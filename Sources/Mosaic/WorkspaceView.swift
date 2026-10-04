import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

enum Palette {
    static let accent = Color(nsColor: .systemBlue)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let avatar = Color(nsColor: .systemGray)
    static let incoming = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)
            : NSColor(red: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1)
    })
    /// #218AFF — outgoing iMessage bubbles.
    static let bubbleBlue = Color(red: 0x21 / 255, green: 0x8A / 255, blue: 0xFF / 255)
    static func outgoing(service: String) -> Color {
        service.caseInsensitiveCompare("iMessage") == .orderedSame ? bubbleBlue : Color(nsColor: .systemGreen)
    }
}

extension Notification.Name {
    /// Puts the keyboard in the sidebar's search field (⌘F).
    static let focusSearch = Notification.Name("Mosaic.focusSearch")
    /// Gives the conversation list the keyboard (⌘L); see `SidebarKeyboard`.
    static let focusConversationList = Notification.Name("Mosaic.focusConversationList")
}

struct WorkspaceView: View {
    /// Height of the window-control strip (traffic lights). Tiles reach up into it; the window itself
    /// is moved only by `WindowDragRegion` (the empty parts of the strip), never by AppKit's automatic
    /// title-bar dragging, which is off (`WindowChrome`).
    static let titleBarHeight: CGFloat = 52
    /// Space between the window edge and the tile area, the same on every side.
    static let tileAreaMargin: CGFloat = 8
    @Environment(WorkspaceStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var keyboard = KeyboardRouter()
    @State private var sidebarKeyboard = SidebarKeyboard()

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            sidebar.frame(width: 256)
                // The strip above the sidebar (where the window controls are) moves the window; the
                // compose button sits at its trailing end, as in Messages.
                .overlay(alignment: .top) {
                    ZStack(alignment: .trailing) {
                        TitleBarDragArea()
                        StripButton(symbol: "square.and.pencil", label: "New Message") { store.beginNewChat() }
                            .frame(width: 30, height: 28).padding(.trailing, 12)
                    }.frame(height: Self.titleBarHeight)
                }
            Divider()
            // Nothing but tiles on the right: no message strips in the title area. What the
            // workspace has to say is said in the empty workspace or in an alert.
            ZStack {
                // Tiles reach up into the title-bar strip; their headers handle their own mouse
                // events there. The empty parts of the strip (margins, gaps) move the window.
                TileWorkspace().padding(Self.tileAreaMargin)
                if store.tiles.isEmpty { emptyWorkspace }
            }
            // Behind everything in the right pane, only as tall as the strip: a press there that no
            // tile header, chip or divider takes moves the window.
            .background(alignment: .top) { TitleBarDragArea().frame(height: Self.titleBarHeight) }
            .background(Palette.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: "workspace")
        .tint(Palette.accent)
        // Every tile reads the same conversation scale (⌘+ / ⌘− / ⌘0).
        .environment(\.zoomScale, CGFloat(store.zoom))
        // Workspace changes — tiles opening, closing, moving, resizing, layouts switching — land
        // on the next frame: every store mutation runs in a transaction without animation
        // (`instantly`), and nothing in the chrome declares one. The only motion is the scoped
        // settling of a newly arrived message inside a thread (NewMessageEffect).
        .background(WindowReader { window in
            WindowChrome.apply(to: window)
            keyboard.attach(window: window, store: store, sidebar: sidebarKeyboard)
        })
        .sheet(isPresented: $store.showSetup) { SetupView().environment(store) }
        .alert(item: $store.alert) { alert in Alert(title: Text(alert.title), message: Text(alert.message)) }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusConversationList)) { _ in sidebarKeyboard.focusList() }
        .onChange(of: searchFocused) { _, focused in keyboard.searchFieldHasFocus = focused }
    }

    private var sidebar: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a conversation", text: $store.search).textFieldStyle(.plain).focused($searchFocused)
                    // Return opens the first match; ↓ moves into the list (KeyboardRouter).
                    .onSubmit { store.activateSidebarSelection() }
                    .accessibilityLabel("Find a conversation")
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 10).padding(.top, Self.titleBarHeight + 4)
            // A List, for its swipe actions: swiping a row left reveals Delete, as in Messages.
            ScrollViewReader { scroller in
                List {
                    ForEach(store.filteredConversations) { conversation in
                        // Rows run to the sidebar's trailing edge, so the swipe action sits flush
                        // against the row instead of beside a gap.
                        ConversationRow(conversation: conversation)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 3, trailing: 0))
                            .listRowSeparator(.hidden)
                            // Inside the list's scroll view: gives it the slim scroller the tiles have,
                            // one that does not thicken under the pointer or appear for a swipe, and
                            // tells the rows while a swipe is under way.
                            .listRowBackground(ThinScrollerInstaller(hidesForHorizontalSwipes: true,
                                onSwipeModeChange: { swiping in store.setSidebarSwiping(swiping) }))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { store.hide(conversation.id) } label: { Image(systemName: "trash") }
                                    .tint(.red)
                            }
                    }
                    if store.filteredConversations.isEmpty {
                        Text(store.search.isEmpty ? "Conversations will appear here." : "No conversations found.")
                            .font(.callout).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .padding(.top, 12)
                // The keyboard's row stays in view as the arrow keys move it.
                .onChange(of: store.sidebarSelection) { _, id in if let id { scroller.scrollTo(id) } }
            }
        }
        .background(.regularMaterial)
        // Holds the keyboard for the list (⌘L); draws nothing and takes no clicks.
        .background(alignment: .topLeading) { SidebarKeyFocus(keyboard: sidebarKeyboard, store: store).frame(width: 1, height: 1) }
    }
    private var emptyWorkspace: some View {
        let unconnected = store.isLive && store.conversations.isEmpty
        return VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(Palette.accent.opacity(0.6))
            Text(unconnected ? "Bring your conversations together" : "Make room for a conversation")
                .font(.system(size: 24, weight: .medium))
            Text(unconnected ? "Connect Messages to see the chats already on your Mac." : "Choose someone in the sidebar to open a tile.\nEvery conversation gets its own space and draft.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if unconnected {
                // Why nothing has loaded yet, in the workspace rather than a strip at the top.
                if let error = store.connectionError {
                    Label(error, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 480).padding(.top, 4)
                }
                HStack(spacing: 10) {
                    Button("Connect Messages") { store.showSetup = true }.buttonStyle(.borderedProminent)
                    if store.connectionError != nil { Button("Retry") { Task { await store.refresh() } } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The window's title bar, configured in AppKit. An empty toolbar with the unified style is what
/// gives the bar Messages' height and brings the window controls in from the corner; doing this with
/// a SwiftUI toolbar item put a nested hosting view in the title bar, and that view's constraint
/// updates could loop until AppKit raised an exception (the "fails to load history" crash).
///
/// AppKit's automatic dragging is turned off (`isMovable = false`): in the title-bar region macOS
/// otherwise moves the window on any press, whatever the view under the pointer says, which is what
/// made a tile-header drag move the whole window. `WindowDragRegion` moves the window instead, from
/// the parts of the strip that hold no tile.
enum WindowChrome {
    static let toolbarIdentifier = NSToolbar.Identifier("MosaicTitleBarSpacer")

    @MainActor static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovable = false
        window.isMovableByWindowBackground = false
        if window.toolbar?.identifier != toolbarIdentifier {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
        window.toolbar?.isVisible = true
    }
}

/// The part of the title-bar strip that moves the window, standing in for the automatic dragging
/// that `WindowChrome` turns off. It is an AppKit view (`WindowDragRegion`) so that it takes only
/// presses no tile header handle or focus chip above it claims.
struct TitleBarDragArea: View {
    var body: some View { WindowDragRegion() }
}

/// A transparent AppKit view that moves the window when dragged and zooms it on a double-click.
/// With `limitedToTitleBar`, only presses within the window's top `titleBarHeight` points are taken;
/// elsewhere the view is invisible to hit testing, so content below the strip is untouched.
/// AppKit's own `performDrag(with:)` is tried first (it snaps to screen edges); if the system
/// declines it because the window is not user-movable, the frame is moved directly, which Apple
/// documents as the way to drag a non-movable window.
struct WindowDragRegion: NSViewRepresentable {
    var limitedToTitleBar = false

    func makeNSView(context: Context) -> DragView { let view = DragView(); view.limitedToTitleBar = limitedToTitleBar; return view }
    func updateNSView(_ view: DragView, context: Context) { view.limitedToTitleBar = limitedToTitleBar }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DragView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class DragView: NSView {
        var limitedToTitleBar = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Whether a point (in this view's coordinates) is within the window's title-bar strip.
        func isInTitleBarStrip(_ local: NSPoint) -> Bool {
            guard let content = window?.contentView else { return false }
            let inContent = convert(local, to: content)
            let fromTop = content.isFlipped ? inContent.y : content.bounds.height - inContent.y
            return fromTop <= WorkspaceView.titleBarHeight
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = superview.map { convert(point, from: $0) } ?? point
            guard bounds.contains(local) else { return nil }
            if limitedToTitleBar && !isInTitleBarStrip(local) { return nil }
            return self
        }
        private var monitor: Any?
        private var dragStart: (mouse: NSPoint, origin: NSPoint)?

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            endTracking()
            if event.clickCount == 2 { Self.performTitleBarDoubleClick(on: window); return }
            let before = window.frame.origin
            window.performDrag(with: event)
            // performDrag runs until the mouse is released when AppKit honors it. If it returned at
            // once with the button still down, it was declined: follow the press ourselves.
            guard NSEvent.pressedMouseButtons & 1 != 0, window.frame.origin == before else { return }
            beginManualDrag(from: NSEvent.mouseLocation)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                if event.type == .leftMouseUp { self.endTracking(); return event }
                self.moveWindow(to: NSEvent.mouseLocation)
                return event
            }
        }
        override func mouseDragged(with event: NSEvent) { if dragStart != nil { moveWindow(to: NSEvent.mouseLocation) } }
        override func mouseUp(with event: NSEvent) { endTracking() }
        /// Starts following the pointer (screen coordinates) with the window's current origin.
        func beginManualDrag(from mouse: NSPoint) {
            guard let window else { return }
            dragStart = (mouse, window.frame.origin)
        }
        /// Moves the window by the pointer's travel since the press (screen coordinates).
        func moveWindow(to mouse: NSPoint) {
            guard let window, let start = dragStart else { return }
            window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        }
        private func endTracking() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            dragStart = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        /// The action System Settings assigns to a double-click on a title bar.
        static func performTitleBarDoubleClick(on window: NSWindow, action: String? = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
            switch action {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}

struct ConversationRow: View {
    @Environment(WorkspaceStore.self) private var store
    let conversation: Conversation
    /// Whether the tile was already open when a click sequence began; a double-click then closes it.
    @State private var wasOpenAtFirstClick = false
    private var isOpen: Bool { store.openIDs.contains(conversation.id) }
    /// The keyboard is on this row (the list has keyboard focus: ⌘L or ↓ from the search field).
    private var isSelected: Bool { store.sidebarSelection == conversation.id }
    /// The one highlighted row: the keyboard's, except during a swipe. The pointer highlights nothing.
    private var isHighlighted: Bool { store.highlightedSidebarRow == conversation.id }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 10) {
                Avatar(conversation: conversation, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(conversation.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if isOpen { Image(systemName: "square.grid.2x2.fill").font(.system(size: 9)).foregroundStyle(Palette.accent) }
                        else if conversation.unreadCount > 0 { Circle().fill(Palette.accent).frame(width: 6, height: 6) }
                    }
                    Text(conversation.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 12)
                // An open conversation is marked by the grid icon alone. The keyboard's row gets a
                // light wash, rounded like a Messages row and reaching a little past the row's
                // content on the trailing side.
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHighlighted ? Color.primary.opacity(0.06) : Color.clear)
                        .padding(.trailing, -4)
                }
                .contentShape(Rectangle())
        }.buttonStyle(TileControlStyle()).accessibilityLabel(isOpen ? "\(conversation.name), open in a tile" : "Open \(conversation.name)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            // No highlight under the pointer; hovering only fetches the history ahead, so the
            // tile opens on its messages.
            .onHover { inside in if inside { store.prefetch(conversation.id) } }
            .help(isOpen ? "Double-click to close this tile" : "Open in a tile")
            .contextMenu {
                Button(isOpen ? "Close tile" : "Open in workspace") { if isOpen { store.close(conversation.id) } else { store.open(conversation.id) } }
                if store.isLive { Button("Open Messages") { store.openMessages(conversation) } }
                Divider()
                Button("Delete", role: .destructive) { store.hide(conversation.id) }
            }
            .onDrag { NSItemProvider(object: conversation.id as NSString) }
    }

    private func activate() {
        var clicks = 1
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type) { clicks = event.clickCount }
        guard clicks < 2 else {
            // The first click of the pair only focused the tile; the second closes it.
            if clicks == 2, wasOpenAtFirstClick, isOpen { store.close(conversation.id) }
            return
        }
        wasOpenAtFirstClick = isOpen
        // While the list has the keyboard, a click also moves the keyboard's row here.
        if store.sidebarSelection != nil { store.selectSidebarRow(conversation.id) }
        store.open(conversation.id)
    }
}

struct Avatar: View {
    let conversation: Conversation
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Palette.avatar.gradient)
            if conversation.isGroup { Image(systemName: "person.2.fill").font(.system(size: size * 0.33)).foregroundStyle(.white) }
            else { Text(conversation.initials).font(.system(size: size * 0.30, weight: .semibold, design: .rounded)).foregroundStyle(.white) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Places every tile and divider at its planned frame. Positioning through layout (rather than offsets)
/// keeps each tile's real frame where it is drawn, so clicks, text carets and cursors always line up.
struct TileCanvas: Layout {
    static let space = "tileCanvas"
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let frame = subview[TileFrameKey.self]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct TileFrameKey: LayoutValueKey { static let defaultValue = CGRect.zero }
extension View {
    func tileFrame(_ frame: CGRect) -> some View { layoutValue(key: TileFrameKey.self, value: frame) }
}

struct TileWorkspace: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var gridFractions: [Int: CGFloat] = [:]
    @State private var rowWeights: [CGFloat] = []
    @State private var columnWeights: [CGFloat] = []
    @State private var resizeStart: (divider: TileDivider.Kind, plan: TilePlan)?

    var body: some View {
        GeometryReader { geometry in
            let layout = store.layout
            let order = layout == .focus ? store.focused.map { [$0.id] } ?? [] : store.displayOrder
            let viewport = CGSize(width: geometry.size.width, height: geometry.size.height - (layout == .focus ? FocusChipBar.height + 8 : 0))
            let plan = TileLayout.plan(order: order, viewport: viewport, layout: layout,
                gridFractions: gridFractions, rowWeights: rowWeights, columnWeights: columnWeights)
            // How any order would lay out right now, so a reorder knows where each tile came from.
            let _ = (store.tilePlanner = { [gridFractions, rowWeights, columnWeights] order in
                TileLayout.plan(order: order, viewport: viewport, layout: layout,
                                gridFractions: gridFractions, rowWeights: rowWeights, columnWeights: columnWeights)
            })
            VStack(spacing: 8) {
                if layout == .focus {
                    FocusChipBar(chips: FocusChip.chips(for: store.tiles, focusedID: store.focused?.id)) { id in store.focus(id) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: FocusChipBar.height)
                }
                // The same view structure in every layout, so switching layouts resizes the tiles
                // instead of rebuilding them (which reset every conversation's scroll position and
                // composer). Only Columns can outgrow the window, sideways; the scroll view is
                // inert in Grid and Focus, whose plans always fit it.
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: layout == .columns) { canvas(plan) }
                        .scrollDisabled(layout != .columns)
                        // Grid and Focus never scroll, so a dragged tile may draw over the margins.
                        .scrollClipDisabled(layout != .columns)
                        .onChange(of: store.focusToken) { _, _ in
                            guard layout == .columns, let id = store.focusTarget else { return }
                            scroller.scrollTo(id)
                        }
                }
            }
        }
        .onChange(of: store.openIDs.count) { _, _ in
            gridFractions = [:]; rowWeights = []; columnWeights = []
            resizeStart = nil
        }
    }

    private func canvas(_ plan: TilePlan) -> some View {
        TileCanvas {
            ForEach(store.tiles) { chat in
                if let slot = plan.frames[chat.id] { tile(chat, slot: slot, plan: plan) }
            }
            ForEach(plan.dividers) { divider in
                DividerHandle(divider: divider, enabled: store.heldTile == nil,
                    onChanged: { translation in resize(divider, translation: translation, plan: plan) },
                    onEnded: { resizeStart = nil })
                    .zIndex(2)
                    .tileFrame(divider.frame)
            }
        }
        .frame(width: plan.size.width, height: plan.size.height, alignment: .topLeading)
        .coordinateSpace(name: TileCanvas.space)
    }

    @ViewBuilder private func tile(_ chat: Conversation, slot: CGRect, plan: TilePlan) -> some View {
        let held = store.heldTile?.id == chat.id ? store.heldTile : nil
        // A held tile keeps its size; its place in the layout is the slot a release would give
        // it, and it is drawn where the pointer has it (`TileMotion`).
        let frame = held.map { CGRect(origin: slot.origin, size: $0.size) } ?? slot
        let movable = store.layout != .focus && store.tiles.count > 1
        let raised = held != nil || store.liftedTile == chat.id || store.settlingTile == chat.id
        TileMotion(motion: store.dragMotion, slot: frame.origin, isHeld: held != nil,
                   spring: store.tileSprings[chat.id] ?? .zero, isLifted: store.liftedTile == chat.id) {
            ConversationTile(conversation: chat,
                onDragChanged: movable ? { (translation: CGSize) in store.dragTile(chat.id, translation: translation, plan: plan) } : nil,
                onDragEnded: { store.finishTileDrag(chat.id) })
                .frame(width: frame.width, height: frame.height)
        }
        .id(chat.id)
        .zIndex(raised ? 100 : 1)
        .tileFrame(frame)
    }

    private func resize(_ divider: TileDivider, translation: CGSize, plan: TilePlan) {
        // A cancelled gesture may never report its end; a different handle always starts fresh.
        if resizeStart?.divider != divider.kind { resizeStart = (divider.kind, plan) }
        guard let start = resizeStart?.plan else { return }
        switch divider.kind {
        case .gridColumn(let row):
            guard start.order.indices.contains(row * 2), let first = start.frames[start.order[row * 2]] else { return }
            let available = start.size.width - TileLayout.inset * 2 - TileLayout.gap
            gridFractions[row] = min(max(first.width + translation.width, TileLayout.minimumWidth), available - TileLayout.minimumWidth) / available
        case .row(let index):
            rowWeights = TileLayout.resizedPair(start.rowSizes, at: index, delta: translation.height, minimum: TileLayout.minimumHeight)
        case .column(let index):
            columnWeights = TileLayout.resizedPair(start.columnSizes, at: index, delta: translation.width, minimum: 300)
        }
    }
}

/// Where a tile is drawn, apart from its place in the layout: following the pointer while held,
/// springing from its old place after a reorder or a release, slightly raised while lifted. All
/// of it is a transform of the finished tile — nothing inside is laid out again — and only this
/// view reads the pointer's position, so moving a tile redraws nothing else.
struct TileMotion<Content: View>: View {
    let motion: TileDragMotion
    let slot: CGPoint
    let isHeld: Bool
    let spring: CGSize
    let isLifted: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var liftScale: CGFloat { 1.015 }

    var body: some View {
        let offset = isHeld ? CGSize(width: motion.origin.x - slot.x, height: motion.origin.y - slot.y) : spring
        let scale = isLifted && !reduceMotion ? Self.liftScale : 1
        content
            // The lift's shadow is drawn from the tile's shape, not from everything in the tile.
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.surface)
                    .shadow(color: .black.opacity(isLifted ? 0.22 : 0), radius: 24, y: 12)
            }
            .tileTransform(offset: offset, scale: scale)
    }
}

extension View {
    /// Moves and scales a finished view as it is drawn — a visual effect, so nothing inside is
    /// laid out or measured again however often it changes. AppKit views inside (the thread's
    /// scroll view, the composer) move with it.
    func tileTransform(offset: CGSize, scale: CGFloat) -> some View {
        visualEffect { content, _ in content.scaleEffect(scale).offset(offset) }
    }
}

/// An invisible gap between tiles that resizes its neighbors.
struct DividerHandle: View {
    let divider: TileDivider
    let enabled: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void
    @GestureState private var active = false

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .hoverCursor(divider.movesHorizontally ? .resizeLeftRight : .resizeUpDown, enabled: enabled)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(TileCanvas.space))
                .updating($active) { _, state, _ in state = true }
                .onChanged { value in onChanged(value.translation) }
                .onEnded { _ in onEnded() })
            .onChange(of: active) { _, isActive in if !isActive { onEnded() } }
            .allowsHitTesting(enabled)
            .accessibilityHidden(true)
    }
}

/// Routes the workspace's keys while its window is key, ahead of the views and the menu bar:
/// Tab and Shift–Tab traverse the tiles; ⌘F finds a conversation and ⌘L goes to the list (taken
/// here so the Edit menu's text Find never claims ⌘F); from the search field, ↓ and ↑ move into
/// the list and Esc clears the search, then gives up the keyboard.
@MainActor final class KeyboardRouter {
    private weak var window: NSWindow?
    private weak var store: WorkspaceStore?
    private var sidebar: SidebarKeyboard?
    private var monitor: Any?
    /// Whether the sidebar's search field has the keyboard (from the view's focus state).
    var searchFieldHasFocus = false

    func attach(window: NSWindow?, store: WorkspaceStore, sidebar: SidebarKeyboard? = nil) {
        if let window { self.window = window }
        self.store = store
        if let sidebar { self.sidebar = sidebar }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let store, let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let key = event.charactersIgnoringModifiers?.lowercased() {
            if modifiers == .command {
                if key == "f" { NotificationCenter.default.post(name: .focusSearch, object: nil); return true }
                if key == "l" { NotificationCenter.default.post(name: .focusConversationList, object: nil); return true }
            }
            // ⌘+ (which is ⌘⇧= on most layouts), ⌘=, ⌘−, ⌘0: the shared zoom, from anywhere in
            // the window — a composer, the search field, the list — without inserting characters.
            // One action path: consuming the event here means the menu equivalents never also fire.
            if modifiers.subtracting(.shift) == .command, let action = Self.zoomAction(for: key) {
                switch action {
                case .zoomIn: store.zoomIn()
                case .zoomOut: store.zoomOut()
                case .reset: store.resetZoom()
                }
                return true
            }
            if modifiers == .command { return false }
        }
        let inSearchField = searchFieldHasFocus && window.firstResponder is NSTextView
        switch event.keyCode {
        case 48: // Tab
            guard modifiers.subtracting(.shift).isEmpty else { return false }
            let editor = window.firstResponder as? DraftTextView
            if let editor, editor.hasMarkedText() { return false }
            return store.moveFocus(forward: !modifiers.contains(.shift), from: editor?.conversationID)
        case 125, 126: // ↓ ↑ from the search field: into the list.
            guard modifiers.isEmpty, inSearchField, let sidebar else { return false }
            return sidebar.focusList(event.keyCode == 125 ? .first : .last)
        case 53: // Esc in the search field: clear it, then give up the keyboard.
            guard modifiers.isEmpty, inSearchField else { return false }
            if store.search.isEmpty { window.makeFirstResponder(nil) } else { instantly { store.search = "" } }
            return true
        default:
            return false
        }
    }
}

extension KeyboardRouter {
    enum ZoomAction { case zoomIn, zoomOut, reset }
    /// The zoom keys, by the character the press stands for: = and + zoom in (⌘= is the unshifted
    /// plus key), - and _ zoom out, 0 resets. Keypad + and - arrive as the same characters.
    nonisolated static func zoomAction(for key: String) -> ZoomAction? {
        switch key {
        case "=", "+": return .zoomIn
        case "-", "_": return .zoomOut
        case "0": return .reset
        default: return nil
        }
    }
}

/// Reports the hosting window without taking part in hit testing or layout.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ReaderView { let view = ReaderView(); view.onChange = onChange; return view }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReaderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [weak self] in self?.onChange?(window) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
