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
    /// Conversations removed from Mosaic (they stay in Messages), with their newest message id then.
    var hidden: [String: String] = [:] { didSet { if hidden != oldValue { persist() } } }
    /// New messages being addressed, by tile id ("new-…"), before they have a conversation.
    var composeDrafts: [String: ComposeDraft] = [:]
    /// Every contact with its handles, for addressing new messages.
    var contactEntries: [ContactNames.Entry] = []
    var search = ""
    var isLive = false
    var connectionError: String?
    var banner: String?
    /// A modal message for something that cannot be done right now.
    var alert: WorkspaceAlert?
    var sendingIDs = Set<String>()
    var sendErrors: [String: String] = [:]
    var showSetup = false
    var historyLimits: [String: Int] = [:]
    var isLoadingContacts = false
    var contactStatus: String?
    private(set) var contactAuthorization = CNContactStore.authorizationStatus(for: .contacts)
    var tileDrag: TileDragSession?
    /// The sidebar row the keyboard is on, while the conversation list has keyboard focus (⌘L, or
    /// an arrow key from the search field). Nil whenever the list does not have the keyboard.
    var sidebarSelection: String?
    /// The sidebar row under the pointer.
    var sidebarHover: String?
    /// The row a sideways swipe (its Delete action) started on. Its highlight stays off until the
    /// swipe is closed again or something is clicked, so no highlight sits against the action.
    var sidebarSwipedRow: String?
    /// The one highlighted sidebar row: the keyboard's row while the list has the keyboard, else
    /// the row under the pointer. The pointer moves the keyboard's row too, so they never differ.
    var highlightedSidebarRow: String? {
        let id = sidebarSelection ?? sidebarHover
        return id == sidebarSwipedRow ? nil : id
    }
    /// Where the pointer was when the keyboard last moved the sidebar row: a hover that arrives
    /// with the pointer still there is the list scrolling under it, not the pointer choosing a row.
    @ObservationIgnored private var pointerAtKeyboardMove: NSPoint?
    /// The pointer's screen location; tests stand in for the real pointer.
    @ObservationIgnored var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
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
            state.drafts = drafts; state.seenMessageIDs = seenMessageIDs; state.hidden = hidden
            return state
        }
        set {
            if openIDs != newValue.openIDs { openIDs = newValue.openIDs }
            if focusedID != newValue.focusedID { focusedID = newValue.focusedID }
            if layout != newValue.layout { layout = newValue.layout }
            if drafts != newValue.drafts { drafts = newValue.drafts }
            if seenMessageIDs != newValue.seenMessageIDs { seenMessageIDs = newValue.seenMessageIDs }
            if hidden != newValue.hidden { hidden = newValue.hidden }
        }
    }
    /// Applies a `Workspace` mutation, writing back only the fields it changed.
    private func mutate(_ body: (inout Workspace) -> Void) {
        var state = workspace
        body(&state)
        workspace = state
    }

    /// The sidebar's conversations: not hidden, and matching the search when there is one.
    var filteredConversations: [Conversation] {
        let visible = hidden.isEmpty ? conversations : conversations.filter { hidden[$0.id] == nil }
        guard !search.isEmpty else { return visible }
        return visible.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) ||
            $0.participants.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var tiles: [Conversation] { openIDs.compactMap(tile(for:)) }
    /// A tile's content: a conversation, or the placeholder for a new message being addressed.
    func tile(for id: String) -> Conversation? {
        if let draft = composeDrafts[id] {
            return Conversation(id: id, name: "New Message", participants: draft.recipients.map(\.address),
                                preview: "", lastActivity: draft.created, messages: draft.sent, isComposeDraft: true)
        }
        return conversations.first { $0.id == id }
    }
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
            if composeDrafts[id] != nil { composeDrafts[id] = nil; drafts[id] = nil }
        }
        if focusTarget == id { focusTarget = nil }
    }
    /// Removes a conversation from Mosaic: its tile closes and it leaves the sidebar. It stays in
    /// Messages, and a message newer than the moment it was removed brings it back.
    func hide(_ id: String) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        instantly {
            close(id)
            hidden[id] = String(max(conversation.lastActivity, Date()).timeIntervalSinceReferenceDate)
        }
    }
    /// A hidden conversation with activity newer than its removal is shown again.
    private func unhideChanged(in loaded: [Conversation]) {
        guard !hidden.isEmpty else { return }
        var remaining = hidden
        for conversation in loaded {
            guard let marker = hidden[conversation.id].flatMap(Double.init),
                  conversation.lastActivity.timeIntervalSinceReferenceDate > marker + 1 else { continue }
            remaining[conversation.id] = nil
        }
        if remaining != hidden { hidden = remaining }
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

    // MARK: Sidebar keyboard

    /// Puts the keyboard's row on `id`, or where the list is entered: the focused tile's row when
    /// it is listed, else the first row.
    func selectSidebarRow(_ id: String?) {
        let rows = filteredConversations
        let target = id.flatMap { candidate in rows.contains { $0.id == candidate } ? candidate : nil }
            ?? focusedID.flatMap { focused in rows.contains { $0.id == focused } ? focused : nil }
            ?? rows.first?.id
        pointerAtKeyboardMove = pointerLocation()
        if sidebarSelection != target { instantly { sidebarSelection = target } }
    }
    /// The pointer entered a row: it is the highlighted row, and the keyboard's row while the list
    /// has the keyboard — unless the pointer has not moved since the keyboard last chose a row,
    /// in which case the list scrolled under a resting pointer and the keyboard's choice stands.
    func hoverSidebarRow(_ id: String) {
        instantly {
            if sidebarHover != id { sidebarHover = id }
            guard sidebarSelection != nil, sidebarSelection != id else { return }
            if let resting = pointerAtKeyboardMove, resting == pointerLocation() { return }
            sidebarSelection = id
        }
    }
    /// The pointer left a row.
    func leaveSidebarRow(_ id: String) {
        if sidebarHover == id { instantly { sidebarHover = nil } }
    }
    /// A sideways swipe began (on the row under the pointer) or ended.
    func setSidebarSwiping(_ swiping: Bool) {
        let row = swiping ? sidebarHover : nil
        if sidebarSwipedRow != row { instantly { sidebarSwipedRow = row } }
    }
    /// Moves the keyboard's row down (positive) or up, stopping at the ends. Without a current row
    /// the first press lands on the first (moving down) or last (moving up) row.
    func moveSidebarSelection(by offset: Int) {
        let rows = filteredConversations
        guard !rows.isEmpty else { return }
        let target: Int
        if let current = sidebarSelection, let index = rows.firstIndex(where: { $0.id == current }) {
            target = min(max(index + offset, 0), rows.count - 1)
        } else {
            target = offset >= 0 ? 0 : rows.count - 1
        }
        pointerAtKeyboardMove = pointerLocation()
        if sidebarSelection != rows[target].id { instantly { sidebarSelection = rows[target].id } }
    }
    /// Return on the keyboard's row (or the first search result): opens it in a tile, or focuses its
    /// tile when it is already open. With every tile taken, says so instead of doing nothing.
    func activateSidebarSelection() {
        guard let id = sidebarSelection ?? (search.isEmpty ? nil : filteredConversations.first?.id) else { return }
        if openIDs.contains(id) { focus(id); return }
        guard openIDs.count < Workspace.maximumTiles else {
            alert = WorkspaceAlert(title: "Mosaic shows up to \(Workspace.maximumTiles) conversations",
                                   message: "Close a tile to open another conversation.")
            return
        }
        open(id)
    }
    /// Delete on the keyboard's row: closes that conversation's tile, if it has one. The
    /// conversation itself stays in the list.
    func untileSidebarSelection() {
        guard let id = sidebarSelection, openIDs.contains(id) else { return }
        close(id)
    }
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
        focusTarget = nil; composeDrafts = [:]
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
            unhideChanged(in: loaded)
            adoptConversations(for: loaded)
            updateContactStatus()
            var reconciledWorkspace = workspace
            reconciledWorkspace.reconcile(availableIDs: Set(loaded.map(\.id)).union(composeDrafts.keys))
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
        if composeDrafts[id] != nil { await sendCompose(id); return }
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

    // MARK: New messages

    /// Opens a tile for a new message. Recipients are chosen in the tile; the conversation is
    /// found or created when the first message is sent.
    @discardableResult func beginNewChat() -> String? {
        guard openIDs.count < Workspace.maximumTiles else {
            alert = WorkspaceAlert(title: "Mosaic shows up to \(Workspace.maximumTiles) conversations",
                                   message: "Close a tile to start a new message.")
            return nil
        }
        let id = "new-\(UUID().uuidString)"
        instantly {
            composeDrafts[id] = ComposeDraft()
            mutate { $0.open(id) }
        }
        return id
    }
    func addRecipient(_ recipient: Recipient, to draftID: String) {
        guard var draft = composeDrafts[draftID], !draft.recipients.contains(where: { $0.id == recipient.id }) else { return }
        draft.recipients.append(recipient)
        draft.boundConversationID = nil
        instantly { composeDrafts[draftID] = draft }
    }
    func removeRecipient(_ recipient: Recipient, from draftID: String) {
        guard var draft = composeDrafts[draftID] else { return }
        draft.recipients.removeAll { $0.id == recipient.id }
        draft.boundConversationID = nil
        instantly { composeDrafts[draftID] = draft }
    }
    /// Addresses the new message to an existing conversation (all of its people).
    func addressDraft(_ draftID: String, to conversation: Conversation) {
        guard var draft = composeDrafts[draftID] else { return }
        draft.recipients = conversation.participants.map { Recipient(address: $0, name: contactNames.name(for: $0)) }
        draft.boundConversationID = conversation.id
        instantly { composeDrafts[draftID] = draft }
    }
    /// People and conversations matching what was typed in the To field: contacts (one row per
    /// handle) and existing conversations, including groups.
    func recipientSuggestions(for query: String, excluding draftID: String) -> [RecipientSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = Set(composeDrafts[draftID]?.recipients.map(\.id) ?? [])
        var results: [RecipientSuggestion] = []
        var seen = Set<String>()
        func add(_ suggestion: RecipientSuggestion) { if seen.insert(suggestion.id).inserted { results.append(suggestion) } }
        if text.isEmpty {
            for conversation in filteredConversations.prefix(8) where !conversation.isComposeDraft { add(.conversation(conversation)) }
            return results
        }
        let digits = text.filter(\.isNumber)
        for entry in contactEntries where entry.name.localizedCaseInsensitiveContains(text) || entry.addresses.contains(where: { $0.localizedCaseInsensitiveContains(text) || (!digits.isEmpty && Recipient.key(for: $0).contains(digits)) }) {
            for address in entry.addresses where !chosen.contains(Recipient.key(for: address)) {
                add(.contact(Recipient(address: address, name: entry.name)))
            }
            if results.count >= 12 { break }
        }
        for conversation in filteredConversations where !conversation.isComposeDraft &&
            (conversation.name.localizedCaseInsensitiveContains(text) || conversation.participants.contains { $0.localizedCaseInsensitiveContains(text) || (!digits.isEmpty && Recipient.key(for: $0).contains(digits)) }) {
            add(.conversation(conversation))
            if results.count >= 16 { break }
        }
        // Typing a full handle addresses it directly, even with no contact for it.
        if text.contains("@") && text.contains(".") || digits.count >= 7 && digits.count == text.filter { !"+()- .".contains($0) }.count {
            add(.contact(Recipient(address: text, name: contactNames.name(for: text))))
        }
        return Array(results.prefix(16))
    }
    /// The existing conversation with exactly these people, if there is one.
    func conversation(with recipients: [Recipient]) -> Conversation? {
        guard !recipients.isEmpty else { return nil }
        let keys = Set(recipients.map(\.id))
        return conversations.first { !$0.isComposeDraft && $0.participantKeys == keys }
    }

    /// Sends a new message: to the conversation that has these people, or, for one new person, by
    /// asking Messages to start the conversation. Messages cannot start a new group from another
    /// app, so a new group is handed to Messages itself.
    private func sendCompose(_ draftID: String) async {
        guard let draft = composeDrafts[draftID] else { return }
        let originalDraft = drafts[draftID] ?? ""
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sendingIDs.contains(draftID) else { return }
        guard !draft.recipients.isEmpty else { sendErrors[draftID] = "Add at least one recipient."; return }
        guard canSend else { sendErrors[draftID] = "Connect Messages before sending."; return }
        let target = draft.boundConversationID.flatMap { id in conversations.first { $0.id == id } } ?? conversation(with: draft.recipients)
        sendingIDs.insert(draftID); sendErrors[draftID] = nil
        defer { sendingIDs.remove(draftID) }
        let message = Message(id: "pending-\(UUID().uuidString)", text: text, date: Date(), isFromMe: true)
        if let target {
            if isLive {
                do { try MessagesBridge.send(text: text, conversationID: target.id) }
                catch { sendErrors[draftID] = error.localizedDescription; return }
                pending[target.id, default: []].append(message)
            }
            instantly {
                if drafts[draftID] == originalDraft { drafts[draftID] = nil }
                if let index = conversations.firstIndex(where: { $0.id == target.id }) {
                    conversations[index].messages.append(message)
                    conversations[index].preview = text
                    conversations[index].lastActivity = Date()
                }
                replaceTile(draftID, with: target.id)
            }
            markSeen(target.id)
            if isLive { lastLoad = nil; await refresh() }
            return
        }
        guard draft.recipients.count == 1, let recipient = draft.recipients.first else {
            sendErrors[draftID] = "Messages can't start a new group from another app. Start it in Messages — it will appear here once it exists."
            openMessages(addresses: draft.recipients.map(\.address))
            return
        }
        if isLive {
            do { try MessagesBridge.send(text: text, toNewRecipient: Recipient.handle(for: recipient.address)) }
            catch { sendErrors[draftID] = error.localizedDescription; return }
        }
        // The conversation appears in the database once Messages has created it; the tile adopts
        // it then (adoptConversations). Until then the sent text is shown in the draft tile.
        var waiting = draft
        waiting.sent.append(message)
        waiting.awaitingConversationSince = Date()
        instantly {
            if drafts[draftID] == originalDraft { drafts[draftID] = "" }
            composeDrafts[draftID] = waiting
        }
        pending[draftID, default: []].append(message)
        if isLive { lastLoad = nil; await refresh() }
    }
    /// Swaps a new-message tile for the conversation it turned out to be.
    private func replaceTile(_ draftID: String, with conversationID: String) {
        var state = workspace
        if let index = state.openIDs.firstIndex(of: draftID) {
            if state.openIDs.contains(conversationID) { state.openIDs.remove(at: index) } else { state.openIDs[index] = conversationID }
        }
        if state.focusedID == draftID { state.focusedID = conversationID }
        if let text = state.drafts[draftID], !text.isEmpty, (state.drafts[conversationID] ?? "").isEmpty { state.drafts[conversationID] = text }
        state.drafts[draftID] = nil
        workspace = state
        if let pendingMessages = pending[draftID] { pending[conversationID, default: []].append(contentsOf: pendingMessages); pending[draftID] = nil }
        composeDrafts[draftID] = nil
        if focusTarget == draftID { focusTarget = conversationID }
    }
    /// New-message tiles whose conversation now exists in the database adopt it.
    private func adoptConversations(for loaded: [Conversation]) {
        for (draftID, draft) in composeDrafts where draft.awaitingConversationSince != nil {
            let keys = Set(draft.recipients.map(\.id))
            guard let match = loaded.first(where: { $0.participantKeys == keys }) else { continue }
            instantly { replaceTile(draftID, with: match.id) }
            markSeen(match.id)
            refreshRequestedWhileBusy = true
        }
    }
    /// Opens Messages addressed to these people, for what automation cannot do (new groups).
    func openMessages(addresses: [String]) {
        let handles = addresses.map(Recipient.handle(for:)).joined(separator: ",")
        if let url = URL(string: "imessage:" + handles.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
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
            contactEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

struct WorkspaceAlert: Identifiable, Equatable {
    let title: String
    let message: String
    var id: String { title + message }
}

/// A message being addressed in a new-message tile.
struct ComposeDraft: Equatable {
    var recipients: [Recipient] = []
    /// Set when the reader picked an existing conversation in the To field.
    var boundConversationID: String?
    /// Messages sent to a new person before Messages has created the conversation.
    var sent: [Message] = []
    var awaitingConversationSince: Date?
    let created = Date()
    var hasRecipients: Bool { !recipients.isEmpty }
}

/// A row in the To field's suggestions: a person (one handle) or an existing conversation.
enum RecipientSuggestion: Identifiable, Equatable {
    case contact(Recipient)
    case conversation(Conversation)
    var id: String {
        switch self {
        case .contact(let recipient): return "contact:" + recipient.id
        case .conversation(let conversation): return "chat:" + conversation.id
        }
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
