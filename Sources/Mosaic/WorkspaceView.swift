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
                if store.tiles.isEmpty { emptyWorkspace }
                else { TileWorkspace().padding(16) }
            }.background(Palette.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
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
    private var isOpen: Bool { store.workspace.openIDs.contains(conversation.id) }
    var body: some View {
        Button { store.open(conversation.id) } label: {
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
        }.buttonStyle(.plain).accessibilityLabel("Open \(conversation.name)")
            .contextMenu {
                Button(isOpen ? "Close tile" : "Open in workspace") { if isOpen { store.close(conversation.id) } else { store.open(conversation.id) } }
                if store.isLive { Button("Open Messages") { store.openMessages(conversation) } }
            }
            .onDrag { NSItemProvider(object: conversation.id as NSString) }
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

struct TileWorkspace: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        GeometryReader { geometry in
            switch store.workspace.layout {
            case .grid:
                let rows = stride(from: 0, to: store.tiles.count, by: 2).map { Array(store.tiles[$0..<min($0 + 2, store.tiles.count)]) }
                ScrollView(.vertical) {
                    TileSplitView(axis: .vertical, minimumPaneSize: 235, panes: rows.enumerated().map { index, row in
                        TileSplitView.Pane(id: "row-\(index)", content: AnyView(
                            TileSplitView(axis: .horizontal, minimumPaneSize: 275, panes: row.map { chat in
                                TileSplitView.Pane(id: chat.id, content: AnyView(
                                    ConversationTile(conversation: chat).environmentObject(store)
                                        .padding(4).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
                                ))
                            }).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
                        ))
                    }).frame(width: geometry.size.width, height: max(geometry.size.height, CGFloat(rows.count) * 250))
                }
            case .columns:
                ScrollView(.horizontal) {
                    TileSplitView(axis: .horizontal, minimumPaneSize: 300, panes: store.tiles.map { chat in
                        TileSplitView.Pane(id: chat.id, content: AnyView(
                            ConversationTile(conversation: chat).environmentObject(store)
                                .padding(4).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
                        ))
                    }).frame(width: max(geometry.size.width, CGFloat(store.tiles.count) * 301 - 1), height: geometry.size.height - 12)
                }
            case .focus:
                VStack(spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.tiles) { chat in
                                Button { store.focus(chat.id) } label: {
                                    HStack(spacing: 7) { Avatar(conversation: chat, size: 22); Text(chat.name).font(.system(size: 12, weight: .medium)) }
                                        .padding(8).background(store.focused?.id == chat.id ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if let focused = store.focused { ConversationTile(conversation: focused) }
                }
            }
        }
    }
}
