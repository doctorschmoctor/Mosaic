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
    /// Height of the unified title bar the window controls sit in.
    static let titleBarHeight: CGFloat = 52
    @EnvironmentObject private var store: WorkspaceStore
    @FocusState private var searchFocused: Bool
    @StateObject private var keyboard = KeyboardRouter()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 256)
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
                    // Tile headers start below the title bar, where a press would drag the window instead.
                    TileWorkspace().padding(.horizontal, 8).padding(.bottom, 8)
                        .padding(.top, store.banner == nil && store.connectionError == nil ? Self.titleBarHeight - TileLayout.inset - 12 : 10)
                    if store.tiles.isEmpty { emptyWorkspace.transition(.opacity) }
                }
            }.background(Palette.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: "workspace")
        .tint(Palette.accent)
        // An invisible toolbar item is what makes the window use the taller unified title bar.
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) } }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(WindowReader { window in keyboard.attach(window: window, store: store) })
        .sheet(isPresented: $store.showSetup) { SetupView().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
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

struct ConversationRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    let conversation: Conversation
    @State private var origin = CGPoint.zero
    /// Whether the tile was already open when a click sequence began; a double-click then closes it.
    @State private var wasOpenAtFirstClick = false
    private var isOpen: Bool { store.workspace.openIDs.contains(conversation.id) }

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
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ConversationOriginKey.self,
                    value: CGPoint(x: geometry.frame(in: .named("workspace")).midX, y: geometry.frame(in: .named("workspace")).midY))
            })
            .onPreferenceChange(ConversationOriginKey.self) { origin = $0 }
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
        store.open(conversation.id, from: origin)
    }
}

private struct ConversationOriginKey: PreferenceKey {
    static var defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
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
/// keeps each tile's real frame where it is drawn, so clicks, text carets and cursors always line up,
/// even after many overlapping animations.
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
    @EnvironmentObject private var store: WorkspaceStore
    @State private var gridFractions: [Int: CGFloat] = [:]
    @State private var rowWeights: [CGFloat] = []
    @State private var columnWeights: [CGFloat] = []
    @State private var resizeStart: (divider: TileDivider.Kind, plan: TilePlan)?

    var body: some View {
        GeometryReader { geometry in
            let layout = store.workspace.layout
            let order = layout == .focus ? store.focused.map { [$0.id] } ?? [] : store.displayOrder
            let viewport = CGSize(width: geometry.size.width, height: geometry.size.height - (layout == .focus ? 44 : 0))
            let plan = TileLayout.plan(order: order, viewport: viewport, layout: layout,
                gridFractions: gridFractions, rowWeights: rowWeights, columnWeights: columnWeights)
            VStack(spacing: 8) {
                if layout == .focus { focusPicker.frame(height: 36).transition(.move(edge: .top).combined(with: .opacity)) }
                if layout == .columns {
                    // Only Columns can outgrow the window, sideways. Grid and Focus always fit it.
                    ScrollViewReader { scroller in
                        ScrollView(.horizontal) { canvas(plan) }
                            .onChange(of: store.focusToken) { _, _ in
                                guard let id = store.focusTarget else { return }
                                withAnimation(Motion.layout) { scroller.scrollTo(id) }
                            }
                    }
                } else {
                    canvas(plan)
                }
            }
        }
        .onChange(of: store.workspace.openIDs.count) { _, _ in
            store.animateLayout { gridFractions = [:]; rowWeights = []; columnWeights = [] }
            resizeStart = nil
        }
    }

    private func canvas(_ plan: TilePlan) -> some View {
        GeometryReader { canvas in
            TileCanvas {
                ForEach(store.tiles) { chat in
                    if let slot = plan.frames[chat.id] { tile(chat, slot: slot, plan: plan, canvas: canvas) }
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
        .frame(width: plan.size.width, height: plan.size.height)
    }

    @ViewBuilder private func tile(_ chat: Conversation, slot: CGRect, plan: TilePlan, canvas: GeometryProxy) -> some View {
        let dragging = store.tileDrag?.id == chat.id
        let frame = dragging ? (store.tileDrag?.frame ?? slot) : slot
        let movable = store.workspace.layout != .focus && store.tiles.count > 1
        ConversationTile(conversation: chat,
            onDragChanged: movable ? { (translation: CGSize) in store.dragTile(chat.id, translation: translation, plan: plan) } : nil,
            onDragEnded: { store.finishTileDrag(chat.id) })
            .frame(width: frame.width, height: frame.height)
            .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: dragging ? 22 : 0, y: dragging ? 10 : 0)
            .id(chat.id)
            .zIndex(dragging ? 100 : 1)
            .transition(tileTransition(chat.id, target: slot, canvas: canvas))
            .onAppear { store.consumeOpeningOrigin(chat.id) }
            .tileFrame(frame)
    }

    private var focusPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.tiles) { chat in
                    Button { store.focus(chat.id) } label: {
                        HStack(spacing: 7) { Avatar(conversation: chat, size: 22); Text(chat.name).font(.system(size: 12, weight: .medium)).lineLimit(1) }
                            .padding(8).background(store.focused?.id == chat.id ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                            // The whole chip, padding and background included, takes the click.
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(TileControlStyle())
                }
            }
        }
    }
    private func tileTransition(_ id: String, target: CGRect, canvas: GeometryProxy) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        let origin = canvas.frame(in: .named("workspace")).origin
        // A tile grows out of the sidebar row that opened it. Focus mode swaps tiles in place, so
        // every conversation there grows from the same spot at the left edge.
        let sidebar = store.workspace.layout == .focus ? nil : store.openingOrigins[id]
        let source = sidebar ?? CGPoint(x: origin.x - 60, y: origin.y + target.midY)
        let insertion = AnyTransition.scale(scale: 0.06)
            .combined(with: .offset(x: source.x - origin.x - target.midX, y: source.y - origin.y - target.midY))
            .combined(with: .opacity).animation(Motion.layout)
        let removal = AnyTransition.scale(scale: 0.03).combined(with: .opacity).animation(Motion.close)
        return .asymmetric(insertion: insertion, removal: removal)
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
@MainActor final class KeyboardRouter: ObservableObject {
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

/// Reports the hosting window without taking part in hit testing.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ReaderView { let view = ReaderView(); view.onChange = onChange; return view }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }
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
