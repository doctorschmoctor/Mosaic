import SwiftUI
import Contacts
#if SWIFT_PACKAGE
import MosaicCore
#endif

@MainActor final class WorkspaceStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var workspace = Workspace() { didSet { persist() } }
    @Published var search = ""
    @Published var isLive = false
    @Published var isRefreshing = false
    @Published var connectionError: String?
    @Published var banner: String?
    @Published var sendingIDs = Set<String>()
    @Published var sendErrors: [String: String] = [:]
    @Published var showSetup = false
    @Published var lastRefreshed: Date?
    @Published var historyLimits: [String: Int] = [:]
    @Published var isLoadingContacts = false
    @Published var contactStatus: String?
    @Published private(set) var contactAuthorization = CNContactStore.authorizationStatus(for: .contacts)
    @Published var tileDrag: TileDragSession?
    /// Keyboard traversal: the tile whose composer should take focus, and a token that changes per request.
    @Published private(set) var focusTarget: String?
    @Published private(set) var focusToken = 0
    var openingOrigins: [String: CGPoint] = [:]
    private let defaults: UserDefaults
    private let database: MessagesDatabase
    private var pollTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var contactNames = ContactNames()
    private var originalTitles: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var loadingState = true
    // Submitted sends are held in memory until the database reports them; never auto-retry a send.
    private var pending: [String: [Message]] = [:]
    private var connectedBefore = false
    private let forcedDemo: Bool

    init(defaults: UserDefaults = .standard, database: MessagesDatabase = MessagesDatabase(), forceDemo: Bool = false) {
        self.defaults = defaults; self.database = database
        forcedDemo = forceDemo || ProcessInfo.processInfo.arguments.contains("--demo")
        isLive = !forcedDemo && defaults.bool(forKey: "Mosaic.live")
        if isLive {
            restore()
            Task { await self.loadContacts(requestPermission: self.contactAuthorization == .notDetermined); await self.refresh() }
        } else {
            conversations = DemoData.conversations(imagePaths: DemoAssets.imagePaths())
            restore(defaultIDs: Array(conversations.prefix(4).map(\.id)))
        }
        loadingState = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                await self.loadContacts(requestPermission: false)
            }
        })
        // Contacts may be switched on in System Settings while Mosaic is open; pick that up on return.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let status = CNContactStore.authorizationStatus(for: .contacts)
                let changed = status != self.contactAuthorization
                self.contactAuthorization = status
                if changed, self.isLive, status == .authorized { await self.loadContacts(requestPermission: false) }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistNow() }
        })
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { break }
                if self.isLive { await self.refresh() }
            }
        }
    }

    deinit {
        pollTask?.cancel()
        persistTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var filteredConversations: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) ||
            $0.participants.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var tiles: [Conversation] { workspace.openIDs.compactMap { id in conversations.first { $0.id == id } } }
    var focused: Conversation? { tiles.first { $0.id == workspace.focusedID } ?? tiles.first }
    var canSend: Bool { !isLive || (connectedBefore && connectionError == nil) }
    func name(for address: String) -> String { contactNames.name(for: address) ?? address }

    /// Tile order shown on screen: the drag preview while a tile is held, always covering every open tile.
    var displayOrder: [String] {
        guard let drag = tileDrag else { return workspace.openIDs }
        let open = Set(workspace.openIDs)
        var order = drag.order.filter { open.contains($0) }
        order += workspace.openIDs.filter { !order.contains($0) }
        return order
    }

    /// Runs a workspace layout change with the shared tile animation, tagged so message lists can skip it.
    func animateLayout(_ animation: Animation? = Motion.layout, _ changes: () -> Void) {
        var transaction = Transaction(animation: animation)
        transaction[TileLayoutTransactionKey.self] = true
        withTransaction(transaction, changes)
    }

    func open(_ id: String, from origin: CGPoint? = nil) {
        if let origin, !workspace.openIDs.contains(id) { openingOrigins[id] = origin }
        var opened = false
        animateLayout { opened = workspace.open(id) }
        guard opened else { banner = "Eight chats are open. Close a tile to make room for another."; return }
        markSeen(id)
        if isLive { Task { await refresh() } }
    }
    /// Forgets where a tile was opened from once it has appeared, so a later re-insertion (switching
    /// layouts, say) does not replay the sidebar fly-out.
    func consumeOpeningOrigin(_ id: String) {
        guard openingOrigins[id] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openingOrigins[id] = nil }
    }
    func close(_ id: String) {
        animateLayout {
            if tileDrag?.id == id { tileDrag = nil }
            workspace.close(id)
        }
        if focusTarget == id { focusTarget = nil }
    }
    func focus(_ id: String, animated: Bool = true) {
        guard workspace.openIDs.contains(id) else { return }
        if workspace.focusedID != id {
            if animated { animateLayout { workspace.focusedID = id } } else { workspace.focusedID = id }
        }
        markSeen(id)
    }
    /// Moves keyboard focus to the next (or previous) tile's composer. Returns false when no tile is open.
    @discardableResult func moveFocus(forward: Bool, from current: String?) -> Bool {
        let ids = workspace.openIDs
        guard !ids.isEmpty else { return false }
        // Relative to the composer that has the keyboard, else to the focused tile: one press always moves
        // to another tile. (It used to spend the first press focusing the current tile's composer.)
        let origin = current.flatMap { ids.contains($0) ? $0 : nil } ?? workspace.focusedID.flatMap { ids.contains($0) ? $0 : nil }
        let target: String
        if let origin, let index = ids.firstIndex(of: origin) {
            target = ids[(index + (forward ? 1 : ids.count - 1)) % ids.count]
        } else {
            target = forward ? ids[0] : ids[ids.count - 1]
        }
        requestComposerFocus(target)
        return true
    }
    /// Focuses a tile and puts the keyboard in its composer in one step.
    func requestComposerFocus(_ id: String) {
        guard workspace.openIDs.contains(id) else { return }
        focus(id, animated: false)
        focusTarget = id
        focusToken += 1
    }
    func reorder(_ id: String, before destination: String) { animateLayout { workspace.reorder(id, before: destination) } }
    func setLayout(_ layout: WorkspaceLayout) { animateLayout { tileDrag = nil; workspace.layout = layout } }
    func dragTile(_ id: String, translation: CGSize, plan: TilePlan) {
        guard workspace.layout != .focus, let frame = plan.frames[id] else { return }
        // Only one tile can be held. A session for another tile is stale (its release was never reported).
        if tileDrag?.id != id { tileDrag = TileDragSession(id: id, origin: frame, order: workspace.openIDs) }
        guard var drag = tileDrag else { return }
        let previousOrder = drag.order
        drag.update(translation: translation, plan: plan)
        if drag.order != previousOrder {
            animateLayout { tileDrag = drag }
        } else {
            // Follow the pointer exactly; neighbors keep any movement already in flight.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { tileDrag = drag }
        }
    }
    func finishTileDrag(_ id: String? = nil) {
        guard let drag = tileDrag, id == nil || drag.id == id else { return }
        let order = displayOrder
        animateLayout {
            if workspace.openIDs != order { workspace.openIDs = order }
            tileDrag = nil
        }
    }
    func draft(_ id: String) -> Binding<String> {
        Binding(get: { self.workspace.drafts[id] ?? "" }, set: { self.workspace.drafts[id] = $0 })
    }
    func markSeen(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if conversations[index].unreadCount != 0 { conversations[index].unreadCount = 0 }
        if let last = conversations[index].messages.last, workspace.seenMessageIDs[id] != last.id { workspace.seenMessageIDs[id] = last.id }
    }
    func setMode(live: Bool) {
        guard live != isLive, sendingIDs.isEmpty else { return }
        persistNow(); generation += 1; isLive = live; connectedBefore = false
        connectionError = nil; banner = nil; sendErrors = [:]; pending = [:]; search = ""; tileDrag = nil; originalTitles = [:]
        focusTarget = nil
        defaults.set(live, forKey: "Mosaic.live")
        loadingState = true
        if live {
            conversations = []; restore()
            Task { await loadContacts(requestPermission: contactAuthorization == .notDetermined); await refresh() }
        } else {
            conversations = DemoData.conversations(imagePaths: DemoAssets.imagePaths())
            restore(defaultIDs: Array(conversations.prefix(4).map(\.id)))
        }
        loadingState = false
    }

    func refresh() async {
        guard isLive, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let requestGeneration = generation
        let ids = Set(workspace.openIDs)
        let historyLimit = max(100, historyLimits.values.max() ?? 100)
        let database = self.database
        do {
            var loaded = try await Task.detached(priority: .userInitiated) { try database.load(openIDs: ids, historyLimit: historyLimit) }.value
            guard generation == requestGeneration, isLive else { return }
            if connectionError != nil { connectionError = nil }
            connectedBefore = true; lastRefreshed = Date()
            for index in loaded.indices {
                let id = loaded[index].id
                originalTitles[id] = loaded[index].name
                loaded[index].name = contactNames.title(for: loaded[index])
                // Remove a submitted bubble when an outgoing row with the same text and a recent date appears.
                let reconciled = MessageReconciler.merge(loaded: loaded[index].messages,
                    previous: conversations.first(where: { $0.id == id })?.messages ?? [], pending: pending[id] ?? [])
                pending[id] = reconciled.pending
                loaded[index].messages = reconciled.messages
                if let previous = conversations.first(where: { $0.id == id }),
                   previous.preview != loaded[index].preview, !ids.contains(id) { loaded[index].unreadCount = previous.unreadCount + 1 }
                else { loaded[index].unreadCount = conversations.first(where: { $0.id == id })?.unreadCount ?? 0 }
                if ids.contains(id) { loaded[index].unreadCount = 0 }
            }
            // Publishing identical data every three seconds re-rendered every tile; only publish real changes.
            if loaded != conversations { conversations = loaded }
            updateContactStatus()
            var reconciledWorkspace = workspace
            reconciledWorkspace.reconcile(availableIDs: Set(loaded.map(\.id)))
            if reconciledWorkspace != workspace { workspace = reconciledWorkspace }
            if workspace.openIDs.isEmpty && !defaults.bool(forKey: "Mosaic.live.hasWorkspace"), let first = loaded.first {
                workspace.open(first.id)
                defaults.set(true, forKey: "Mosaic.live.hasWorkspace")
                Task { await self.refresh() }
            }
        } catch {
            guard generation == requestGeneration else { return }
            connectionError = error.localizedDescription
        }
    }

    func loadMore(_ id: String) {
        historyLimits[id] = min(1000, (historyLimits[id] ?? 100) + 100)
        Task { await refresh() }
    }

    func send(_ id: String) async {
        let originalDraft = workspace.drafts[id] ?? ""
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sendingIDs.contains(id), canSend,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        sendingIDs.insert(id); sendErrors[id] = nil
        defer { sendingIDs.remove(id) }
        let message = Message(id: "pending-\(UUID().uuidString)", text: text, date: Date(), isFromMe: true)
        if isLive {
            do {
                // NSAppleScript is executed on the main actor, as required by Foundation.
                try MessagesBridge.send(text: text, conversationID: id)
                pending[id, default: []].append(message)
            } catch { sendErrors[id] = error.localizedDescription; return }
        }
        withAnimation(Motion.message) {
            if workspace.drafts[id] == originalDraft { workspace.drafts[id] = "" }
            if let currentIndex = conversations.firstIndex(where: { $0.id == id }) {
                conversations[currentIndex].messages.append(message)
                conversations[currentIndex].preview = text
                conversations[currentIndex].lastActivity = Date()
            }
        }
        markSeen(id)
        if isLive { await refresh() }
        else {
            // Demo sending stays local. No invented replies or real recipients.
            conversations[index].unreadCount = 0
        }
    }

    // MARK: Contacts

    /// Loads contact names. With `requestPermission`, asks macOS for Contacts access first if needed.
    func loadContacts(requestPermission: Bool = true) async {
        guard !isLoadingContacts else { return }
        var status = CNContactStore.authorizationStatus(for: .contacts)
        contactAuthorization = status
        if status != .authorized {
            guard requestPermission else { return }
            switch status {
            case .denied:
                contactStatus = "Contacts access is off for Mosaic. Turn it on in System Settings → Privacy & Security → Contacts; names load as soon as you return."
                return
            case .restricted:
                contactStatus = "Contacts access is restricted on this Mac (for example by a device profile)."
                return
            default: break
            }
            isLoadingContacts = true
            let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            isLoadingContacts = false
            status = CNContactStore.authorizationStatus(for: .contacts)
            contactAuthorization = status
            guard granted, status == .authorized else {
                contactStatus = "Mosaic wasn't given Contacts access. Turn it on in System Settings → Privacy & Security → Contacts."
                return
            }
        }
        isLoadingContacts = true
        defer { isLoadingContacts = false }
        do {
            let entries = try await Task.detached(priority: .userInitiated) {
                let request = CNContactFetchRequest(keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                    CNContactIdentifierKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor])
                var entries: [ContactNames.Entry] = []
                try CNContactStore().enumerateContacts(with: request) { contact, _ in
                    let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                    let name = [formatted, contact.nickname, contact.organizationName].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                    guard !name.isEmpty else { return }
                    entries.append(ContactNames.Entry(id: contact.identifier, name: name,
                        addresses: contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }))
                }
                return entries
            }.value
            applyContactNames(ContactNames(entries: entries))
        } catch { contactStatus = "Contact sync failed: \(error.localizedDescription)" }
    }

    /// Apply immediately, even when a Messages refresh is already in flight.
    func applyContactNames(_ names: ContactNames) {
        contactNames = names
        for index in conversations.indices {
            var original = conversations[index]
            if originalTitles[original.id] == nil { originalTitles[original.id] = original.name }
            original.name = originalTitles[original.id] ?? original.name
            let title = names.title(for: original)
            if conversations[index].name != title { conversations[index].name = title }
        }
        if names.contactCount == 0 { contactStatus = "No named contacts were found. Check that your contacts appear in the Mac's Contacts app." }
        updateContactStatus()
    }
    private func updateContactStatus() {
        guard contactNames.contactCount > 0 else { return }
        let matches = conversations.filter { chat in
            if chat.participants.isEmpty { return contactNames.name(for: originalTitles[chat.id] ?? chat.name) != nil }
            return chat.participants.contains { contactNames.name(for: $0) != nil }
        }.count
        let status = "Loaded \(contactNames.contactCount) contacts · Matched \(matches) of \(conversations.count) conversations."
        if contactStatus != status { contactStatus = status }
    }

    func openPrivacy(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") { NSWorkspace.shared.open(url) }
    }
    func openMessages(_ conversation: Conversation? = nil) {
        if let address = conversation?.participants.first, conversation?.isGroup == false,
           let escaped = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "imessage:\(escaped)") { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app")) }
    }
    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    // MARK: Persistence

    private var stateKey: String { "Mosaic.workspace.\(isLive ? "live" : "demo")" }
    /// Coalesces saves: typing changes a draft on every keystroke, and encoding each one blocked the main thread.
    private func persist() {
        guard !loadingState, !forcedDemo else { return }
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }
    func persistNow() {
        persistTask?.cancel(); persistTask = nil
        guard !loadingState, !forcedDemo, let data = try? JSONEncoder().encode(workspace) else { return }
        defaults.set(data, forKey: stateKey)
    }
    private func restore(defaultIDs: [String] = []) {
        if !forcedDemo, let data = defaults.data(forKey: stateKey), let saved = try? JSONDecoder().decode(Workspace.self, from: data) { workspace = saved }
        else { workspace = Workspace(openIDs: defaultIDs) }
        if !isLive { workspace.reconcile(availableIDs: Set(conversations.map(\.id))) }
    }
}
