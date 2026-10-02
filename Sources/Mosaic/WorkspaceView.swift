import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

enum Palette {
    static let accent = Color(red: 0.29, green: 0.34, blue: 0.86)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let colors: [Color] = [Color(red: 0.40, green: 0.48, blue: 0.76), Color(red: 0.77, green: 0.52, blue: 0.34), Color(red: 0.39, green: 0.63, blue: 0.57), Color(red: 0.72, green: 0.44, blue: 0.56), Color(red: 0.52, green: 0.48, blue: 0.70)]
    static func avatar(_ id: String) -> Color { colors[id.utf8.reduce(0) { ($0 + Int($1)) % colors.count }] }
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @FocusState private var searchFocused: Bool
    @State private var sidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible { sidebar.frame(width: 256); Divider() }
            VStack(spacing: 0) {
                toolbar
                Divider()
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
                footer
            }.background(Palette.canvas)
        }
        .tint(Palette.accent)
        .sheet(isPresented: $store.showSetup) { SetupView().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in sidebarVisible = true; searchFocused = true }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.accent)
                Text("Mosaic").font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 46).padding(.bottom, 20)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a conversation", text: $store.search).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Find a conversation")
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 16)
            HStack {
                Text("CONVERSATIONS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer(); Text("\(store.conversations.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 10)
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
            }
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(store.isLive && store.connectionError == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(store.isLive ? "Messages on this Mac" : "Demo workspace").font(.system(size: 12, weight: .medium))
                }
                Button { store.showSetup = true } label: {
                    HStack { Text(store.isLive ? "Connection settings" : "Connect your Messages"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 12)).foregroundStyle(Palette.accent)
                }.buttonStyle(.plain)
            }.padding(20)
        }.background(.regularMaterial)
    }
    private var toolbar: some View {
        HStack(spacing: 16) {
            Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 17)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Toggle conversation sidebar")
            VStack(alignment: .leading, spacing: 4) {
                Text("Your workspace").font(.system(size: 21, weight: .semibold))
                Text(store.isLive ? "Keep the conversation going." : "A little more room for everyone.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 3) {
                ForEach(WorkspaceLayout.allCases, id: \.self) { layout in
                    Button { store.workspace.layout = layout } label: {
                        Label(layout.title, systemImage: layout == .grid ? "square.grid.2x2" : layout == .columns ? "rectangle.split.3x1" : "rectangle.inset.filled")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(store.workspace.layout == layout ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .shadow(color: .black.opacity(store.workspace.layout == layout ? 0.06 : 0), radius: 2, y: 1)
                    }.buttonStyle(.plain).foregroundStyle(store.workspace.layout == layout ? .primary : .secondary)
                        .accessibilityLabel("\(layout.title) layout")
                }
            }.padding(3).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Button { store.showSetup = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Connection settings")
        }.padding(.horizontal, 24).padding(.top, 35).padding(.bottom, 20)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 11))
            Text("\(store.tiles.count) of \(Workspace.maximumTiles) tiles")
            Text("·").padding(.horizontal, 2)
            Text("Drag headers to reorder · Drag dividers to resize")
            Spacer()
            if store.isLive {
                if store.isRefreshing { ProgressView().controlSize(.mini) }
                Text(store.lastRefreshed == nil ? "Connecting…" : "Refreshes every 3 seconds")
            } else { Text("Sample chats · Sends stay in this demo") }
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
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
            Circle().fill(Palette.avatar(conversation.id).gradient)
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
                    VSplitView {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HSplitView {
                                ForEach(row) { chat in
                                    ConversationTile(conversation: chat)
                                        .padding(4)
                                        .frame(minWidth: 275, idealWidth: geometry.size.width / CGFloat(row.count), maxWidth: .infinity,
                                               minHeight: 235, idealHeight: geometry.size.height / CGFloat(rows.count), maxHeight: .infinity)
                                }
                            }
                        }
                    }.frame(width: geometry.size.width, height: max(geometry.size.height, CGFloat(rows.count) * 250))
                }
            case .columns:
                ScrollView(.horizontal) {
                    HSplitView {
                        ForEach(store.tiles) { chat in
                            ConversationTile(conversation: chat)
                                .frame(minWidth: 300, idealWidth: max(300, geometry.size.width / CGFloat(store.tiles.count)), maxWidth: .infinity)
                        }
                    }.frame(minWidth: max(geometry.size.width, CGFloat(store.tiles.count) * 300), minHeight: geometry.size.height - 12)
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
