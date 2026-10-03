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
    @State private var composerHeight = ComposerEditor.minimumHeight
    /// Resets automatically even when the system cancels a drag, so a tile can never stay "lifted".
    @GestureState private var headerDragging = false
    private var isFocused: Bool { store.workspace.focusedID == conversation.id }
    private var draft: Binding<String> { store.draft(conversation.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            MessageList(conversation: conversation, isLive: store.isLive,
                        canLoadMore: store.isLive && conversation.messages.count >= (store.historyLimits[conversation.id] ?? 100) && conversation.messages.count < 1000,
                        senderNames: senderNames, onLoadMore: { [store, id = conversation.id] in store.loadMore(id) })
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A click anywhere in the thread puts the keyboard in this tile's composer; links,
                // pictures and text selection keep working because this runs alongside their gestures.
                .simultaneousGesture(TapGesture().onEnded { store.requestComposerFocus(conversation.id) })
            composer
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isDropTarget ? Palette.accent : isFocused ? Palette.accent.opacity(0.45) : Color.primary.opacity(0.09),
                              lineWidth: isDropTarget || isFocused ? 1.5 : 1)
                .animation(Motion.control, value: isFocused)
                .animation(Motion.control, value: isDropTarget)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.025), radius: 5, y: 2)
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
        .onChange(of: headerDragging) { _, dragging in if !dragging { onDragEnded?() } }
    }

    private var senderNames: [String: String] {
        guard conversation.isGroup else { return [:] }
        return Dictionary(conversation.participants.map { ($0, store.name(for: $0)) }, uniquingKeysWith: { first, _ in first })
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
            .contentShape(Rectangle())
            .onTapGesture { store.requestComposerFocus(conversation.id) }
            .help(onDragChanged == nil ? "" : "Drag to move this tile")
            .hoverCursor(.openHand, enabled: onDragChanged != nil && store.tileDrag == nil)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(TileCanvas.space))
                .updating($headerDragging) { _, state, _ in state = true }
                .onChanged { value in onDragChanged?(value.translation) }
                .onEnded { _ in onDragEnded?() })
            Button { store.close(conversation.id) } label: {
                Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(TileControlStyle())
            .help("Close tile — your draft is kept").accessibilityLabel("Close \(conversation.name) tile")
        }
        .font(.system(size: 11)).buttonStyle(.plain).padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 12)
    }

    private var composer: some View {
        VStack(spacing: 7) {
            if let error = store.sendErrors[conversation.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerEditor(text: draft, placeholder: placeholder, conversationID: conversation.id,
                    accessibilityLabel: "Message to \(conversation.name)",
                    focusRequest: store.focusTarget == conversation.id ? store.focusToken : 0,
                    height: $composerHeight,
                    onFocus: { store.focus(conversation.id, animated: false) },
                    onSend: { Task { await store.send(conversation.id) } },
                    onTab: { forward in store.moveFocus(forward: forward, from: conversation.id) })
                    .frame(height: composerHeight)
                    // The field's corners match the tile's.
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
                emojiButton.padding(.bottom, (ComposerEditor.minimumHeight - 31) / 2)
            }
        }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
    }

    /// The service name, as Messages labels its own field.
    private var placeholder: String {
        switch conversation.service.lowercased() {
        case "imessage": return "iMessage"
        case "sms": return "Text Message"
        case "rcs": return "RCS Message"
        default: return conversation.service
        }
    }

    /// Opens Emoji & Symbols for this tile's field. Return sends; there is no send button.
    private var emojiButton: some View {
        Button {
            store.focus(conversation.id, animated: false)
            DraftTextView.editor(for: conversation.id)?.showEmojiPicker()
        } label: {
            if store.sendingIDs.contains(conversation.id) { ProgressView().controlSize(.small).frame(width: 31, height: 31) }
            else {
                Image(systemName: "face.smiling").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                    .frame(width: 31, height: 31).contentShape(Circle())
            }
        }
        .buttonStyle(TileControlStyle())
        .disabled(store.sendingIDs.contains(conversation.id))
        .accessibilityLabel("Insert emoji into message to \(conversation.name)").help("Emoji & Symbols")
    }
}

/// Marks layout changes (tiles opening, closing, moving, resizing) so message content can opt out of them.
struct TileLayoutTransactionKey: TransactionKey { static let defaultValue = false }

/// The conversation history. It only re-renders when its own inputs change, never during tile drags.
struct MessageList: View, Equatable {
    let conversation: Conversation
    let isLive: Bool
    let canLoadMore: Bool
    let senderNames: [String: String]
    let onLoadMore: () -> Void
    @State private var followsNewest = true

    static func == (lhs: MessageList, rhs: MessageList) -> Bool {
        lhs.conversation == rhs.conversation && lhs.isLive == rhs.isLive && lhs.canLoadMore == rhs.canLoadMore && lhs.senderNames == rhs.senderNames
    }

    /// Scrolls to the newest message. Rows added in the current update have no size yet, so the
    /// scroll is repeated once layout has run; otherwise a freshly loaded history landed mid-way.
    private func scrollToLatest(_ reader: ScrollViewProxy, animated: Bool) {
        let scroll = {
            if animated && !Motion.reduced { withAnimation(Motion.message) { reader.scrollTo("bottom", anchor: .bottom) } }
            else { reader.scrollTo("bottom", anchor: .bottom) }
        }
        scroll()
        DispatchQueue.main.async(execute: scroll)
        if !animated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reader.scrollTo("bottom", anchor: .bottom) } }
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                // A plain VStack: a lazy stack inserts and removes rows while a tile grows or shrinks,
                // and each insertion replayed the new-message animation (the jumping text).
                VStack(alignment: .leading, spacing: 10) {
                    if canLoadMore {
                        Button("Load earlier messages") { followsNewest = false; onLoadMore() }
                            .font(.caption).frame(maxWidth: .infinity)
                    }
                    if conversation.messages.isEmpty {
                        Text(isLive ? "Loading this conversation…" : "Start the conversation.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    let latestOutgoing = conversation.messages.last(where: \.isFromMe)?.presentationID
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.presentationID) { index, message in
                        VStack(spacing: 10) {
                            if index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: conversation.messages[index - 1].date) {
                                Text(message.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            MessageBubble(message: message, group: conversation.isGroup,
                                          senderName: message.sender.map { senderNames[$0] ?? $0 }, live: isLive, service: conversation.service,
                                          showsStatus: message.presentationID == latestOutgoing)
                        }
                        .id(message.presentationID)
                        .transition(Motion.reduced ? .opacity : .offset(x: message.isFromMe ? 12 : -12, y: 38)
                            .combined(with: .scale(scale: 0.86, anchor: message.isFromMe ? .bottomTrailing : .bottomLeading))
                            .combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .background(ThinScrollerInstaller())
                // Bubbles take their final positions at once during tile animations; the card around them
                // still grows, shrinks and moves smoothly. Interpolating every bubble made text slide around.
                .transaction { transaction in
                    if transaction[TileLayoutTransactionKey.self] && !Motion.animateMessageLayout { transaction.animation = nil }
                }
            }
            .defaultScrollAnchor(.bottom)
            .task(id: conversation.id) {
                // Let the tile's first layout settle before following its newest message.
                try? await Task.sleep(for: .milliseconds(150))
                if followsNewest { scrollToLatest(reader, animated: false) }
            }
            .onChange(of: conversation.messages.last?.presentationID) { previous, _ in
                guard followsNewest else { return }
                // History arriving in an open tile (previous == nil) jumps straight to the end; a new
                // message slides in.
                scrollToLatest(reader, animated: previous != nil)
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
}

struct MessageBubble: View {
    let message: Message
    let group: Bool
    let senderName: String?
    let live: Bool
    let service: String
    /// Delivery and read receipts appear under the most recent sent message only, as in Messages.
    var showsStatus = true

    var body: some View {
        let fromMe = message.isFromMe
        let previewURL = LinkDetector.previewURL(in: message.text)
        let showsText = !message.text.isEmpty && !LinkDetector.isOnlyLink(message.text)
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 4) {
            if group && !fromMe, let senderName {
                Text(senderName).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 4)
            }
            ForEach(message.attachments) { attachment in AttachmentView(attachment: attachment) }
            if showsText {
                Text(attributedText).font(.system(size: 12)).lineSpacing(2)
                    .foregroundStyle(fromMe ? Color.white : Color.primary)
                    .tint(fromMe ? Color.white : Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(fromMe ? Palette.outgoing(service: service) : Palette.incoming,
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            if let previewURL { LinkPreviewCard(url: previewURL) }
            HStack(spacing: 4) {
                Text(message.date.formatted(date: .omitted, time: .shortened))
                if fromMe {
                    // A sent message shows only its time until Messages reports delivery.
                    if message.error != 0 { Text("· Failed").foregroundStyle(.red) }
                    else if showsStatus && message.isRead { Text("· Read") }
                    else if showsStatus && message.isDelivered { Text("· Delivered") }
                }
            }.font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 3)
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .padding(fromMe ? .leading : .trailing, 36)
    }

    /// Message text with web links made clickable.
    private var attributedText: AttributedString {
        var attributed = AttributedString(message.text)
        for match in LinkDetector.links(in: message.text) {
            guard let range = Range(match.range, in: message.text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = match.url
        }
        return attributed
    }
}
