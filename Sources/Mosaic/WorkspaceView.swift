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
    static func outgoing(service: String) -> Color {
        service.caseInsensitiveCompare("iMessage") == .orderedSame ? Color(nsColor: .systemBlue) : Color(nsColor: .systemGreen)
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 256)
            Divider()
            VStack(spacing: 0) {
                if let banner = store.banner {
                    HStack { Text(banner).font(.callout); Spacer(); Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(12).background(Palette.accent.opacity(0.08))
                }
                if let error = store.connectionError {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.lock").foregroundStyle(.orange)
                        Text(error).font(.callout).lineLimit(3)
                        Spacer()
                        Button("Set up") { store.showSetup = true }
                        Button("Retry") { Task { await store.refresh() } }
                    }.padding(14).background(Color.orange.opacity(0.08))
                }
                ZStack {
                    TileWorkspace().padding(16)
                    if store.tiles.isEmpty { emptyWorkspace.transition(.opacity) }
                }
            }.background(Palette.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: "workspace")
        .tint(Palette.accent)
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
                .padding(.horizontal, 16).padding(.top, 36)
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
            Divider().padding(.horizontal, 16)
            Button { store.showSetup = true } label: {
                HStack { Text(store.isLive ? "Connection settings" : "Connect your Messages"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 12)).foregroundStyle(Palette.accent)
            }.buttonStyle(.plain).padding(20)
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
    private var isOpen: Bool { store.workspace.openIDs.contains(conversation.id) }
    var body: some View {
        Button { store.open(conversation.id, from: origin) } label: {
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
        }.buttonStyle(TileControlStyle()).accessibilityLabel("Open \(conversation.name)")
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

struct TileWorkspace: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var gridFractions: [Int: CGFloat] = [:]
    @State private var rowWeights: [CGFloat] = []
    @State private var columnWeights: [CGFloat] = []
    @State private var resizeStart: TilePlan?
    var body: some View {
        GeometryReader { geometry in
            let layout = store.workspace.layout
            let order = layout == .focus ? store.focused.map { [$0.id] } ?? [] : store.tileDrag?.order ?? store.tiles.map(\.id)
            let viewport = CGSize(width: geometry.size.width, height: geometry.size.height - (layout == .focus ? 44 : 0))
            let plan = TileLayout.plan(order: order, viewport: viewport, layout: layout,
                gridFractions: gridFractions, rowWeights: rowWeights, columnWeights: columnWeights)
            VStack(spacing: 8) {
                if layout == .focus { focusPicker.frame(height: 36).transition(.move(edge: .top).combined(with: .opacity)) }
                ScrollView(layout == .columns ? .horizontal : .vertical) {
                    GeometryReader { canvas in
                        ZStack(alignment: .topLeading) {
                            ForEach(store.tiles) { chat in
                                if let target = plan.frames[chat.id] {
                                    let dragging = store.tileDrag?.id == chat.id
                                    let frame = dragging ? store.tileDrag!.frame : target
                                    ConversationTile(conversation: chat,
                                        onDragChanged: { translation in store.dragTile(chat.id, translation: translation, plan: plan) },
                                        onDragEnded: { store.finishTileDrag() })
                                        .frame(width: frame.width, height: frame.height)
                                        .scaleEffect(dragging && !Motion.reduced ? 1.015 : 1)
                                        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: dragging ? 18 : 0, y: dragging ? 8 : 0)
                                        .transition(tileTransition(chat.id, target: target, canvas: canvas))
                                        .offset(x: frame.minX, y: frame.minY)
                                        .zIndex(dragging ? 100 : 1)
                                        .transaction { if dragging { $0.animation = nil } }
                                }
                            }
                            ForEach(plan.dividers) { divider in
                                Color.clear.contentShape(Rectangle())
                                    .frame(width: divider.frame.width, height: divider.frame.height)
                                    .position(x: divider.frame.midX, y: divider.frame.midY)
                                    .onHover { hovering in
                                        if hovering { (divider.movesHorizontally ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
                                        else { NSCursor.arrow.set() }
                                    }
                                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tileCanvas"))
                                        .onChanged { value in resize(divider, translation: value.translation, plan: plan) }
                                        .onEnded { _ in resizeStart = nil })
                                    .allowsHitTesting(store.tileDrag == nil)
                                    .zIndex(2)
                            }
                        }
                        .frame(width: plan.size.width, height: plan.size.height, alignment: .topLeading)
                        .coordinateSpace(name: "tileCanvas")
                    }
                    .frame(width: plan.size.width, height: plan.size.height)
                }
            }
        }
        .onChange(of: store.workspace.openIDs.count) { _, _ in
            withAnimation(Motion.layout) { gridFractions = [:]; rowWeights = []; columnWeights = [] }
            resizeStart = nil
        }
    }
    private var focusPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.tiles) { chat in
                    Button { store.focus(chat.id) } label: {
                        HStack(spacing: 7) { Avatar(conversation: chat, size: 22); Text(chat.name).font(.system(size: 12, weight: .medium)) }
                            .padding(8).background(store.focused?.id == chat.id ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(TileControlStyle())
                }
            }
        }
    }
    private func tileTransition(_ id: String, target: CGRect, canvas: GeometryProxy) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        let origin = canvas.frame(in: .named("workspace")).origin
        let source = store.openingOrigins[id] ?? CGPoint(x: origin.x - 60, y: origin.y + target.midY)
        let insertion = AnyTransition.scale(scale: 0.06)
            .combined(with: .offset(x: source.x - origin.x - target.midX, y: source.y - origin.y - target.midY))
            .combined(with: .opacity).animation(Motion.layout)
        let removal = AnyTransition.scale(scale: 0.03).combined(with: .opacity).animation(Motion.close)
        return .asymmetric(insertion: insertion, removal: removal)
    }
    private func resize(_ divider: TileDivider, translation: CGSize, plan: TilePlan) {
        if resizeStart == nil { resizeStart = plan }
        guard let start = resizeStart else { return }
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
