import SwiftUI
import Observation
import Contacts
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// The workspace model. It is `@Observable` rather than an `ObservableObject`: a view re-renders
/// only when something it actually read changes, so a keystroke in one composer no longer
/// re-renders every sidebar row and every tile, and the periodic poll touches nothing a view reads
/// unless the database changed.
@MainActor @Observable final class WorkspaceStore {
    var conversations: [Conversation] = []
    // The persisted workspace, as separate fields so that typing a draft invalidates only the views
    // that read drafts. `workspace` assembles them for persistence and for tests.
    var openIDs: [String] = [] { didSet { if openIDs != oldValue { persist() } } }
    var focusedID: String? { didSet { if focusedID != oldValue { persist() } } }
    var layout: WorkspaceLayout = .grid { didSet { if layout != oldValue { persist() } } }
    var drafts: [String: String] = [:] { didSet { if drafts != oldValue { persist() } } }
    var seenMessageIDs: [String: String] = [:] { didSet { if seenMessageIDs != oldValue { persist() } } }
    var search = ""
    var isLive = false
    var connectionError: String?
    var banner: String?
    var sendingIDs = Set<String>()
    var sendErrors: [String: String] = [:]
    var showSetup = false
    var historyLimits: [String: Int] = [:]
    var isLoadingContacts = false
    var contactStatus: String?
    private(set) var contactAuthorization = CNContactStore.authorizationStatus(for: .contacts)
    var tileDrag: TileDragSession?
    /// Keyboard traversal: the tile whose composer should take focus, and a token that changes per request.
    private(set) var focusTarget: String?
    private(set) var focusToken = 0

    // Bookkeeping no view reads.
    @ObservationIgnored var isRefreshing = false
    @ObservationIgnored private(set) var lastRefreshed: Date?
    @ObservationIgnored private var refreshRequestedWhileBusy = false
    /// Transient read failures (Messages writing to the database) keep the last good data; the
    /// connection error only shows once reads keep failing or the first connection never succeeded.
    @ObservationIgnored private(set) var consecutiveLoadFailures = 0
    static let failuresBeforeError = 3
    private let defaults: UserDefaults
    private let database: MessagesDatabase
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileChangeWatcher?
    @ObservationIgnored private var watchRefreshTask: Task<Void, Never>?
    /// What the last successful load covered; a poll skips the load when the database's fingerprint
    /// still matches and the request (open tiles, history depth) is the same.
    @ObservationIgnored private var lastLoad: (fingerprint: DatabaseFingerprint, ids: Set<String>, historyLimit: Int)?
    @ObservationIgnored private var contactNames = ContactNames()
    @ObservationIgnored private var originalTitles: [String: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingState = true
    // Submitted sends are held in memory until the database reports them; never auto-retry a send.
    @ObservationIgnored private var pending: [String: [Message]] = [:]
    @ObservationIgnored private var connectedBefore = false
    private let forcedDemo: Bool

    init(defaults: UserDefaults = .standard, database: MessagesDatabase = MessagesDatabase(), forceDemo: Bool = false) {
        self.defaults = defaults; self.database = database
        forcedDemo = forceDemo || ProcessInfo.processInfo.arguments.contains("--demo")
        isLive = !forcedDemo && defaults.bool(forKey: "Mosaic.live")
        // Connection settings open on launch until Messages is connected; afterwards they live in
        // Mosaic › Settings and the Workspace menu.
        showSetup = !isLive && !forcedDemo
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
        // The poll is a fallback: changes are normally picked up within a moment by the file watcher.
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
        watchRefreshTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The persisted shape of the workspace (open tiles, focus, layout, drafts, seen messages).
    var workspace: Workspace {
        get {
            var state = Workspace()
            state.openIDs = openIDs; state.focusedID = focusedID; state.layout = layout
            state.drafts = drafts; state.seenMessageIDs = seenMessageIDs
            return state
        }
        set {
            if openIDs != newValue.openIDs { openIDs = newValue.openIDs }
            if focusedID != newValue.focusedID { focusedID = newValue.focusedID }
            if layout != newValue.layout { layout = newValue.layout }
            if drafts != newValue.drafts { drafts = newValue.drafts }
            if seenMessageIDs != newValue.seenMessageIDs { seenMessageIDs = newValue.seenMessageIDs }
        }
    }
    /// Applies a `Workspace` mutation, writing back only the fields it changed.
    private func mutate(_ body: (inout Workspace) -> Void) {
        var state = workspace
        body(&state)
        workspace = state
    }

    var filteredConversations: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) ||
            $0.participants.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var tiles: [Conversation] { openIDs.compactMap { id in conversations.first { $0.id == id } } }
    var focused: Conversation? { tiles.first { $0.id == focusedID } ?? tiles.first }
    var canSend: Bool { !isLive || (connectedBefore && connectionError == nil) }
    func name(for address: String) -> String { contactNames.name(for: address) ?? address }

    /// Tile order shown on screen: the drag preview while a tile is held, always covering every open tile.
    var displayOrder: [String] {
        guard let drag = tileDrag else { return openIDs }
        let open = Set(openIDs)
        var order = drag.order.filter { open.contains($0) }
        order += openIDs.filter { !order.contains($0) }
        return order
    }

    func open(_ id: String) {
        var opened = false
        instantly { mutate { opened = $0.open(id) } }
        // At capacity, the click does nothing; close a tile to make room.
        guard opened else { return }
        markSeen(id)
        if isLive { Task { await refresh() } }
    }
    func close(_ id: String) {
        instantly {
            if tileDrag?.id == id { tileDrag = nil }
            mutate { $0.close(id) }
        }
        if focusTarget == id { focusTarget = nil }
    }
    func focus(_ id: String) {
        guard openIDs.contains(id) else { return }
        if focusedID != id { instantly { focusedID = id } }
        markSeen(id)
    }
    /// Moves keyboard focus to the next (or previous) tile's composer. Returns false when no tile is open.
    @discardableResult func moveFocus(forward: Bool, from current: String?) -> Bool {
        let ids = openIDs
        guard !ids.isEmpty else { return false }
        // Relative to the composer that has the keyboard, else to the focused tile: one press always moves
        // to another tile.
        let origin = current.flatMap { ids.contains($0) ? $0 : nil } ?? focusedID.flatMap { ids.contains($0) ? $0 : nil }
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
        guard openIDs.contains(id) else { return }
        focus(id)
        focusTarget = id
        focusToken += 1
    }
    func reorder(_ id: String, before destination: String) { instantly { mutate { $0.reorder(id, before: destination) } } }
    func setLayout(_ layout: WorkspaceLayout) { instantly { tileDrag = nil; self.layout = layout } }
    func dragTile(_ id: String, translation: CGSize, plan: TilePlan) {
        guard layout != .focus, let frame = plan.frames[id] else { return }
        // Only one tile can be held. A session for another tile is stale (its release was never reported).
        if tileDrag?.id != id { tileDrag = TileDragSession(id: id, origin: frame, order: openIDs) }
        guard var drag = tileDrag else { return }
        drag.update(translation: translation, plan: plan)
        instantly { tileDrag = drag }
    }
    func finishTileDrag(_ id: String? = nil) {
        guard let drag = tileDrag, id == nil || drag.id == id else { return }
        let order = displayOrder
        instantly {
            if openIDs != order { openIDs = order }
            tileDrag = nil
        }
    }
    func draft(_ id: String) -> Binding<String> {
        Binding(get: { self.drafts[id] ?? "" }, set: { if self.drafts[id] ?? "" != $0 { self.drafts[id] = $0 } })
    }
    func markSeen(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if conversations[index].unreadCount != 0 { conversations[index].unreadCount = 0 }
        if let last = conversations[index].messages.last, seenMessageIDs[id] != last.id { seenMessageIDs[id] = last.id }
    }
    func setMode(live: Bool) {
        guard live != isLive, sendingIDs.isEmpty else { return }
        persistNow(); generation += 1; isLive = live; connectedBefore = false; consecutiveLoadFailures = 0; lastLoad = nil
        connectionError = nil; banner = nil; sendErrors = [:]; pending = [:]; search = ""; tileDrag = nil; originalTitles = [:]
        focusTarget = nil
        defaults.set(live, forKey: "Mosaic.live")
        loadingState = true
        if live {
            conversations = []; restore()
            Task { await loadContacts(requestPermission: contactAuthorization == .notDetermined); await refresh() }
        } else {
            watcher = nil
            conversations = DemoData.conversations(imagePaths: DemoAssets.imagePaths())
            restore(defaultIDs: Array(conversations.prefix(4).map(\.id)))
        }
        loadingState = false
    }

    /// Reloads conversations and open histories. A request that arrives while a load is running is
    /// not dropped: one more load follows, so a tile opened mid-poll gets its history right away.
    func refresh() async {
        guard isLive else { return }
        if isRefreshing { refreshRequestedWhileBusy = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequestedWhileBusy = false
            await performRefresh()
        } while refreshRequestedWhileBusy && isLive
    }

    private func performRefresh() async {
        let requestGeneration = generation
        let ids = Set(openIDs)
        let historyLimit = max(100, historyLimits.values.max() ?? 100)
        let database = self.database
        // The same request as last time may skip the load if nothing in the database moved.
        let known = lastLoad.flatMap { $0.ids == ids && $0.historyLimit == historyLimit ? $0.fingerprint : nil }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try database.snapshot(openIDs: ids, historyLimit: historyLimit, unlessUnchangedFrom: known)
            }.value
            guard generation == requestGeneration, isLive else { return }
            consecutiveLoadFailures = 0
            if connectionError != nil { connectionError = nil }
            connectedBefore = true; lastRefreshed = Date()
            startWatchingDatabase()
            guard let snapshot else { return } // unchanged since the last load
            lastLoad = (snapshot.fingerprint, ids, historyLimit)
            var loaded = snapshot.conversations
            let previousByID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in loaded.indices {
                let id = loaded[index].id
                originalTitles[id] = loaded[index].name
                loaded[index].name = contactNames.title(for: loaded[index])
                let previous = previousByID[id]
                // Remove a submitted bubble when an outgoing row with the same text and a recent date appears.
                let reconciled = MessageReconciler.merge(loaded: loaded[index].messages, previous: previous?.messages ?? [], pending: pending[id] ?? [])
                pending[id] = reconciled.pending
                loaded[index].messages = reconciled.messages
                if let previous, previous.preview != loaded[index].preview, !ids.contains(id) { loaded[index].unreadCount = previous.unreadCount + 1 }
                else { loaded[index].unreadCount = previous?.unreadCount ?? 0 }
                if ids.contains(id) { loaded[index].unreadCount = 0 }
            }
            // Publishing identical data re-rendered every tile; only publish real changes.
            if loaded != conversations { instantly { conversations = loaded } }
            updateContactStatus()
            var reconciledWorkspace = workspace
            reconciledWorkspace.reconcile(availableIDs: Set(loaded.map(\.id)))
            if reconciledWorkspace != workspace { instantly { workspace = reconciledWorkspace } }
            if openIDs.isEmpty && !defaults.bool(forKey: "Mosaic.live.hasWorkspace"), let first = loaded.first {
                mutate { $0.open(first.id) }
                defaults.set(true, forKey: "Mosaic.live.hasWorkspace")
                refreshRequestedWhileBusy = true
            }
        } catch {
            guard generation == requestGeneration else { return }
            consecutiveLoadFailures += 1
            if !connectedBefore || consecutiveLoadFailures >= Self.failuresBeforeError {
                connectionError = error.localizedDescription
            }
        }
    }

    /// Refreshes within a moment of Messages writing to its database, instead of at the next poll.
    private func startWatchingDatabase() {
        guard watcher == nil else { return }
        watcher = FileChangeWatcher(paths: database.watchedPaths) { [weak self] in
            guard let self else { return }
            self.watchRefreshTask?.cancel()
            // Messages writes in bursts; one refresh after the burst settles.
            self.watchRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, self.isLive else { return }
                await self.refresh()
            }
        }
    }

    func loadMore(_ id: String) {
        historyLimits[id] = min(1000, (historyLimits[id] ?? 100) + 100)
        Task { await refresh() }
    }

    func send(_ id: String) async {
        let originalDraft = drafts[id] ?? ""
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sendingIDs.contains(id), canSend,
              conversations.contains(where: { $0.id == id }) else { return }
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
        instantly {
            if drafts[id] == originalDraft { drafts[id] = "" }
            if let currentIndex = conversations.firstIndex(where: { $0.id == id }) {
                conversations[currentIndex].messages.append(message)
                conversations[currentIndex].preview = text
                conversations[currentIndex].lastActivity = Date()
            }
        }
        markSeen(id)
        if isLive { lastLoad = nil; await refresh() }
        else if let index = conversations.firstIndex(where: { $0.id == id }) {
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
        var renamed = conversations
        for index in renamed.indices {
            var original = renamed[index]
            if originalTitles[original.id] == nil { originalTitles[original.id] = original.name }
            original.name = originalTitles[original.id] ?? original.name
            let title = names.title(for: original)
            if renamed[index].name != title { renamed[index].name = title }
        }
        if renamed != conversations { conversations = renamed }
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
        var state: Workspace
        if !forcedDemo, let data = defaults.data(forKey: stateKey), let saved = try? JSONDecoder().decode(Workspace.self, from: data) { state = saved }
        else { state = Workspace(openIDs: defaultIDs) }
        if !isLive { state.reconcile(availableIDs: Set(conversations.map(\.id))) }
        workspace = state
    }
}

/// Calls back on the main thread when any of the given files is written, replaced or removed. The
/// write-ahead log Messages appends to is recreated on checkpoints, so a vanished file is watched
/// again as soon as it exists.
@MainActor final class FileChangeWatcher {
    private let paths: [String]
    private let onChange: () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var retry: Task<Void, Never>?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
        watchAll()
    }
    deinit {
        for source in sources.values { source.cancel() }
        retry?.cancel()
    }
    private func watchAll() {
        var missing = false
        for path in paths where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { missing = true; continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let events = source.data
                if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                    source.cancel()
                    self.sources[path] = nil
                    self.scheduleRewatch()
                }
                self.onChange()
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources[path] = source
        }
        if missing { scheduleRewatch() }
    }
    private func scheduleRewatch() {
        guard retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.retry = nil
            self.watchAll()
        }
    }
}
