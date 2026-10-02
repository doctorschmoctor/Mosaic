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
    private let defaults: UserDefaults
    private let database: MessagesDatabase
    private var pollTask: Task<Void, Never>?
    private var contactNames: [String: String] = [:]
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
            Task { await refresh() }
        } else {
            conversations = DemoData.conversations()
            restore(defaultIDs: Array(conversations.prefix(4).map(\.id)))
        }
        loadingState = false
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { break }
                if self.isLive { await self.refresh() }
            }
        }
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
    func name(for address: String) -> String { contactNames[normalized(address)] ?? address }

    func open(_ id: String) {
        guard workspace.open(id) else { banner = "Eight chats are open. Close a tile to make room for another."; return }
        markSeen(id)
        if isLive { Task { await refresh() } }
    }
    func close(_ id: String) { workspace.close(id) }
    func focus(_ id: String) { workspace.focusedID = id; markSeen(id) }
    func reorder(_ id: String, before destination: String) { workspace.reorder(id, before: destination) }
    func draft(_ id: String) -> Binding<String> {
        Binding(get: { self.workspace.drafts[id] ?? "" }, set: { self.workspace.drafts[id] = $0 })
    }
    func markSeen(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].unreadCount = 0
        if let last = conversations[index].messages.last { workspace.seenMessageIDs[id] = last.id }
    }
    func setMode(live: Bool) {
        guard live != isLive, sendingIDs.isEmpty else { return }
        persist(); generation += 1; isLive = live; connectedBefore = false
        connectionError = nil; banner = nil; sendErrors = [:]; pending = [:]; search = ""
        defaults.set(live, forKey: "Mosaic.live")
        loadingState = true
        if live { conversations = []; restore(); Task { await refresh() } }
        else { conversations = DemoData.conversations(); restore(defaultIDs: Array(conversations.prefix(4).map(\.id))) }
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
            connectionError = nil; connectedBefore = true; lastRefreshed = Date()
            for index in loaded.indices {
                let id = loaded[index].id
                if loaded[index].name == loaded[index].participants.joined(separator: ", ") {
                    loaded[index].name = loaded[index].participants.map { name(for: $0) }.joined(separator: ", ")
                }
                // Remove a submitted bubble when an outgoing row with the same text and a recent date appears.
                let waiting = (pending[id] ?? []).filter { candidate in
                    !loaded[index].messages.contains { $0.isFromMe && $0.text == candidate.text && abs($0.date.timeIntervalSince(candidate.date)) < 120 }
                }
                pending[id] = waiting
                loaded[index].messages.append(contentsOf: waiting)
                if let previous = conversations.first(where: { $0.id == id }),
                   previous.preview != loaded[index].preview, !ids.contains(id) { loaded[index].unreadCount = previous.unreadCount + 1 }
                else { loaded[index].unreadCount = conversations.first(where: { $0.id == id })?.unreadCount ?? 0 }
                if ids.contains(id) { loaded[index].unreadCount = 0 }
            }
            conversations = loaded
            workspace.reconcile(availableIDs: Set(loaded.map(\.id)))
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
        if workspace.drafts[id] == originalDraft { workspace.drafts[id] = "" }
        if let currentIndex = conversations.firstIndex(where: { $0.id == id }) {
            conversations[currentIndex].messages.append(message)
            conversations[currentIndex].preview = text
            conversations[currentIndex].lastActivity = Date()
        }
        markSeen(id)
        if isLive { await refresh() }
        else {
            // Demo sending stays local. No invented replies or real recipients.
            conversations[index].unreadCount = 0
        }
    }

    func loadContacts() async {
        let store = CNContactStore()
        do {
            guard try await store.requestAccess(for: .contacts) else { banner = "Contacts access was declined. Phone numbers and email addresses still work."; return }
            let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor])
            var names: [String: String] = [:]
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                guard !name.isEmpty else { return }
                for phone in contact.phoneNumbers { names[self.normalized(phone.value.stringValue)] = name }
                for email in contact.emailAddresses { names[self.normalized(email.value as String)] = name }
            }
            contactNames = names
            await refresh()
            banner = "Contact names loaded for this session."
        } catch { banner = error.localizedDescription }
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
    private func normalized(_ address: String) -> String {
        if address.contains("@") { return address.lowercased() }
        // Preserve country code; do not guess which similarly ending number is a contact.
        return address.filter(\.isNumber)
    }
    private var stateKey: String { "Mosaic.workspace.\(isLive ? "live" : "demo")" }
    private func persist() {
        guard !loadingState, !forcedDemo, let data = try? JSONEncoder().encode(workspace) else { return }
        defaults.set(data, forKey: stateKey)
    }
    private func restore(defaultIDs: [String] = []) {
        if !forcedDemo, let data = defaults.data(forKey: stateKey), let saved = try? JSONDecoder().decode(Workspace.self, from: data) { workspace = saved }
        else { workspace = Workspace(openIDs: defaultIDs) }
        if !isLive { workspace.reconcile(availableIDs: Set(conversations.map(\.id))) }
    }
}
