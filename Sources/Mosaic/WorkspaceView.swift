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

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            sidebar.frame(width: 256)
                // The strip above the sidebar (where the window controls are) moves the window.
                .overlay(alignment: .top) { TitleBarDragArea().frame(height: Self.titleBarHeight) }
            Divider()
            VStack(spacing: 0) {
                if let banner = store.banner {
                    HStack { Text(banner).font(.callout); Spacer(); Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(12).padding(.top, Self.titleBarHeight - 12).background(Palette.accent.opacity(0.08))
                }
                if let error = store.connectionError {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.lock").foregroundStyle(.orange)
                        Text(error).font(.callout).lineLimit(3)
                        Spacer()
                        Button("Set up") { store.showSetup = true }
                        Button("Retry") { Task { await store.refresh() } }
                    }.padding(14).padding(.top, Self.titleBarHeight - 14).background(Color.orange.opacity(0.08))
                }
                ZStack {
                    // Tiles reach up into the title-bar strip; their headers handle their own mouse
                    // events there. The empty parts of the strip (margins, gaps) move the window.
                    TileWorkspace().padding(Self.tileAreaMargin)
                    if store.tiles.isEmpty { emptyWorkspace }
                }
            }
            // Behind everything in the right pane, only as tall as the strip: a press there that no
            // tile header, chip or divider takes moves the window.
            .background(alignment: .top) { TitleBarDragArea().frame(height: Self.titleBarHeight) }
            .background(Palette.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: "workspace")
        .tint(Palette.accent)
        // No motion anywhere in the workspace: every change lands on the next frame.
        .transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true }
        .background(WindowReader { window in
            WindowChrome.apply(to: window)
            keyboard.attach(window: window, store: store)
        })
        .sheet(isPresented: $store.showSetup) { SetupView().environment(store) }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
    }

    private var sidebar: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a conversation", text: $store.search).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Find a conversation")
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 10).padding(.top, Self.titleBarHeight + 4)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.filteredConversations) { conversation in
                        ConversationRow(conversation: conversation)
                    }
                    if store.filteredConversations.isEmpty {
                        Text(store.search.isEmpty ? "Conversations will appear here." : "No conversations found.")
                            .font(.callout).foregroundStyle(.secondary).padding(20)
                    }
                }.padding(.horizontal, 10)
            }.padding(.top, 12)
        }.background(.regularMaterial)
    }
    private var emptyWorkspace: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(Palette.accent.opacity(0.6))
            Text(store.isLive && store.conversations.isEmpty ? "Bring your conversations together" : "Make room for a conversation")
                .font(.system(size: 24, weight: .medium))
            Text(store.isLive && store.conversations.isEmpty ? "Connect Messages to see the chats already on your Mac." : "Choose someone in the sidebar to open a tile.\nEvery conversation gets its own space and draft.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if store.isLive && store.conversations.isEmpty { Button("Connect Messages") { store.showSetup = true }.buttonStyle(.borderedProminent) }
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
            }.padding(.horizontal, 10).padding(.vertical, 12)
                .background(isOpen ? Palette.accent.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(TileControlStyle()).accessibilityLabel(isOpen ? "\(conversation.name), open in a tile" : "Open \(conversation.name)")
            .help(isOpen ? "Double-click to close this tile" : "Open in a tile")
            .contextMenu {
                Button(isOpen ? "Close tile" : "Open in workspace") { if isOpen { store.close(conversation.id) } else { store.open(conversation.id) } }
                if store.isLive { Button("Open Messages") { store.openMessages(conversation) } }
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
                DividerHandle(divider: divider, enabled: store.tileDrag == nil,
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
        let dragging = store.tileDrag?.id == chat.id
        let frame = dragging ? (store.tileDrag?.frame ?? slot) : slot
        let movable = store.layout != .focus && store.tiles.count > 1
        ConversationTile(conversation: chat,
            onDragChanged: movable ? { (translation: CGSize) in store.dragTile(chat.id, translation: translation, plan: plan) } : nil,
            onDragEnded: { store.finishTileDrag(chat.id) })
            .frame(width: frame.width, height: frame.height)
            .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: dragging ? 22 : 0, y: dragging ? 10 : 0)
            .id(chat.id)
            .zIndex(dragging ? 100 : 1)
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

/// Routes Tab and Shift–Tab to tile traversal while the workspace window is key.
@MainActor final class KeyboardRouter {
    private weak var window: NSWindow?
    private weak var store: WorkspaceStore?
    private var monitor: Any?

    func attach(window: NSWindow?, store: WorkspaceStore) {
        if let window { self.window = window }
        self.store = store
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48, let store, let window, event.window === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.subtracting(.shift).isEmpty else { return false }
        let editor = window.firstResponder as? DraftTextView
        if let editor, editor.hasMarkedText() { return false }
        return store.moveFocus(forward: !modifiers.contains(.shift), from: editor?.conversationID)
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
