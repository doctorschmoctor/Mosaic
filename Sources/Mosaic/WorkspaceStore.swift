import SwiftUI
import Observation
import Contacts
import UniformTypeIdentifiers
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
    var focusedID: String? {
        didSet {
            guard focusedID != oldValue else { return }
            persist()
            // Going to a tile is what its dot asks for.
            if let focusedID, tilesWithNews.contains(focusedID) { tilesWithNews.remove(focusedID) }
        }
    }
    /// Open tiles that received a message while the reader was in another tile. Each shows a dot
    /// beside its name until it is focused (Tab, a click, Return in the list). Mosaic's own, like
    /// the unread counts: nothing is marked read in Messages, and the list shows no dot for it.
    private(set) var tilesWithNews: Set<String> = []
    /// Which contact each comparable address (`Recipient.key`) belongs to, for contacts that
    /// have a photo. An avatar fetches the photo itself when it is shown (`ContactPhotos`); the
    /// address book's pictures are never all loaded.
    private(set) var contactPhotoIDs: [String: String] = [:]
    /// Moves on when contacts are loaded again, so avatars on screen fetch their photo again.
    private(set) var contactPhotoGeneration = 0
    /// Conversations whose earlier messages are being loaded (scrolling near the top of a thread).
    private(set) var loadingMore: Set<String> = []
    var layout: WorkspaceLayout = .grid { didSet { if layout != oldValue { persist() } } }
    var drafts: [String: String] = [:] { didSet { if drafts != oldValue { persist() } } }
    var seenMessageIDs: [String: String] = [:] { didSet { if seenMessageIDs != oldValue { persist() } } }
    /// Conversations removed from Mosaic (they stay in Messages), with their newest message id then.
    var hidden: [String: String] = [:] { didSet { if hidden != oldValue { persist() } } }
    /// The conversation-content scale every tile shares (⌘+ / ⌘− / ⌘0); persisted with the workspace.
    var zoom: Double = 1 { didSet { if zoom != oldValue { persist() } } }
    /// Whether a new message settles in with a short animation (Settings); Reduce Motion trims it further.
    var animateMessages: Bool { didSet { if animateMessages != oldValue { defaults.set(animateMessages, forKey: "Mosaic.animateMessages") } } }
    /// New messages being addressed, by tile id ("new-…"), before they have a conversation.
    var composeDrafts: [String: ComposeDraft] = [:] { didSet { if composeDrafts != oldValue { persist() } } }
    /// Every contact with its handles, for addressing new messages.
    var contactEntries: [ContactNames.Entry] = []
    var search = ""
    var isLive = false
    /// Messages is being read for the first time since launch (or since switching to it): the
    /// window shows that it is loading rather than an empty workspace that asks to connect.
    /// Over once a load succeeds or fails.
    /// Settable within the app only for the preview renderer's loading state.
    var isLoadingConversations = false
    /// Why Messages cannot be read right now. Shown where there is room for it — the empty
    /// workspace and the connection settings — and announced in an alert when conversations are
    /// on screen (the window's title area never carries messages).
    var connectionError: String?
    /// A modal message for something that cannot be done right now.
    var alert: WorkspaceAlert?
    var sendErrors: [String: String] = [:]
    /// Files in each tile's composer, in the order they were added, to go out with the next
    /// message — including the ones still on their way in (a photo being fetched from the
    /// library, a pasted picture being written) and the ones that could not be added.
    var outgoing: [String: [OutgoingAttachment]] = [:] { didSet { if outgoing != oldValue { persist() } } }
    /// A line under a composer about its send: waiting for photos, or why a send stopped.
    var sendNotes: [String: String] = [:]
    var showSetup = false
    /// How many messages each open tile asked to show (100, then 100 more each time it scrolls
    /// back, up to 1,000). Loads read only each tile's newest 100; the earlier ones a tile paged
    /// in are kept above them (see `keepingEarlier`).
    var historyLimits: [String: Int] = [:]
    var isLoadingContacts = false
    var contactStatus: String?
    /// Whether Mosaic may read Contacts, as last asked (off the main thread; "not determined" until then).
    private(set) var contactAuthorization: CNAuthorizationStatus = .notDetermined
    /// The tile being dragged and the order a release would give. Not observed: the pointer moves
    /// it on every frame. What views read is published from it below, so the workspace re-renders
    /// only when the order changes, and the pointer's movement changes one transform.
    @ObservationIgnored var tileDrag: TileDragSession? { didSet { publishDrag() } }
    /// The held tile, its size and the order a release would give: changes when a drag begins,
    /// ends, or the held tile crosses into another tile's place.
    private(set) var heldTile: HeldTile?
    /// Where the held tile is now; read only by the held tile's position.
    let dragMotion = TileDragMotion()
    /// The tile shown lifted (slightly larger, with a deeper shadow): the held one, and then the
    /// released one until it has settled into its place.
    private(set) var liftedTile: String?
    /// Tiles springing from where they were to their new place, after a reorder or a release:
    /// offsets from the new place, animated to zero.
    private(set) var tileSprings: [String: CGSize] = [:]
    /// Lays out an order in the workspace's current size and proportions (set by the workspace
    /// view), so a reorder knows where each tile was and where it goes.
    @ObservationIgnored var tilePlanner: (([String]) -> TilePlan)?
    /// Whether tile motion springs; off with Reduce Motion (tiles then move in one step).
    @ObservationIgnored var tileMotionEnabled: () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The sidebar row the keyboard is on, while the conversation list has keyboard focus (⌘L, or
    /// an arrow key from the search field). Nil whenever the list does not have the keyboard. The
    /// pointer never highlights a row; only the keyboard does.
    var sidebarSelection: String?
    /// Whether a sideways swipe (a row's Delete action) is under way or has left its action
    /// showing. The keyboard's highlight stays off meanwhile, so none sits against the action.
    var sidebarSwiping = false
    /// The one highlighted sidebar row: the keyboard's, except during a swipe.
    var highlightedSidebarRow: String? { sidebarSwiping ? nil : sidebarSelection }
    /// Keyboard traversal: the tile whose composer should take focus, and a token that changes per request.
    private(set) var focusTarget: String?
    private(set) var focusToken = 0

    /// Recently shown histories, so a tile opens on its messages at once instead of waiting for
    /// a load: kept in memory only (never written anywhere), at most `historyCacheLimit`
    /// conversations, the least recently used dropped first. A cached history is shown as it was
    /// and brought up to date by the load that follows.
    @ObservationIgnored private var historyCache: [String: (page: ThreadPage, used: Int)] = [:]
    @ObservationIgnored private var prefetchedRecent = false
    /// Conversations waiting to be fetched ahead, the most wanted last (`hovered` marks the ones
    /// the pointer asked for), and the one being fetched. One read ahead runs at a time, so they
    /// never pile up in the reader's queue in front of a conversation being opened.
    @ObservationIgnored private var prefetchWaiting: [(id: String, hovered: Bool)] = []
    @ObservationIgnored private var prefetchRunning: String?
    /// Tiles opening on a fresh read of their history; reads ahead wait for them.
    @ObservationIgnored private var openingReads = 0
    /// The row the pointer rests on, and the pause before its history is fetched ahead.
    @ObservationIgnored private var hoveredRow: String?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    /// Reads ahead that ran (tests).
    @ObservationIgnored private(set) var prefetchReadCount = 0
    /// Launches that showed the list before the full load (tests).
    @ObservationIgnored private(set) var listShownFirstCount = 0
    /// How long the pointer rests on a row before its history is fetched ahead.
    static let hoverDelay: Duration = .milliseconds(150)
    /// The most reads ahead kept waiting; older wishes are dropped first.
    static let prefetchWaitLimit = 8
    static let historyCacheLimit = 16

    // Bookkeeping no view reads.
    /// When each tile was last used — opened, focused, typed in, sent from — as a running count,
    /// so a fifth conversation can take the place of the tile used longest ago.
    @ObservationIgnored private var lastUsed: [String: Int] = [:]
    @ObservationIgnored private var useCount = 0
    @ObservationIgnored var isRefreshing = false
    @ObservationIgnored private(set) var lastRefreshed: Date?
    @ObservationIgnored private var refreshRequestedWhileBusy = false
    /// Callers waiting for the load that follows the running one.
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    /// Transient read failures (Messages writing to the database) keep the last good data; the
    /// connection error only shows once reads keep failing or the first connection never succeeded.
    @ObservationIgnored private(set) var consecutiveLoadFailures = 0
    static let failuresBeforeError = 3
    private let defaults: UserDefaults
    private let database: MessagesDatabase
    /// Contacts and the outgoing folders: the system's in the installed app, a fixture run's own otherwise.
    @ObservationIgnored let services: StoreServices
    /// How messages leave Mosaic: Messages' AppleScript dictionary when live, nowhere in the demo,
    /// and whatever a test injects.
    @ObservationIgnored private let liveTransport: MessageTransport
    @ObservationIgnored private let demoTransport = DemoTransport()
    var transport: MessageTransport { isLive ? liveTransport : demoTransport }
    /// Submissions go to Messages one at a time, in the order Return accepted them.
    @ObservationIgnored private var submissionChain: Task<Void, Never> = Task {}
    /// Messages accepted by Return and not yet handed to Messages (or refused).
    @ObservationIgnored private(set) var submissionsInFlight = 0
    /// Sends waiting for a composer's photos to finish arriving.
    @ObservationIgnored private var importWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The cadence the running poll was started with; a faster need restarts it at once.
    @ObservationIgnored private var scheduledPollInterval: Duration?
    /// Whether Mosaic is the active app; the fallback poll slows down while it is not.
    @ObservationIgnored private var appActive = true
    /// When the current burst of database writes began and when its refresh is due.
    @ObservationIgnored private var burstStarted: ContinuousClock.Instant?
    @ObservationIgnored private var watchDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileChangeWatcher?
    @ObservationIgnored private var watchRefreshTask: Task<Void, Never>?
    /// What the last successful load covered; a poll skips the load when the database's fingerprint
    /// still matches and the request (open tiles, history depth) is the same.
    @ObservationIgnored private var lastLoad: ChangeToken?
    /// The one reader of Messages' database: one connection, kept open, with change detection on it.
    @ObservationIgnored private let reader: MessagesReader
    @ObservationIgnored private var contactNames = ContactNames()
    @ObservationIgnored private var originalTitles: [String: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingState = true
    // Submitted sends are held in memory until the database reports them; never auto-retry a send.
    @ObservationIgnored private var pending: [String: [Message]] = [:]
    @ObservationIgnored private var connectedBefore = false
    private let forcedDemo: Bool

    /// Everything left out comes from `StoreServices.processDefault`: the installed app reads the
    /// signed-in Messages database, Contacts and its own preferences and sends through Messages; a
    /// fixture run (the tests, the preview, a `--demo` or `--isolated` launch) reads only what it
    /// is given, keeps its preferences and files apart from the app's, and cannot send.
    init(defaults: UserDefaults? = nil, database: MessagesDatabase? = nil, forceDemo: Bool = false,
         transport: MessageTransport? = nil, services: StoreServices = .processDefault) {
        let isolated = MosaicRuntime.isIsolated
        let defaults = defaults ?? (isolated ? UserDefaults(suiteName: MosaicRuntime.isolatedDefaultsSuite) ?? .standard : .standard)
        let database = database ?? (isolated ? MessagesDatabase(path: MosaicRuntime.isolatedRoot.appending(path: "chat.db").path) : MessagesDatabase())
        self.defaults = defaults; self.database = database; self.services = services
        liveTransport = transport ?? (isolated ? UnavailableTransport() : AppleScriptTransport())
        animateMessages = defaults.object(forKey: "Mosaic.animateMessages") as? Bool ?? true
        reader = MessagesReader(database: database)
        forcedDemo = forceDemo || ProcessInfo.processInfo.arguments.contains("--demo")
        // Live unless the demo workspace was chosen: a fresh install starts with an empty workspace
        // whose "Connect Messages" leads to the connection settings. Nothing opens or asks on
        // launch — no settings sheet, no Contacts prompt (that waits for the settings' button).
        isLive = !forcedDemo && (defaults.object(forKey: "Mosaic.live") as? Bool ?? true)
        if isLive {
            isLoadingConversations = true
            restore()
            // Messages and Contacts load side by side; names apply to the conversations as they arrive.
            Task { await self.refresh() }
            Task { await self.loadContacts(requestPermission: false) }
        } else {
            conversations = DemoData.conversations(imagePaths: DemoAssets.imagePaths())
            restore(defaultIDs: Array(conversations.prefix(4).map(\.id)))
        }
        loadingState = false
        // Leftovers from earlier runs go, off the main thread — never a file a saved draft (this
        // workspace's or the other one's) still points at.
        OutgoingFiles.purgeStaleInBackground(in: services.outgoing, keeping: SavedDrafts.referencedPaths(in: defaults)
            .union(outgoing.values.joined().compactMap { $0.url?.path }))
        // What Contacts allows is asked off the main thread: a slow answer holds up nothing.
        Task { [weak self] in
            guard let self else { return }
            let status = await self.services.contacts.authorizationStatus()
            if self.contactAuthorization != status { self.contactAuthorization = status }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                await self.loadContacts(requestPermission: false)
            }
        })
        // Contacts may be switched on in System Settings while Mosaic is open; pick that up on return.
        // Coming back also checks Messages at once and returns the poll to its active cadence.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.setAppActive(true)
                let status = await self.services.contacts.authorizationStatus()
                let changed = status != self.contactAuthorization
                self.contactAuthorization = status
                if changed, self.isLive, status == .authorized { await self.loadContacts(requestPermission: false) }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistNow() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(false) }
        })
        // After sleep the watcher may have missed writes; look once on wake.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        wakeObserver = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                await self.refresh()
            }
        }
        startPolling()
    }

    /// The poll is a fallback: changes are normally picked up within a moment by the file watcher.
    /// Its cadence follows `RefreshPolicy` and is chosen again after every check.
    private func startPolling() {
        pollTask?.cancel()
        let first = pollInterval
        scheduledPollInterval = first
        pollTask = Task { [weak self] in
            var interval = first
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
                if self.isLive { await self.refresh(background: !self.appActive) }
                interval = self.pollInterval
                self.scheduledPollInterval = interval
            }
        }
    }
    private var pollInterval: Duration {
        RefreshPolicy.pollInterval(appActive: appActive, awaitingConfirmation: pending.values.contains { !$0.isEmpty })
    }
    /// Restarts the poll when a quicker cadence is wanted now; a slower one waits for the next tick.
    private func pollCadenceMayHaveChanged() {
        guard let scheduled = scheduledPollInterval, pollInterval < scheduled else { return }
        startPolling()
    }
    private func setAppActive(_ active: Bool) {
        guard appActive != active else { return }
        appActive = active
        if active, isLive { Task { await self.refresh() } }
        pollCadenceMayHaveChanged()
    }

    deinit {
        pollTask?.cancel()
        persistTask?.cancel()
        watchRefreshTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// The persisted shape of the workspace (open tiles, focus, layout, drafts, seen messages).
    var workspace: Workspace {
        get {
            var state = Workspace()
            state.openIDs = openIDs; state.focusedID = focusedID; state.layout = layout
            state.drafts = drafts; state.seenMessageIDs = seenMessageIDs; state.hidden = hidden
            state.zoom = zoom
            return state
        }
        set {
            if openIDs != newValue.openIDs { openIDs = newValue.openIDs }
            if focusedID != newValue.focusedID { focusedID = newValue.focusedID }
            if layout != newValue.layout { layout = newValue.layout }
            if drafts != newValue.drafts { drafts = newValue.drafts }
            if seenMessageIDs != newValue.seenMessageIDs { seenMessageIDs = newValue.seenMessageIDs }
            if hidden != newValue.hidden { hidden = newValue.hidden }
            if zoom != newValue.zoom { zoom = newValue.zoom }
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
        guard let held = heldTile else { return openIDs }
        let open = Set(openIDs)
        var order = held.order.filter { open.contains($0) }
        order += openIDs.filter { !order.contains($0) }
        return order
    }

    func open(_ id: String) {
        var opened = false
        instantly {
            mutate { opened = $0.open(id) }
            // Every tile taken: the one used longest ago gives up its place to the new one.
            if !opened, let victim = tileToReplace() {
                evict(victim)
                mutate { $0.replace(victim, with: id) }
                opened = true
            }
        }
        guard opened else { return }
        // Not marked read here: the thread reports when its newest message is actually in view.
        noteUse(id)
        guard isLive else { return }
        showHistoryAtOnce(id)
        Task { await refresh() }
    }

    // MARK: History cache

    /// A tile that just opened shows its messages now: from the cache when they were shown or
    /// fetched recently, else from a fetch of that one conversation, which is far quicker than the
    /// full load that follows.
    private func showHistoryAtOnce(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].messages.isEmpty else { return }
        if let cached = historyCache[id] {
            apply(cached.page, to: id)
            touchCache(id)
            return
        }
        // Being fetched ahead right now: that read brings it (see `startNextPrefetch`).
        if prefetchRunning == id { return }
        // Otherwise it is read now, ahead of any read ahead still waiting.
        prefetchWaiting.removeAll { $0.id == id }
        openingReads += 1
        let reader = self.reader
        let requestGeneration = generation
        Task {
            let page = try? await reader.page(forChat: id, limit: Self.pageSize)
            guard generation == requestGeneration else { return }
            openingReads -= 1
            if let page {
                remember(page, for: id)
                apply(page, to: id)
            }
            startNextPrefetch()
        }
    }
    /// Puts a fetched or cached page into a conversation that has no history on screen yet.
    private func apply(_ page: ThreadPage, to id: String) {
        guard openIDs.contains(id), let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].messages.isEmpty, !page.messages.isEmpty else { return }
        instantly {
            conversations[index].messages = page.messages
            conversations[index].reactions = page.reactions
            conversations[index].referencedMessages = page.referencedMessages
        }
    }
    /// Keeps a conversation's newest page for its next opening (a tile opens on its newest 100;
    /// earlier messages it scrolled back for are not kept here).
    private func remember(_ page: ThreadPage, for id: String) {
        guard !page.messages.isEmpty else { return }
        useCount += 1
        let newest = page.messages.count > Self.pageSize
            ? ThreadPage(messages: Array(page.messages.suffix(Self.pageSize)), reactions: page.reactions, referencedMessages: page.referencedMessages)
            : page
        historyCache[id] = (newest, useCount)
        if historyCache.count > Self.historyCacheLimit, let oldest = historyCache.min(by: { $0.value.used < $1.value.used })?.key {
            historyCache[oldest] = nil
        }
    }
    private func touchCache(_ id: String) {
        guard var entry = historyCache[id] else { return }
        useCount += 1
        entry.used = useCount
        historyCache[id] = entry
    }
    /// The pointer came to rest on a row: its history is fetched ahead after a short pause, so the
    /// tile opens on its messages — and a sweep down the list fetches nothing.
    func pointerEntered(_ id: String) {
        hoverTask?.cancel()
        hoveredRow = id
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: WorkspaceStore.hoverDelay)
            guard !Task.isCancelled, let self, self.hoveredRow == id else { return }
            self.hoverTask = nil
            self.prefetch(id, hovered: true)
        }
    }
    /// The pointer left a row: a pause not over yet fetches nothing, and a read it asked for that
    /// has not started is dropped.
    func pointerExited(_ id: String) {
        guard hoveredRow == id else { return }
        hoveredRow = nil
        hoverTask?.cancel()
        hoverTask = nil
        prefetchWaiting.removeAll { $0.id == id && $0.hovered }
    }
    /// Fetches a conversation's history ahead of opening it, so the tile opens on its messages.
    /// Reads ahead go one at a time, the most recently wanted first, and wait while a tile opens
    /// on a fresh read.
    func prefetch(_ id: String, hovered: Bool = false) {
        enqueuePrefetch(id, hovered: hovered)
        startNextPrefetch()
    }
    private func enqueuePrefetch(_ id: String, hovered: Bool = false) {
        guard isLive, historyCache[id] == nil, prefetchRunning != id, !openIDs.contains(id),
              conversations.contains(where: { $0.id == id }) else { return }
        prefetchWaiting.removeAll { $0.id == id }
        prefetchWaiting.append((id, hovered))
        if prefetchWaiting.count > Self.prefetchWaitLimit { prefetchWaiting.removeFirst(prefetchWaiting.count - Self.prefetchWaitLimit) }
    }
    private func startNextPrefetch() {
        while prefetchRunning == nil, openingReads == 0, let next = prefetchWaiting.popLast() {
            let id = next.id
            // Opened or cached since it was wanted: nothing to fetch.
            guard isLive, historyCache[id] == nil, !openIDs.contains(id) else { continue }
            prefetchRunning = id
            prefetchReadCount += 1
            let reader = self.reader
            let requestGeneration = generation
            Task {
                let page = try? await reader.page(forChat: id, limit: Self.pageSize)
                guard generation == requestGeneration else { return }
                prefetchRunning = nil
                if let page {
                    remember(page, for: id)
                    // Opened while it was being read: the tile shows it now.
                    apply(page, to: id)
                }
                startNextPrefetch()
            }
        }
    }
    /// Whether reads ahead are running or waiting (tests).
    var isFetchingAhead: Bool { prefetchRunning != nil || !prefetchWaiting.isEmpty }
    /// Whether a read ahead for this conversation is waiting its turn (tests).
    func isWaitingToFetchAhead(_ id: String) -> Bool { prefetchWaiting.contains { $0.id == id } }
    /// Whether a conversation's history is ready to show at once (tests).
    func hasCachedHistory(_ id: String) -> Bool { historyCache[id] != nil }
    /// Which open tile a new conversation replaces when every tile is taken: the one used longest
    /// ago (the first on screen among equals). An unsent New Message is kept unless nothing else is open.
    func tileToReplace() -> String? {
        let candidates = openIDs.filter { composeDrafts[$0] == nil }
        let pool = candidates.isEmpty ? openIDs : candidates
        return pool.min { (lastUsed[$0] ?? 0, openIDs.firstIndex(of: $0) ?? 0) < (lastUsed[$1] ?? 0, openIDs.firstIndex(of: $1) ?? 0) }
    }
    /// Lets go of a tile's transient state ahead of its replacement (its draft text is kept, as on close).
    private func evict(_ victim: String) {
        if tileDrag?.id == victim { tileDrag = nil }
        if focusTarget == victim { focusTarget = nil }
        let isNewMessage = composeDrafts[victim] != nil
        if isNewMessage { composeDrafts[victim] = nil; drafts[victim] = nil }
        releaseComposer(victim, keepingFiles: !isNewMessage)
        releaseTileState(victim)
    }
    /// A closed tile's history goes back to the standard depth (the next load releases the rest).
    private func releaseTileState(_ id: String) {
        historyLimits[id] = nil
        if tilesWithNews.contains(id) { tilesWithNews.remove(id) }
    }
    /// The newest database row among `messages` (bubbles still being sent are not rows yet).
    static func newestRow(in messages: [Message]) -> Int64? {
        messages.compactMap { $0.sendState == nil ? Int64($0.id) : nil }.max()
    }
    /// Whether `messages` hold an incoming message newer than row `newest`: a text or file from
    /// someone else, not a reaction, activity or unsent message.
    static func receivedMessage(in messages: [Message], after newest: Int64) -> Bool {
        messages.contains { !$0.isFromMe && $0.kind == .message && !$0.isUnsent && $0.sendState == nil && (Int64($0.id) ?? 0) > newest }
    }
    /// A closed or replaced conversation keeps the files ready in its composer, as it keeps its
    /// text: they are there again when it opens. A photo still arriving lands nowhere (its file
    /// is removed when it does), a failed add is forgotten, and a send waiting for photos stops
    /// waiting. A New Message tile's files go with it; Mosaic's own copies of them are removed.
    private func releaseComposer(_ id: String, keepingFiles: Bool) {
        let files = outgoing[id] ?? []
        let kept = keepingFiles ? files.filter { $0.state == .ready || $0.isMissing } : []
        let keptIDs = Set(kept.map(\.id))
        for file in files where !keptIDs.contains(file.id) && ownsFile(file) {
            if let url = file.url { try? FileManager.default.removeItem(at: url) }
        }
        if outgoing[id] != nil { outgoing[id] = kept.isEmpty ? nil : kept }
        sendNotes[id] = nil
        resumeImportWaiters(for: id)
    }
    /// Whether a composer's file is one this store wrote (and may remove), never one the user chose.
    func ownsFile(_ file: OutgoingAttachment) -> Bool { file.url.map(services.outgoing.owns) ?? false }
    private func noteUse(_ id: String) {
        useCount += 1
        lastUsed[id] = useCount
    }
    func close(_ id: String) {
        instantly {
            if tileDrag?.id == id { tileDrag = nil }
            mutate { $0.close(id) }
            let isNewMessage = composeDrafts[id] != nil
            if isNewMessage { composeDrafts[id] = nil; drafts[id] = nil }
            releaseComposer(id, keepingFiles: !isNewMessage)
            releaseTileState(id)
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
        // Focusing a tile scrolled up in history does not read what is below.
        noteUse(id)
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
        if sidebarSelection != target { instantly { sidebarSelection = target } }
    }
    /// A sideways swipe began or ended.
    func setSidebarSwiping(_ swiping: Bool) {
        if sidebarSwiping != swiping { instantly { sidebarSwiping = swiping } }
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
        if sidebarSelection != rows[target].id { instantly { sidebarSelection = rows[target].id } }
    }
    /// Return on the keyboard's row (or the first search result): opens it in a tile — taking the
    /// place of the tile used longest ago when every tile is taken — or focuses its tile when it
    /// is already open.
    /// Return on the keyboard's row (or in the search field): opens the conversation in a tile,
    /// or finds its tile, and puts the keyboard in that tile's composer, ready to type.
    func activateSidebarSelection() {
        guard let id = sidebarSelection ?? (search.isEmpty ? nil : filteredConversations.first?.id) else { return }
        openAndType(id)
    }
    /// Opening a conversation from the list (a click, Return, a drag onto a tile, the menu): it
    /// gets a tile — free space, or the place of the tile used longest ago — or its tile is
    /// found, and the cursor goes into that tile's message field, ready to type.
    func openAndType(_ id: String) {
        if !openIDs.contains(id) { open(id) }
        requestComposerFocus(id)
    }
    /// Delete on the keyboard's row: closes that conversation's tile, if it has one. The
    /// conversation itself stays in the list.
    func untileSidebarSelection() {
        guard let id = sidebarSelection, openIDs.contains(id) else { return }
        close(id)
    }
    func setLayout(_ layout: WorkspaceLayout) { instantly { tileDrag = nil; self.layout = layout } }

    // MARK: Zoom

    /// The one action path for ⌘+/⌘−/⌘0, the Workspace menu and anything else: every tile shows
    /// the same scale, clamped to the offered steps.
    func setZoom(_ value: Double) {
        let clamped = Workspace.clampZoom(value)
        if zoom != clamped { instantly { zoom = clamped } }
    }
    func zoomIn() { setZoom(zoom + Workspace.zoomStep) }
    func zoomOut() { setZoom(zoom - Workspace.zoomStep) }
    func resetZoom() { setZoom(1) }
    var canZoomIn: Bool { zoom < Workspace.zoomRange.upperBound - 0.001 }
    var canZoomOut: Bool { zoom > Workspace.zoomRange.lowerBound + 0.001 }
    /// "120%", for the menu.
    var zoomLabel: String { "\(Int((zoom * 100).rounded()))%" }
    // MARK: Tile drag

    /// The spring tiles move with: quick, settling without a wobble.
    static let tileSpring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    /// The pointer moved with a tile held. The tile follows the pointer exactly; when it crosses
    /// into another tile's place, the tiles between spring to their new places.
    func dragTile(_ id: String, translation: CGSize, plan: TilePlan) {
        guard layout != .focus, let frame = plan.frames[id] else { return }
        // Only one tile can be held. A session for another tile is stale (its release was never reported).
        if tileDrag?.id != id {
            instantly { tileDrag = TileDragSession(id: id, origin: frame, order: openIDs) }
            // Picked up: the tile lifts off the board.
            if tileMotionEnabled() { withAnimation(Self.tileSpring) { liftedTile = id } } else { instantly { liftedTile = id } }
        }
        guard var drag = tileDrag else { return }
        let before = drag.order
        drag.update(translation: translation, plan: plan)
        let springs = drag.order == before ? [:] : springOffsets(from: before, to: drag.order, except: id)
        instantly {
            tileDrag = drag
            if !springs.isEmpty { tileSprings.merge(springs) { _, new in new } }
        }
        if !springs.isEmpty { settleSprings() }
    }
    /// The held tile was let go: the order is committed and the tile springs from where it was
    /// dropped into its place, coming back down as it lands.
    func finishTileDrag(_ id: String? = nil) {
        guard let drag = tileDrag, id == nil || drag.id == id else { return }
        let order = displayOrder
        var springs: [String: CGSize] = [:]
        if tileMotionEnabled(), let end = tilePlanner?(order).frames[drag.id] {
            springs[drag.id] = CGSize(width: drag.frame.minX - end.minX, height: drag.frame.minY - end.minY)
        }
        instantly {
            if openIDs != order { openIDs = order }
            tileSprings.merge(springs) { _, new in new }
            settlingTile = springs.isEmpty ? nil : drag.id
            tileDrag = nil
        }
        if springs.isEmpty { instantly { liftedTile = nil } } else { settleSprings(landing: drag.id) }
    }
    /// The tile just released, while it springs into place (it stays above the others).
    private(set) var settlingTile: String?
    @ObservationIgnored private var springGeneration = 0
    /// Where each moved tile was, relative to its new place: the start of its spring.
    private func springOffsets(from old: [String], to new: [String], except held: String) -> [String: CGSize] {
        guard tileMotionEnabled(), let planner = tilePlanner else { return [:] }
        let before = planner(old).frames, after = planner(new).frames
        var springs: [String: CGSize] = [:]
        for (id, start) in before where id != held {
            guard let end = after[id], start.origin != end.origin else { continue }
            springs[id] = CGSize(width: start.minX - end.minX, height: start.minY - end.minY)
        }
        return springs
    }
    /// On the next turn — after the new places are laid out with the offsets holding the tiles
    /// where they were — the offsets spring to zero.
    private func settleSprings(landing: String? = nil) {
        springGeneration += 1
        let generation = springGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(Self.tileSpring, completionCriteria: .logicallyComplete) {
                self.tileSprings = [:]
                if let landing, self.liftedTile == landing { self.liftedTile = nil }
            } completion: { [weak self] in
                guard let self, generation == self.springGeneration else { return }
                self.settlingTile = nil
            }
        }
    }
    /// Publishes what views read of the drag: the held tile and order when they change, and the
    /// held tile's place on every move.
    private func publishDrag() {
        let held = tileDrag.map { HeldTile(id: $0.id, size: $0.origin.size, order: $0.order) }
        if held != heldTile { heldTile = held }
        if let drag = tileDrag {
            if dragMotion.origin != drag.frame.origin { dragMotion.origin = drag.frame.origin }
        } else if liftedTile != nil, liftedTile != settlingTile {
            // Ended some other way (the tile closed, the layout changed): nothing settles.
            liftedTile = nil
        }
    }
    func draft(_ id: String) -> Binding<String> {
        Binding(get: { self.drafts[id] ?? "" }, set: { if self.drafts[id] ?? "" != $0 { self.drafts[id] = $0; self.noteUse(id) } })
    }
    /// Everything in the conversation up to its newest row has been seen: the unread count clears
    /// and the seen boundary moves to that row. Called when a thread's newest message is in view,
    /// and after sending (sending is reading).
    func markSeen(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if conversations[index].unreadCount != 0 { conversations[index].unreadCount = 0 }
        let loadedNewest = conversations[index].messages.reversed().lazy.compactMap { Int64($0.id) }.first ?? 0
        let newest = max(conversations[index].lastMessageID, loadedNewest)
        if newest > 0 {
            if (seenBoundary(id) ?? 0) < newest { seenMessageIDs[id] = String(newest) }
        } else if let last = conversations[index].messages.last, seenMessageIDs[id] != last.id {
            seenMessageIDs[id] = last.id // the demo's ids are not rows
        }
    }
    /// The newest row seen in a conversation, when it is a database row.
    func seenBoundary(_ id: String) -> Int64? { seenMessageIDs[id].flatMap { Int64($0) } }
    func setMode(live: Bool) {
        // Not while messages are being handed over: the rest of a batch must not go elsewhere.
        guard live != isLive, submissionsInFlight == 0 else { return }
        persistNow(); generation += 1; isLive = live; connectedBefore = false; consecutiveLoadFailures = 0; lastLoad = nil
        connectionError = nil; sendErrors = [:]; pending = [:]; search = ""; tileDrag = nil; originalTitles = [:]
        focusTarget = nil; composeDrafts = [:]
        historyCache = [:]; prefetchedRecent = false; tilesWithNews = []; loadingMore = []
        prefetchWaiting = []; prefetchRunning = nil; openingReads = 0; hoveredRow = nil; hoverTask?.cancel(); hoverTask = nil
        defaults.set(live, forKey: "Mosaic.live")
        loadingState = true
        isLoadingConversations = live
        if live {
            conversations = []; restore()
            Task { await refresh() }
            Task { await loadContacts(requestPermission: contactAuthorization == .notDetermined) }
        } else {
            watcher = nil
            conversations = DemoData.conversations(imagePaths: DemoAssets.imagePaths())
            restore(defaultIDs: Array(conversations.prefix(4).map(\.id)))
        }
        loadingState = false
    }

    /// Reloads conversations and open histories. A request that arrives while a load is running is
    /// not dropped: one more load follows, so a tile opened mid-poll gets its history right away,
    /// and the request returns once that load is done (a caller that awaits it sees what was in the
    /// database when it asked). `background` marks a fallback poll while Mosaic is not the active
    /// app; its read runs at utility priority.
    func refresh(background: Bool = false) async {
        guard isLive else { return }
        if isRefreshing {
            refreshRequestedWhileBusy = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiting = refreshWaiters
            refreshWaiters = []
            for continuation in waiting { continuation.resume() }
        }
        var background = background
        repeat {
            refreshRequestedWhileBusy = false
            await performRefresh(background: background)
            background = false
        } while refreshRequestedWhileBusy && isLive
    }

    private func performRefresh(background: Bool = false) async {
        let requestGeneration = generation
        defer {
            if isLoadingConversations, generation == requestGeneration, connectedBefore || connectionError != nil {
                isLoadingConversations = false
            }
        }
        // The first read since launch shows the list first: it takes a fraction of the full load,
        // which then reads the open tiles' histories (each says it is loading meanwhile).
        if conversations.isEmpty, !connectedBefore {
            await showListFirst(background: background)
            guard generation == requestGeneration, isLive else { return }
        }
        // Each open tile's newest 100 messages; earlier ones a tile paged in are not read again,
        // only the reactions on them. The reader skips the load when nothing was committed since
        // the last one and the request is the same.
        let request = LoadRequest(openIDs: Set(openIDs), historyLimits: [:], defaultHistoryLimit: Self.pageSize,
                                  seenBoundaries: seenMessageIDs.compactMapValues { Int64($0) }, earlierRows: earlierRowsShown())
        do {
            let snapshot = try await reader.load(request, unlessUnchangedFrom: lastLoad, background: background)
            guard generation == requestGeneration, isLive else { return }
            consecutiveLoadFailures = 0
            if connectionError != nil { connectionError = nil }
            connectedBefore = true; lastRefreshed = Date()
            startWatchingDatabase()
            guard let snapshot else { return } // unchanged since the last load
            lastLoad = snapshot.token
            let ids = request.openIDs
            var loaded = snapshot.conversations
            let previousByID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var newBoundaries: [String: String] = [:]
            var arrivals = Set<String>()
            for index in loaded.indices {
                let id = loaded[index].id
                originalTitles[id] = loaded[index].name
                loaded[index].name = contactNames.title(for: loaded[index])
                let previous = previousByID[id]
                // A tile opened while this load was under way: the load had no history for it, so
                // the history it already shows stays (no empty flash) until the next load brings it.
                if !ids.contains(id), openIDs.contains(id), let previous, !previous.messages.isEmpty {
                    loaded[index].messages = previous.messages
                    loaded[index].reactions = previous.reactions
                    loaded[index].referencedMessages = previous.referencedMessages
                }
                // A tile that scrolled back keeps the earlier messages it shows above the newest
                // page, which is all a load reads.
                if ids.contains(id), let depth = historyLimits[id], depth > Self.pageSize, let previous {
                    if let kept = Self.keepingEarlier(of: previous, in: loaded[index], depth: depth,
                                                      lookedUp: request.earlierRows[id]?.guids ?? []) {
                        loaded[index] = kept
                    } else if !loadingMore.contains(id) {
                        // More than a page arrived at once: what the tile showed no longer meets
                        // the newest page. It starts over from there rather than show a gap.
                        historyLimits[id] = nil
                    }
                }
                // Remove a submitted bubble when an outgoing row with the same text and a recent date appears.
                let reconciled = MessageReconciler.merge(loaded: loaded[index].messages, previous: previous?.messages ?? [], pending: pending[id] ?? [])
                pending[id] = reconciled.pending
                loaded[index].messages = reconciled.messages
                // A message arrived in an open tile the reader is not in: its header shows a dot.
                if openIDs.contains(id), id != focusedID, let previous, let newest = Self.newestRow(in: previous.messages),
                   Self.receivedMessage(in: loaded[index].messages, after: newest) {
                    arrivals.insert(id)
                }
                // Unread counts are counted by the reader from the seen boundary: every incoming
                // message after it, repeated texts and files included. A conversation seen for the
                // first time starts with its newest row as seen (Messages keeps its own unread state).
                if seenBoundary(id) == nil {
                    loaded[index].unreadCount = 0
                    if loaded[index].lastMessageID > 0 { newBoundaries[id] = String(loaded[index].lastMessageID) }
                }
            }
            if !newBoundaries.isEmpty { seenMessageIDs.merge(newBoundaries) { current, _ in current } }
            if !arrivals.subtracting(tilesWithNews).isEmpty { tilesWithNews.formUnion(arrivals) }
            // Publishing identical data re-rendered every tile; only publish real changes.
            if loaded != conversations { instantly { conversations = loaded } }
            // What the open tiles show now is what they will open on next time.
            for conversation in loaded where ids.contains(conversation.id) && !conversation.messages.isEmpty {
                remember(ThreadPage(messages: conversation.messages.filter { $0.sendState == nil }, reactions: conversation.reactions,
                                    referencedMessages: conversation.referencedMessages), for: conversation.id)
            }
            // After the first load, the most recent conversations are fetched ahead, so the ones
            // most likely to be opened open at once.
            if !prefetchedRecent {
                prefetchedRecent = true
                // The most recent is wanted most, so it is queued last (reads ahead take the last first).
                for conversation in loaded.prefix(8).reversed() where !ids.contains(conversation.id) { enqueuePrefetch(conversation.id) }
                startNextPrefetch()
            }
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
                // With conversations on screen there is nowhere quiet to show this: say it once, in
                // an alert, when the trouble starts. The empty workspace shows it otherwise.
                if connectionError == nil, !conversations.isEmpty {
                    alert = WorkspaceAlert(title: "Mosaic can't read Messages right now", message: error.localizedDescription)
                }
                connectionError = error.localizedDescription
            }
        }
    }

    /// The conversation list on its own (`LoadRequest.listOnly`), shown while nothing is on screen
    /// yet. A failure here is left to the full load that follows, which reports it.
    private func showListFirst(background: Bool) async {
        let requestGeneration = generation
        let request = LoadRequest(openIDs: Set(openIDs), defaultHistoryLimit: Self.pageSize,
                                  seenBoundaries: seenMessageIDs.compactMapValues { Int64($0) }, listOnly: true)
        guard let snapshot = try? await reader.load(request, unlessUnchangedFrom: nil, background: background),
              generation == requestGeneration, isLive, conversations.isEmpty else { return }
        listShownFirstCount += 1
        connectedBefore = true; consecutiveLoadFailures = 0
        if connectionError != nil { connectionError = nil }
        var list = snapshot.conversations
        for index in list.indices {
            originalTitles[list[index].id] = list[index].name
            list[index].name = contactNames.title(for: list[index])
            // As the full load does: a conversation seen for the first time has nothing unread.
            if seenBoundary(list[index].id) == nil { list[index].unreadCount = 0 }
        }
        instantly { conversations = list }
    }

    /// Refreshes within a moment of Messages writing to its database, instead of at the next poll.
    private func startWatchingDatabase() {
        guard watcher == nil else { return }
        watcher = FileChangeWatcher(paths: database.watchedPaths) { [weak self] in
            self?.databaseWritten()
        }
    }
    /// Messages writes in bursts; one refresh after the burst settles — but no later than
    /// `RefreshPolicy.maxWait` after the burst began, so a writer that never pauses still shows.
    private func databaseWritten() {
        let now = ContinuousClock.now
        let started = burstStarted ?? now
        burstStarted = started
        let deadline = RefreshPolicy.refreshDeadline(now: now, burstStarted: started)
        // At the cap the deadline stops moving: the refresh already due stands.
        if watchRefreshTask != nil, watchDeadline == deadline { return }
        watchDeadline = deadline
        watchRefreshTask?.cancel()
        watchRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.burstStarted = nil
            self.watchDeadline = nil
            self.watchRefreshTask = nil
            guard self.isLive else { return }
            await self.refresh()
        }
    }

    /// How many messages a load reads per tile, and how many each step back adds.
    static let pageSize = 100
    /// The most a tile shows.
    static let maximumHistory = 1000

    /// Loads the 100 messages before the oldest one a tile shows (up to 1,000 in all), one step
    /// at a time: the thread asks as the reader scrolls near the top of what is loaded. Only those
    /// rows are read — by a (date, row) cursor at the oldest shown message — and they are put
    /// above the others by message ID; nothing else is loaded again, in this tile or any other.
    func loadMore(_ id: String) {
        let shown = conversations.first(where: { $0.id == id })?.messages.filter { $0.sendState == nil } ?? []
        // The depth follows what the tile shows, whatever it asked for before.
        let depth = max(historyLimits[id] ?? Self.pageSize, shown.count)
        guard isLive, !loadingMore.contains(id), depth < Self.maximumHistory,
              let oldest = shown.first, let rowID = Int64(oldest.id) else { return }
        let step = min(Self.pageSize, Self.maximumHistory - depth)
        loadingMore.insert(id)
        historyLimits[id] = depth + step
        let reader = self.reader
        let requestGeneration = generation
        Task {
            let page = try? await reader.earlierPage(forChat: id, before: rowID, date: oldest.date, limit: step)
            loadingMore.remove(id)
            // The tile closed (or was replaced) meanwhile: its depth started over, and the page goes.
            guard generation == requestGeneration, openIDs.contains(id), historyLimits[id] == depth + step else { return }
            // Not readable now: the step can be asked for again.
            guard let page else { historyLimits[id] = depth; return }
            // The page joins the message it was read before; if that is no longer the oldest the
            // tile shows (a burst of new messages replaced them), it would leave a gap: it goes.
            let nowShown = conversations.first { $0.id == id }?.messages.filter { $0.sendState == nil } ?? []
            guard nowShown.first?.id == oldest.id else {
                historyLimits[id] = nowShown.count > Self.pageSize ? nowShown.count : nil
                return
            }
            addEarlier(page, to: id)
        }
    }
    /// Puts a page of earlier messages above what a tile shows, with their reactions and the
    /// originals their replies quote. A message the tile already has is not added twice.
    private func addEarlier(_ page: ThreadPage, to id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), !page.messages.isEmpty else { return }
        var conversation = conversations[index]
        let known = Set(conversation.messages.map(\.id))
        conversation.messages = page.messages.filter { !known.contains($0.id) } + conversation.messages
        let knownReactions = Set(conversation.reactions.map(\.id))
        conversation.reactions = page.reactions.filter { !knownReactions.contains($0.id) } + conversation.reactions
        conversation.referencedMessages.merge(page.referencedMessages) { current, _ in current }
        instantly { conversations[index] = conversation }
    }
    /// What a load needs to know of the earlier messages open tiles show above their newest page:
    /// which they are, so their reactions are looked up too.
    private func earlierRowsShown() -> [String: EarlierRows] {
        var rows: [String: EarlierRows] = [:]
        for id in openIDs where (historyLimits[id] ?? Self.pageSize) > Self.pageSize {
            guard let shown = conversations.first(where: { $0.id == id })?.messages.filter({ $0.sendState == nil }),
                  let oldest = shown.first else { continue }
            rows[id] = EarlierRows(guids: Set(shown.compactMap(\.guid)), oldest: oldest.date)
        }
        return rows
    }
    /// A loaded conversation with the earlier messages its tile showed above the newest page
    /// (`loaded` holds only that page): the database rows of `previous` older than the page's
    /// first message, by date and then row, up to `depth` messages in all. The reactions on
    /// those the load looked up (`lookedUp`) came with it; the others — a page that arrived
    /// while the load ran — keep theirs, as do the originals their replies quote. Nil when the
    /// page shares no message with what was shown (more than a page arrived at once), since the
    /// earlier messages would then not meet the page.
    static func keepingEarlier(of previous: Conversation, in loaded: Conversation, depth: Int, lookedUp: Set<String> = []) -> Conversation? {
        let page = loaded.messages
        guard let first = page.first else { return loaded }
        let inPage = Set(page.map(\.id))
        guard previous.messages.contains(where: { $0.sendState == nil && inPage.contains($0.id) }) else { return nil }
        let firstRow = Int64(first.id) ?? 0
        let earlier = previous.messages.filter { message in
            message.sendState == nil && !inPage.contains(message.id)
                && (message.date < first.date || (message.date == first.date && (Int64(message.id) ?? 0) < firstRow))
        }.suffix(max(0, depth - page.count))
        guard !earlier.isEmpty else { return loaded }
        var merged = loaded
        merged.messages = Array(earlier) + page
        let notLookedUp = Set(earlier.compactMap(\.guid)).subtracting(lookedUp)
        if !notLookedUp.isEmpty {
            merged.reactions = previous.reactions.filter { notLookedUp.contains($0.targetGUID) } + loaded.reactions
        }
        let quoted = Set(earlier.compactMap(\.replyToGUID))
        merged.referencedMessages = previous.referencedMessages.filter { quoted.contains($0.key) }
            .merging(loaded.referencedMessages) { _, current in current }
        return merged
    }
    /// The contact whose photo a one-to-one conversation (or a New Message to one person) shows.
    func contactPhotoID(for conversation: Conversation) -> String? {
        guard !conversation.isGroup, let handle = conversation.participants.first, !contactPhotoIDs.isEmpty else { return nil }
        return contactPhotoIDs[Recipient.key(for: handle)]
    }

    /// Return in a composer. The text and the files are taken from the composer at once — what is
    /// typed afterwards is a new message — and a bubble for each stands in the thread immediately,
    /// marked as being sent; then the items are handed to Messages one after another, in order.
    /// An item Messages refuses is marked so, kept on screen for the reader to retry, change or
    /// remove, and never resent by itself. A send waits for photos still arriving, and stops with
    /// a note when one could not be added rather than going out without it.
    func send(_ id: String) async {
        if composeDrafts[id] != nil { await sendCompose(id); return }
        guard conversations.contains(where: { $0.id == id }) else { return }
        guard await readyToSend(id) else { return }
        guard let batch = acceptSend(from: id, to: .chat(id), into: id) else { return }
        await submit(batch)
    }

    /// Waits for the composer's photos to finish arriving, then says whether a send may go: not
    /// while Messages is unreachable, and not with a file that could not be added.
    private func readyToSend(_ id: String) async -> Bool {
        guard canSend else { sendErrors[id] = "Connect Messages before sending."; return false }
        if outgoing[id]?.contains(where: { $0.state == .importing }) == true {
            instantly { sendNotes[id] = "Waiting for photos to finish adding…" }
            await awaitImports(id)
            instantly { sendNotes[id] = nil }
        }
        if let failed = outgoing[id]?.first(where: { $0.state.isFailed }) {
            sendErrors[id] = failed.isMissing ? "\(failed.name) is no longer on this Mac. Remove it, then send."
                : "\(failed.name) couldn't be added. Remove it or add it again, then send."
            return false
        }
        return openIDs.contains(id) || composeDrafts[id] != nil
    }

    /// What one Return sends: the files, then the text, each with the bubble that stands for it.
    struct Outbound {
        enum Item { case text(String), file(URL) }
        let target: SendTarget
        /// Where the bubbles live (the conversation, or a New Message tile until it has one).
        let threadID: String
        let items: [(item: Item, message: Message)]
    }

    /// Takes the composer's text and files, clears the composer, and puts a sending bubble for
    /// each item in the thread. Nil when there is nothing to send.
    private func acceptSend(from tileID: String, to target: SendTarget, into threadID: String) -> Outbound? {
        let originalDraft = drafts[tileID] ?? ""
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (outgoing[tileID] ?? []).filter { $0.state == .ready }
        guard !text.isEmpty || !files.isEmpty else { return nil }
        var items: [(item: Outbound.Item, message: Message)] = []
        let now = Date()
        for file in files {
            guard let url = file.url else { continue }
            var message = file.pendingMessage(date: now)
            message.sendState = .sending
            items.append((.file(url), message))
        }
        if !text.isEmpty {
            var message = Message(id: "pending-\(UUID().uuidString)", text: text, date: now, isFromMe: true)
            message.sendState = .sending
            items.append((.text(text), message))
        }
        let batch = Outbound(target: target, threadID: threadID, items: items)
        instantly {
            if drafts[tileID] == originalDraft { drafts[tileID] = tileID == threadID ? "" : nil }
            outgoing[tileID] = nil
            sendErrors[tileID] = nil
            place(batch.items.map(\.message), in: threadID, preview: Self.preview(text: text, files: files))
        }
        pending[threadID, default: []].append(contentsOf: batch.items.map(\.message))
        pollCadenceMayHaveChanged()
        noteUse(threadID)
        markSeen(threadID)
        return batch
    }
    /// Shows messages at the end of a thread (a conversation's history, or a New Message tile's sent list).
    private func place(_ messages: [Message], in threadID: String, preview: String) {
        if let index = conversations.firstIndex(where: { $0.id == threadID }) {
            conversations[index].messages.append(contentsOf: messages)
            conversations[index].preview = preview
            conversations[index].lastActivity = Date()
        } else if var draft = composeDrafts[threadID] {
            draft.sent.append(contentsOf: messages)
            draft.awaitingConversationSince = Date()
            composeDrafts[threadID] = draft
        }
    }

    /// Hands a batch to Messages item by item, after whatever was accepted before it. The first
    /// frame shows the bubbles before the transport runs (it waits for Messages in a helper
    /// process, but its in-process fallback would hold the main thread).
    private func submit(_ batch: Outbound) async {
        // The whole batch goes through the transport it was accepted with.
        let transport = self.transport
        submissionsInFlight += batch.items.count
        SendActivity.shared.begin(batch.items.count)
        try? await Task.sleep(for: .milliseconds(16))
        var anySubmitted = false
        for entry in batch.items {
            do {
                try await serialized {
                    switch entry.item {
                    case .text(let text): try await transport.send(text: text, to: batch.target)
                    case .file(let url): try await transport.send(file: url, to: batch.target)
                    }
                }
                setSendState(.submitted, of: entry.message.presentationID, in: batch.threadID)
                anySubmitted = true
            } catch {
                // The window stays live while Messages is asked, so a refresh may already have
                // found the message's row: Messages recorded it, whatever the hand-off said last.
                // It is not marked refused (that would offer to send it again).
                if isConfirmed(entry.message.presentationID, in: batch.threadID) {
                    anySubmitted = true
                } else {
                    setSendState(.failed(error.localizedDescription), of: entry.message.presentationID, in: batch.threadID)
                    sendErrors[batch.threadID] = error.localizedDescription
                }
            }
            submissionsInFlight -= 1
            SendActivity.shared.end(1)
        }
        guard anySubmitted else { return }
        if isLive { lastLoad = nil; await refresh() }
        else if let index = conversations.firstIndex(where: { $0.id == batch.threadID }) {
            // Demo sending stays local. No invented replies or real recipients.
            conversations[index].unreadCount = 0
        }
    }
    /// Runs transport work after all transport work accepted before it.
    private func serialized(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let previous = submissionChain
        let task = Task { @MainActor in
            await previous.value
            try await work()
        }
        submissionChain = Task { _ = try? await task.value }
        try await task.value
    }
    /// Whether the database already reported this message: its row carries the bubble's identity.
    private func isConfirmed(_ presentationID: String, in threadID: String) -> Bool {
        conversations.first { $0.id == threadID }?.messages.contains { $0.presentationID == presentationID && $0.sendState == nil } ?? false
    }
    /// Updates a local message's state wherever it is shown — never a row the database reported,
    /// which already took the bubble's place. A refused message leaves the pending list: it must
    /// not claim a later row.
    private func setSendState(_ state: SendState, of presentationID: String, in threadID: String) {
        instantly {
            if let index = conversations.firstIndex(where: { $0.id == threadID }),
               let position = conversations[index].messages.firstIndex(where: { $0.presentationID == presentationID && $0.sendState != nil }) {
                conversations[index].messages[position].sendState = state
            } else if var draft = composeDrafts[threadID], let position = draft.sent.firstIndex(where: { $0.presentationID == presentationID && $0.sendState != nil }) {
                draft.sent[position].sendState = state
                composeDrafts[threadID] = draft
            }
        }
        if state.isFailed { pending[threadID]?.removeAll { $0.presentationID == presentationID } }
        else if case .submitted = state, let position = pending[threadID]?.firstIndex(where: { $0.presentationID == presentationID }) {
            pending[threadID]?[position].sendState = .submitted
        }
    }
    /// The local message with this identity, wherever it is shown.
    private func localMessage(_ presentationID: String, in threadID: String) -> Message? {
        conversations.first { $0.id == threadID }?.messages.first { $0.presentationID == presentationID }
            ?? composeDrafts[threadID]?.sent.first { $0.presentationID == presentationID }
    }
    /// Sends a refused message again, as it was.
    func retrySend(_ presentationID: String, in threadID: String) async {
        guard let message = localMessage(presentationID, in: threadID), message.sendState?.isFailed == true, canSend else { return }
        let target: SendTarget
        if conversations.contains(where: { $0.id == threadID }) { target = .chat(threadID) }
        else if let draft = composeDrafts[threadID], draft.recipients.count == 1, let recipient = draft.recipients.first {
            target = .participant(handle: Recipient.handle(for: recipient.address), service: "iMessage")
        } else { return }
        let item: Outbound.Item
        if let path = message.attachments.first?.path { item = .file(URL(fileURLWithPath: path)) } else { item = .text(message.text) }
        setSendState(.sending, of: presentationID, in: threadID)
        var fresh = message
        fresh.sendState = .sending
        pending[threadID, default: []].append(fresh)
        sendErrors[threadID] = nil
        await submit(Outbound(target: target, threadID: threadID, items: [(item, fresh)]))
    }
    /// Takes a refused message out of the thread; its text goes back into the composer and its
    /// file back into the composer's strip, so it can be changed and sent again.
    func reclaimFailedSend(_ presentationID: String, in threadID: String) {
        guard let message = localMessage(presentationID, in: threadID), message.sendState?.isFailed == true else { return }
        discardFailedSend(presentationID, in: threadID)
        instantly {
            if let path = message.attachments.first?.path { outgoing[threadID, default: []].append(OutgoingAttachment(url: URL(fileURLWithPath: path))) }
            else if !message.text.isEmpty { drafts[threadID] = [drafts[threadID] ?? "", message.text].filter { !$0.isEmpty }.joined(separator: "\n") }
        }
    }
    /// Removes a refused message from the thread.
    func discardFailedSend(_ presentationID: String, in threadID: String) {
        instantly {
            if let index = conversations.firstIndex(where: { $0.id == threadID }) {
                conversations[index].messages.removeAll { $0.presentationID == presentationID && $0.sendState?.isFailed == true }
            } else if var draft = composeDrafts[threadID] {
                draft.sent.removeAll { $0.presentationID == presentationID && $0.sendState?.isFailed == true }
                composeDrafts[threadID] = draft
            }
            if sendErrors[threadID] != nil, localFailures(in: threadID) == 0 { sendErrors[threadID] = nil }
        }
    }
    private func localFailures(in threadID: String) -> Int {
        (conversations.first { $0.id == threadID }?.messages ?? composeDrafts[threadID]?.sent ?? []).filter { $0.sendState?.isFailed == true }.count
    }
    /// The sidebar preview after a send: the text, else what the last file was.
    static func preview(text: String, files: [OutgoingAttachment]) -> String {
        if !text.isEmpty { return text }
        return files.last?.previewText ?? "Attachment"
    }

    // MARK: Attachments

    /// Adds files that exist now (chosen in a panel, dropped, pasted from Finder) to a tile's composer.
    func attach(_ urls: [URL], to id: String) {
        guard !urls.isEmpty, openIDs.contains(id) else { return }
        instantly { outgoing[id, default: []] += urls.map { OutgoingAttachment(url: $0) } }
    }
    /// Adds a pasted or dropped picture to a tile's composer. The file is written off the main
    /// thread, behind a placeholder.
    func attachPicture(_ data: Data, type: UTType, to id: String) {
        guard let slot = beginImports(1, to: id).first else { return }
        let pending = services.outgoing.pending
        Task.detached(priority: .userInitiated) {
            let url = try? OutgoingFiles.store(data, type: type, in: pending)
            await MainActor.run { self.completeImport(slot, url: url, in: id, failure: "The pasted picture couldn't be kept.") }
        }
    }
    /// Reserves places in a tile's composer for this many files on their way in, in the order
    /// chosen; each then arrives through `completeImport`. Returns the places' identities.
    func beginImports(_ count: Int, to id: String) -> [String] {
        guard count > 0, openIDs.contains(id) else { return [] }
        let slots = (0..<count).map { _ in OutgoingAttachment.importing() }
        instantly { outgoing[id, default: []] += slots }
        return slots.map(\.id)
    }
    /// A file arrived for a reserved place (or failed to). A place that is gone — the tile was
    /// closed or replaced — takes nothing, and a file written for it is removed.
    func completeImport(_ slot: String, url: URL?, in id: String, failure: String = "This photo couldn't be added.") {
        guard let index = outgoing[id]?.firstIndex(where: { $0.id == slot }) else {
            if let url, services.outgoing.owns(url) { try? FileManager.default.removeItem(at: url) }
            return
        }
        instantly {
            if let url { outgoing[id]?[index].url = url; outgoing[id]?[index].state = .ready }
            else { outgoing[id]?[index].state = .failed(failure) }
        }
        if outgoing[id]?.contains(where: { $0.state == .importing }) != true { resumeImportWaiters(for: id) }
    }
    /// Suspends until none of the tile's files is still arriving (or the tile goes away).
    private func awaitImports(_ id: String) async {
        guard outgoing[id]?.contains(where: { $0.state == .importing }) == true else { return }
        await withCheckedContinuation { importWaiters[id, default: []].append($0) }
    }
    private func resumeImportWaiters(for id: String) {
        guard let waiting = importWaiters.removeValue(forKey: id) else { return }
        for continuation in waiting { continuation.resume() }
    }
    func removeAttachment(_ attachmentID: String, from id: String) {
        guard let file = outgoing[id]?.first(where: { $0.id == attachmentID }) else { return }
        instantly {
            outgoing[id]?.removeAll { $0.id == attachmentID }
            if outgoing[id]?.isEmpty == true { outgoing[id] = nil }
            if outgoing[id]?.contains(where: { $0.state.isFailed }) != true,
               let error = sendErrors[id], error.contains("couldn't be added") || error.contains("no longer on this Mac") { sendErrors[id] = nil }
        }
        // A picture Mosaic wrote for this message is not needed any more; a chosen file is the user's.
        if ownsFile(file), let url = file.url { try? FileManager.default.removeItem(at: url) }
        if outgoing[id]?.contains(where: { $0.state == .importing }) != true { resumeImportWaiters(for: id) }
    }

    // MARK: New messages

    /// Opens a tile for a new message. Recipients are chosen in the tile; the conversation is
    /// found or created when the first message is sent. With every tile taken, the tile used
    /// longest ago gives up its place.
    @discardableResult func beginNewChat() -> String? {
        let id = "new-\(UUID().uuidString)"
        instantly {
            composeDrafts[id] = ComposeDraft()
            var opened = false
            mutate { opened = $0.open(id) }
            if !opened, let victim = tileToReplace() {
                evict(victim)
                mutate { $0.replace(victim, with: id) }
            }
        }
        noteUse(id)
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
        guard !draft.recipients.isEmpty else { sendErrors[draftID] = "Add at least one recipient."; return }
        guard await readyToSend(draftID), let current = composeDrafts[draftID] else { return }
        // The conversation these people already have, else a new one Messages creates for one person.
        if let target = current.boundConversationID.flatMap({ id in conversations.first { $0.id == id } }) ?? conversation(with: current.recipients) {
            guard let batch = acceptSend(from: draftID, to: .chat(target.id), into: target.id) else { return }
            // The tile becomes the conversation now; the sending bubbles are already in it.
            instantly { replaceTile(draftID, with: target.id) }
            await submit(batch)
            return
        }
        guard current.recipients.count == 1, let recipient = current.recipients.first else {
            sendErrors[draftID] = "Messages can't start a new group from another app. Start it in Messages — it will appear here once it exists."
            openMessages(addresses: current.recipients.map(\.address))
            return
        }
        // The conversation appears in the database once Messages has created it; the tile adopts
        // it then (adoptConversations). Until then what was sent is shown in the draft tile.
        guard let batch = acceptSend(from: draftID, to: .participant(handle: Recipient.handle(for: recipient.address), service: "iMessage"), into: draftID) else { return }
        await submit(batch)
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
        let contacts = services.contacts
        var status = await contacts.authorizationStatus()
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
            let granted = await contacts.requestAccess()
            isLoadingContacts = false
            status = await contacts.authorizationStatus()
            contactAuthorization = status
            guard granted, status == .authorized else {
                contactStatus = "Mosaic wasn't given Contacts access. Turn it on in System Settings → Privacy & Security → Contacts."
                return
            }
        }
        isLoadingContacts = true
        defer { isLoadingContacts = false }
        do {
            let snapshot = try await contacts.entries()
            let entries = snapshot.entries, photoIDs = snapshot.photoIDs
            // A photo may have changed with the contacts: the ones on screen are fetched again.
            ContactPhotos.shared.reset()
            contactPhotoIDs = photoIDs
            contactPhotoGeneration += 1
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
        guard !loadingState, !forcedDemo else { return }
        if let data = try? JSONEncoder().encode(workspace) { defaults.set(data, forKey: stateKey) }
        if let data = try? JSONEncoder().encode(savedDrafts) { defaults.set(data, forKey: SavedDrafts.key(live: isLive)) }
    }
    private func restore(defaultIDs: [String] = []) {
        var state: Workspace
        if !forcedDemo, let data = defaults.data(forKey: stateKey), let saved = try? JSONDecoder().decode(Workspace.self, from: data) { state = saved }
        else { state = Workspace(openIDs: defaultIDs) }
        let saved = forcedDemo ? nil : SavedDrafts.load(from: defaults, live: isLive)
        // New Message tiles that were open come back with their recipients.
        let newMessageIDs = Set((saved?.newMessages.keys).map(Array.init) ?? []).intersection(state.openIDs)
        if !isLive { state.reconcile(availableIDs: Set(conversations.map(\.id)).union(newMessageIDs)) }
        // Text kept for a New Message tile that is not coming back has nowhere to go.
        for id in state.drafts.keys where id.hasPrefix("new-") && !newMessageIDs.contains(id) { state.drafts[id] = nil }
        workspace = state
        if let saved { restoreDrafts(saved, newMessages: newMessageIDs) }
    }
    /// What `SavedDrafts` keeps of the composers now: files that are ready (or missing, so the
    /// reader still sees them), and each unsent New Message's recipients. A New Message that has
    /// already handed messages over is in transition to its conversation and is not kept.
    private var savedDrafts: SavedDrafts {
        var saved = SavedDrafts()
        for (id, files) in outgoing {
            let paths = files.filter { $0.state == .ready || $0.isMissing }.compactMap { $0.url?.path }
            if !paths.isEmpty { saved.files[id] = paths }
        }
        for (id, draft) in composeDrafts where draft.sent.isEmpty {
            saved.newMessages[id] = SavedDrafts.NewMessage(recipients: draft.recipients.map { SavedDrafts.SavedRecipient(address: $0.address, name: $0.name) },
                                                          conversationID: draft.boundConversationID)
        }
        return saved
    }
    /// Puts saved composers back. A file that is gone is shown as missing (and blocks the send
    /// until removed); nothing is sent.
    private func restoreDrafts(_ saved: SavedDrafts, newMessages ids: Set<String>) {
        for id in ids {
            guard let draft = saved.newMessages[id] else { continue }
            composeDrafts[id] = ComposeDraft(recipients: draft.recipients.map { Recipient(address: $0.address, name: $0.name) },
                                             boundConversationID: draft.conversationID)
        }
        for (id, paths) in saved.files where !id.hasPrefix("new-") || ids.contains(id) {
            let files = paths.map { path -> OutgoingAttachment in
                let url = URL(fileURLWithPath: path)
                return FileManager.default.fileExists(atPath: path) ? OutgoingAttachment(url: url) : .missing(url)
            }
            if !files.isEmpty { outgoing[id] = files }
        }
    }
}

/// Messages accepted by Return and not yet handed to Messages, across the app. Sending no longer
/// holds the window, so a quit can come while some wait their turn; quitting asks first, and can
/// wait for them (`AppDelegate.applicationShouldTerminate`).
@MainActor final class SendActivity {
    static let shared = SendActivity()
    private(set) var waiting = 0
    private var whenDone: [() -> Void] = []
    func begin(_ count: Int) { waiting += count }
    func end(_ count: Int) {
        waiting = max(0, waiting - count)
        guard waiting == 0 else { return }
        let actions = whenDone
        whenDone = []
        for action in actions { action() }
    }
    /// Runs `action` once nothing is waiting (at once if nothing is).
    func whenAllSent(_ action: @escaping () -> Void) {
        if waiting == 0 { action() } else { whenDone.append(action) }
    }
}

struct WorkspaceAlert: Identifiable, Equatable {
    let title: String
    let message: String
    var id: String { title + message }
}

/// Unsent work kept across launches, beside the workspace (which holds the text drafts): the
/// files waiting in each composer, as paths — Mosaic's own copies, or the user's chosen originals
/// where they are — and the recipients of each New Message tile. Nothing about sends: a message
/// that was handed to Messages is never restored, and nothing is sent at launch. Stored as JSON
/// in Mosaic's preferences, like the workspace; no history or previews are kept here.
struct SavedDrafts: Codable, Equatable {
    static let currentVersion = 1
    var version = SavedDrafts.currentVersion
    var files: [String: [String]] = [:]
    var newMessages: [String: NewMessage] = [:]
    struct NewMessage: Codable, Equatable {
        var recipients: [SavedRecipient]
        var conversationID: String?
    }
    struct SavedRecipient: Codable, Equatable { var address: String; var name: String }

    static func key(live: Bool) -> String { "Mosaic.drafts.\(live ? "live" : "demo")" }
    /// The saved record, or nil when there is none or it was written by a newer Mosaic.
    static func load(from defaults: UserDefaults, live: Bool) -> SavedDrafts? {
        guard let data = defaults.data(forKey: key(live: live)),
              let saved = try? JSONDecoder().decode(SavedDrafts.self, from: data), saved.version <= currentVersion else { return nil }
        return saved
    }
    /// Every file a saved draft (live or demo) still points at; cleanup leaves these alone.
    static func referencedPaths(in defaults: UserDefaults) -> Set<String> {
        Set([true, false].compactMap { load(from: defaults, live: $0) }.flatMap { $0.files.values.joined() })
    }
}

/// What views know of a held tile: which one, its size while held, and the order a release gives.
struct HeldTile: Equatable {
    let id: String
    let size: CGSize
    let order: [String]
}

/// The held tile's place, apart from the store's other state so the pointer's movement re-renders
/// only the view that positions the tile.
@Observable @MainActor final class TileDragMotion {
    var origin: CGPoint = .zero
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
/// How often Mosaic looks at Messages' database when the file watcher has said nothing, and how
/// it settles a burst of writes. The watcher is the normal path; the poll covers a missed event,
/// a replaced file or a watcher that could not start.
enum RefreshPolicy {
    /// Mosaic is in front: a quick fallback.
    static let active: Duration = .seconds(3)
    /// A send was handed to Messages and its row has not appeared yet: look more often, active or not.
    static let awaitingConfirmation: Duration = .seconds(1)
    /// Mosaic is in the background: rare checks (the watcher still refreshes at once).
    static let inactive: Duration = .seconds(15)
    /// Quiet time after the last write before refreshing.
    static let settle: Duration = .milliseconds(120)
    /// The longest a burst can postpone its refresh.
    static let maxWait: Duration = .milliseconds(500)

    static func pollInterval(appActive: Bool, awaitingConfirmation: Bool) -> Duration {
        if awaitingConfirmation { return Self.awaitingConfirmation }
        return appActive ? active : inactive
    }
    /// When to refresh after a write at `now` in a burst that began at `burstStarted`.
    static func refreshDeadline(now: ContinuousClock.Instant, burstStarted: ContinuousClock.Instant) -> ContinuousClock.Instant {
        min(now + settle, burstStarted + maxWait)
    }
}

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
