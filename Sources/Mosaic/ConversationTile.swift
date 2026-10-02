import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

struct ConversationTile: View {
    @EnvironmentObject private var store: WorkspaceStore
    let conversation: Conversation
    var onDragChanged: ((CGSize) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    @State private var isDropTarget = false
    @State private var followsNewest = true
    @State private var scrollTarget: String? = "bottom"
    private var isFocused: Bool { store.workspace.focusedID == conversation.id }
    private var draft: Binding<String> { store.draft(conversation.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            messages.frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(isDropTarget ? Palette.accent : isFocused ? Palette.accent.opacity(0.35) : Color.primary.opacity(0.09), lineWidth: isDropTarget ? 2 : 1))
        .shadow(color: .black.opacity(0.025), radius: 5, y: 2)
        .animation(Motion.control, value: isFocused)
        .animation(Motion.control, value: isDropTarget)
        .onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value else { return }
                Task { @MainActor in
                    // Accept only known conversation IDs, never external text as a recipient.
                    guard store.conversations.contains(where: { $0.id == value }) else { return }
                    store.open(value); store.reorder(value, before: conversation.id)
                }
            }
            return true
        }
    }
    private var header: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Avatar(conversation: conversation, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(conversation.isGroup ? "\(conversation.participants.count + 1) people · \(conversation.service)" : conversation.service)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle()).onTapGesture { store.focus(conversation.id) }
            .help("Drag this header to move the whole tile")
            .onHover { hovering in
                if store.workspace.layout != .focus { (hovering ? NSCursor.openHand : NSCursor.arrow).set() }
            }
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("tileCanvas"))
                .onChanged { value in onDragChanged?(value.translation); if store.workspace.layout != .focus { NSCursor.closedHand.set() } }
                .onEnded { _ in onDragEnded?(); NSCursor.openHand.set() })
            Button { store.close(conversation.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(TileControlStyle())
                .help("Close tile — your draft is kept").accessibilityLabel("Close \(conversation.name) tile")
        }
        .font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 12)
    }
    private var messages: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.isLive && conversation.messages.count >= (store.historyLimits[conversation.id] ?? 100) && conversation.messages.count < 1000 {
                        Button("Load earlier messages") { followsNewest = false; store.loadMore(conversation.id) }
                            .font(.caption).frame(maxWidth: .infinity)
                    }
                    if conversation.messages.isEmpty {
                        Text(store.isLive ? "Loading this conversation…" : "Start the conversation.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.presentationID) { index, message in
                        if index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: conversation.messages[index - 1].date) {
                            Text(message.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        MessageBubble(message: message, group: conversation.isGroup, senderName: message.sender.map { store.name(for: $0) }, live: store.isLive, service: conversation.service)
                            .id(message.presentationID)
                            .transition(Motion.reduced ? .opacity : .offset(x: message.isFromMe ? 12 : -12, y: 38)
                                .combined(with: .scale(scale: 0.86, anchor: message.isFromMe ? .bottomTrailing : .bottomLeading))
                                .combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.scrollTargetLayout().padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition(id: $scrollTarget, anchor: .bottom)
            .task(id: conversation.id) {
                // Let the tile's first layout settle before following its newest message.
                try? await Task.sleep(for: .milliseconds(150))
                reader.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation.messages.last?.presentationID) { _, _ in
                if followsNewest { withAnimation(Motion.message) { reader.scrollTo("bottom", anchor: .bottom) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsNewest {
                    Button { followsNewest = true; withAnimation(Motion.message) { reader.scrollTo("bottom", anchor: .bottom) } } label: {
                        Label("Latest", systemImage: "arrow.down").font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                    }.buttonStyle(.plain).padding(12)
                }
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 7) {
            if let error = store.sendErrors[conversation.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ComposerEditor(text: draft, accessibilityLabel: "Message to \(conversation.name)", focusRequest: 0,
                        onFocus: { store.focus(conversation.id) }, onSend: { Task { await store.send(conversation.id) } })
                        .frame(height: 42)
                    if draft.wrappedValue.isEmpty {
                        Text("Message \(conversation.name)").font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.top, 10).allowsHitTesting(false)
                    }
                }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
                Button { Task { await store.send(conversation.id) } } label: {
                    if store.sendingIDs.contains(conversation.id) { ProgressView().controlSize(.small).frame(width: 31, height: 31) }
                    else { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 31, height: 31).background(Palette.outgoing(service: conversation.service), in: Circle()) }
                }.buttonStyle(TileControlStyle()).padding(.bottom, 5)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.sendingIDs.contains(conversation.id) || !store.canSend)
                    .opacity(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canSend ? 0.35 : 1)
                    .accessibilityLabel("Send to \(conversation.name)").help("Send to \(conversation.name) · Return")
            }
        }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
    }
}

struct MessageBubble: View {
    let message: Message
    let group: Bool
    let senderName: String?
    let live: Bool
    let service: String
    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            if message.isFromMe { Spacer(minLength: 30) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                if group && !message.isFromMe, let senderName { Text(senderName).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 4) }
                Text(message.text).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                    .foregroundStyle(message.isFromMe ? .white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(message.isFromMe ? Palette.outgoing(service: service) : Palette.incoming, in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 4) {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                    if message.isFromMe {
                        if message.error != 0 { Text("· Failed").foregroundStyle(.red) }
                        else if !live { Text("· Demo") }
                        else if message.isRead { Text("· Read") }
                        else if message.isDelivered { Text("· Delivered") }
                        else if message.id.hasPrefix("pending-") { Text("· Submitted to Messages") }
                    }
                }.font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 3)
            }
            if !message.isFromMe { Spacer(minLength: 30) }
        }
    }
}
