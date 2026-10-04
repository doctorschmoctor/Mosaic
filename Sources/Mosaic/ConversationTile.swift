import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

struct ConversationTile: View {
    @Environment(WorkspaceStore.self) private var store
    let conversation: Conversation
    var onDragChanged: ((CGSize) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    @State private var isDropTarget = false
    @State private var composerHeight = ComposerEditor.minimumHeight
    @Environment(\.zoomScale) private var zoom
    @State private var closeHovered = false
    private var isFocused: Bool { store.focusedID == conversation.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if conversation.isComposeDraft {
                RecipientField(draftID: conversation.id)
                if conversation.messages.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    MessageList(conversation: conversation, isLive: store.isLive, canLoadMore: false, senderNames: [:], zoom: zoom,
                            animateNew: store.animateMessages, onLoadMore: {})
                        .equatable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                MessageList(conversation: conversation, isLive: store.isLive,
                            canLoadMore: store.isLive && conversation.messages.count >= (store.historyLimits[conversation.id] ?? 100) && conversation.messages.count < 1000,
                            senderNames: senderNames, zoom: zoom, animateNew: store.animateMessages,
                            seenBoundary: store.seenBoundary(conversation.id),
                            onLoadMore: { [store, id = conversation.id] in store.loadMore(id) },
                            onTailSeen: { [store, id = conversation.id] in store.markSeen(id) })
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A click anywhere in the thread puts the keyboard in this tile's composer; links
                    // and pictures keep working because this runs alongside their gestures.
                    .simultaneousGesture(TapGesture().onEnded { store.requestComposerFocus(conversation.id) })
            }
            composer
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isDropTarget ? Palette.accent : isFocused ? Palette.accent.opacity(0.45) : Color.primary.opacity(0.09),
                              lineWidth: isDropTarget || isFocused ? 1.5 : 1)
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
    }

    private var senderNames: [String: String] {
        guard conversation.isGroup else { return [:] }
        return Dictionary(conversation.participants.map { ($0, store.name(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    private var header: some View {
        HStack(spacing: 9) {
            if conversation.isComposeDraft {
                ZStack {
                    Circle().fill(Palette.accent.opacity(0.15))
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                }.frame(width: 30, height: 30).accessibilityHidden(true)
            } else {
                Avatar(conversation: conversation, size: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(conversation.isComposeDraft ? (conversation.participants.isEmpty ? "Choose who to message" : "\(conversation.participants.count) \(conversation.participants.count == 1 ? "person" : "people")")
                     : conversation.isGroup ? "\(conversation.participants.count + 1) people · \(conversation.service)" : conversation.service)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            // The close glyph. Drawn here, in SwiftUI, like the rest of the header; its clicks are
            // detected by the handle underneath (TileHeaderHandle.closeRect matches this frame).
            Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                .frame(width: TileHeaderHandle.closeSize, height: TileHeaderHandle.closeSize)
                .background(closeHovered ? Color.primary.opacity(0.09) : .clear, in: Circle())
                .accessibilityHidden(true)
        }
        .font(.system(size: 11)).padding(.leading, 14).padding(.trailing, TileHeaderHandle.closeInset).padding(.vertical, 12)
        // The handle is an overlay, not a background: SwiftUI content above an AppKit view takes the
        // clicks (and, on the title-bar strip, lets the window move). Covering the whole header with
        // the transparent handle makes every press — on the name, the avatar or the × — reach it.
        .overlay(TileHeaderHandle(draggable: onDragChanged != nil, closeLabel: "Close \(conversation.name) tile",
            onDragChanged: { onDragChanged?($0) }, onDragEnded: { onDragEnded?() },
            onClick: { store.requestComposerFocus(conversation.id) }, onClose: { store.close(conversation.id) },
            onCloseHover: { hovered in if closeHovered != hovered { closeHovered = hovered } }))
        .help(onDragChanged == nil ? "" : "Drag to move this tile")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(conversation.name)
    }

    private var composer: some View {
        VStack(spacing: 7) {
            if let error = store.sendErrors[conversation.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            } else if let note = store.sendNotes[conversation.id] {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Photos and files, as in Messages.
                AttachmentMenuButton(conversationName: conversation.name,
                    onFiles: { urls in store.attach(urls, to: conversation.id) },
                    onBeginAdding: { count in store.beginImports(count, to: conversation.id) },
                    onAdded: { slot, url in store.completeImport(slot, url: url, in: conversation.id) })
                    .frame(width: 31, height: 31).padding(.bottom, max(0, (ComposerEditor.minimumHeight(zoom: zoom) - 31) / 2))
                VStack(spacing: 0) {
                    if let files = store.outgoing[conversation.id], !files.isEmpty {
                        // Pictures and files going out with the next message, above the text.
                        AttachmentStrip(files: files) { store.removeAttachment($0, from: conversation.id) }
                    }
                    ComposerEditor(text: store.draft(conversation.id), placeholder: placeholder, conversationID: conversation.id,
                        accessibilityLabel: "Message to \(conversation.name)",
                        focusRequest: store.focusTarget == conversation.id ? store.focusToken : 0,
                        zoom: zoom,
                        height: $composerHeight,
                        onFocus: { store.focus(conversation.id) },
                        onSend: { Task { await store.send(conversation.id) } },
                        onTab: { forward in store.moveFocus(forward: forward, from: conversation.id) },
                        onCancel: conversation.isComposeDraft ? { store.close(conversation.id) } : nil,
                        onAttachFiles: { urls in store.attach(urls, to: conversation.id) },
                        onAttachPicture: { data, type in store.attachPicture(data, type: type, to: conversation.id) })
                        .frame(height: composerHeight)
                }
                // The field's corners match the tile's.
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
                emojiButton.padding(.bottom, max(0, (ComposerEditor.minimumHeight(zoom: zoom) - 31) / 2))
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
            store.focus(conversation.id)
            DraftTextView.editor(for: conversation.id)?.showEmojiPicker()
        } label: {
            Image(systemName: "face.smiling").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                .frame(width: 31, height: 31).contentShape(Circle())
        }
        .buttonStyle(TileControlStyle())
        .accessibilityLabel("Insert emoji into message to \(conversation.name)").help("Emoji & Symbols")
    }
}

/// The conversation history. It only re-renders when its own inputs change, never during tile drags.
/// Its scroll position is kept by `ScrollPinner` in AppKit: a list showing the newest message stays
/// on it through resizes, layout switches and new messages, and a list the reader scrolled up stays
/// on the same rows when older messages load above them.
struct MessageList: View, Equatable {
    let conversation: Conversation
    let isLive: Bool
    let canLoadMore: Bool
    let senderNames: [String: String]
    /// The shared conversation zoom: fonts, bubbles and media scale; the tile around them does not.
    var zoom: CGFloat = 1
    /// Whether a newly arrived or sent message settles in with a short effect (Settings).
    var animateNew = true
    /// The newest row the reader has seen; incoming messages after it are new.
    var seenBoundary: Int64? = nil
    let onLoadMore: () -> Void
    /// The newest message is in view: everything up to it has been seen.
    var onTailSeen: () -> Void = {}
    @State private var isNearBottom = true
    /// A reply's original that was just jumped to, outlined for a moment.
    @State private var highlightedID: String?
    @State private var latestRequest = 0
    /// Where each row sits in the content, for the scroll anchor; a class, so rows reporting
    /// their frames cost no view invalidation.
    @State private var registry = ThreadRowRegistry()
    /// The rows that just arrived at the tail and settle in once.
    @State private var freshIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: MessageList, rhs: MessageList) -> Bool {
        lhs.conversation == rhs.conversation && lhs.isLive == rhs.isLive && lhs.canLoadMore == rhs.canLoadMore
            && lhs.senderNames == rhs.senderNames && lhs.zoom == rhs.zoom && lhs.animateNew == rhs.animateNew
            && lhs.seenBoundary == rhs.seenBoundary
    }

    /// A person in this thread, as the thread names them.
    private func name(of handle: String?) -> String {
        guard let handle else { return conversation.isGroup ? "Someone" : conversation.name }
        return senderNames[handle] ?? (conversation.isGroup ? Recipient.display(handle) : conversation.name)
    }
    private func name(of actor: ReactionActor) -> String {
        switch actor {
        case .me: return "You"
        case .handle(let handle): return name(of: handle)
        case .unknown: return "Someone"
        }
    }
    private func author(of message: Message) -> String { message.isFromMe ? "You" : name(of: message.sender) }
    /// The first incoming message after the seen boundary, where the New Messages line goes.
    static func firstUnread(in rows: [MessageRow], after boundary: Int64?) -> String? {
        guard let boundary else { return nil }
        return rows.first { row in
            !row.message.isFromMe && row.message.kind == .message && !row.message.isUnsent && (Int64(row.message.id) ?? 0) > boundary
        }?.id
    }

    var body: some View {
        let rows = MessageRow.rows(for: conversation)
        let content = ThreadContent(first: rows.first?.id, last: rows.last?.id, count: rows.count)
        let ids = rows.map(\.id)
        let reactions = Reactions.reduce(conversation.reactions)
        let byGUID = Dictionary(conversation.messages.compactMap { message in message.guid.map { ($0, message) } }, uniquingKeysWith: { first, _ in first })
        // The New Messages line only while reading above them; at the tail everything is being seen.
        let firstUnread = isNearBottom ? nil : Self.firstUnread(in: rows, after: seenBoundary)
        ScrollViewReader { proxy in
        ScrollView {
            // A plain VStack: a lazy stack inserts and removes rows while a tile grows or shrinks,
            // which made rows jump.
            VStack(alignment: .leading, spacing: 10 * zoom) {
                if canLoadMore {
                    Button("Load earlier messages", action: onLoadMore).font(.caption).frame(maxWidth: .infinity)
                }
                if conversation.messages.isEmpty {
                    Text(isLive ? "Loading this conversation…" : "Start the conversation.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
                ForEach(rows) { row in
                    VStack(spacing: 10 * zoom) {
                        if let day = row.dayLabel {
                            Text(day).font(.system(size: 10 * zoom, weight: .medium))
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 4 * zoom)
                        }
                        if row.id == firstUnread { UnreadDivider() }
                        MessageBubble(message: row.message, threadID: conversation.id, group: conversation.isGroup,
                                      senderName: row.showsSender ? row.message.sender.map { senderNames[$0] ?? $0 } : nil,
                                      live: isLive, service: conversation.service,
                                      showsStatus: row.showsStatus, showsTime: row.showsTime,
                                      authorName: author(of: row.message),
                                      reactions: row.message.guid.flatMap { reactions[$0] } ?? [],
                                      reply: replyContext(for: row.message, in: byGUID),
                                      highlighted: highlightedID == row.id,
                                      actorName: { name(of: $0) }, replyAuthor: { author(of: $0) },
                                      onShowOriginal: { original in jump(to: original.presentationID, proxy: proxy) })
                    }
                    .id(row.id)
                    // Messages in a run from the same person sit close together; a new run gets the full gap.
                    .padding(.top, row.continuesRun ? -7 * zoom : 0)
                    // A row that just arrived at the tail settles in once; everything else is still.
                    .modifier(NewMessageEffect(animated: freshIDs.contains(row.id),
                                               incoming: !row.message.isFromMe, reduceMotion: reduceMotion))
                    // The row's place within the thread, reported as layout places it (not as it
                    // scrolls: the thread's own space does not move with the scroll).
                    .onGeometryChange(for: CGRect.self) { proxy in proxy.frame(in: .named("thread")) } action: { frame in
                        registry.update(row.id, frame)
                    }
                }
            }
            .coordinateSpace(name: "thread")
            .padding(16 * zoom)
            .background(MessageScrollSupport(scrollToBottomRequest: latestRequest, content: content, registry: registry) { near in
                if isNearBottom != near { isNearBottom = near }
            })
        }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom {
                Button { latestRequest += 1 } label: {
                    Label(conversation.unreadCount > 0 ? "\(conversation.unreadCount) new" : "Latest", systemImage: "arrow.down")
                        .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                }.buttonStyle(.plain).padding(12)
                .accessibilityLabel(conversation.unreadCount > 0 ? "\(conversation.unreadCount) new messages; go to the latest" : "Go to the latest message")
            }
        }
        .onAppear { if isNearBottom { onTailSeen() } }
        .onChange(of: isNearBottom) { _, near in if near { onTailSeen() } }
        .onChange(of: ids) { old, new in
            // Only rows appended at the tail animate: never the initial load (no change event),
            // an older page loading above, a reconnect or confirmation (same identities), a
            // removal, or a large burst.
            freshIDs = animateNew ? Self.freshTailIDs(old: old, new: new) : []
            if isNearBottom { onTailSeen() }
        }
    }

    /// What a reply answers: a message in the page, one above it, or nothing Mosaic can find.
    private func replyContext(for message: Message, in byGUID: [String: Message]) -> ReplyContext? {
        guard let target = message.replyToGUID else { return nil }
        if let loaded = byGUID[target] { return .loaded(loaded) }
        if let earlier = conversation.referencedMessages[target] { return .earlier(earlier) }
        return .missing
    }
    /// Goes to a reply's original and outlines it for a moment.
    private func jump(to id: String, proxy: ScrollViewProxy) {
        proxy.scrollTo(id, anchor: .center)
        highlightedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if highlightedID == id { highlightedID = nil } }
    }

    /// How many appended rows animate at once; a bigger batch arrives silently.
    static let animatedBatchLimit = 8
    /// The rows that were appended at the end — the old rows still end where they ended, and the
    /// new ones follow. Anything else (prepend, removal, replacement, a burst) returns nothing.
    static func freshTailIDs(old: [String], new: [String]) -> Set<String> {
        guard !old.isEmpty, new.count > old.count, new.count - old.count <= animatedBatchLimit else { return [] }
        let added = new.count - old.count
        guard Array(new.prefix(old.count)) == old else { return [] }
        return Set(new.suffix(added))
    }
}

/// A new message settles in once: an outgoing bubble rises a little as it fades in, an incoming
/// one settles down a touch. With Reduce Motion, only the fade. The offset is visual (it does not
/// change layout), so the scroll pinning underneath is untouched; the row's own state keeps a
/// confirmation (the same presentation identity) from pulsing again.
struct NewMessageEffect: ViewModifier {
    let animated: Bool
    let incoming: Bool
    let reduceMotion: Bool
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .opacity(animated && !settled ? 0 : 1)
            .offset(y: animated && !settled && !reduceMotion ? (incoming ? -5 : 9) : 0)
            .onAppear(perform: settle)
            .onChange(of: animated) { _, _ in settle() }
    }
    /// The row is laid out at its final place, hidden, and settles on the next turn — an explicit,
    /// one-time effect, not an animation tied to appearance (older rows appear all the time).
    private func settle() {
        guard animated, !settled else { return }
        DispatchQueue.main.async {
            guard !settled else { return }
            withAnimation(.easeOut(duration: incoming ? 0.16 : 0.2)) { settled = true }
        }
    }
}

/// One message with everything the list needs precomputed (day separators, runs of messages from
/// the same person, which rows show a time or a status), so the per-row work is done once per
/// conversation change rather than per render.
struct MessageRow: Identifiable, Equatable {
    /// Messages from the same person closer together than this form one run with one time stamp.
    static let runGap: TimeInterval = 15 * 60
    let message: Message
    let dayLabel: String?
    /// Part of a run started by the row above (same person, soon after).
    let continuesRun: Bool
    /// The last message of its run shows the time; a failed message always does.
    let showsTime: Bool
    /// The sender's name appears once, at the start of a run (groups only).
    let showsSender: Bool
    let showsStatus: Bool
    var id: String { message.presentationID }

    static func rows(for conversation: Conversation) -> [MessageRow] {
        let messages = conversation.messages
        let latestOutgoing = messages.last(where: \.isFromMe)?.presentationID
        var rows: [MessageRow] = []
        rows.reserveCapacity(messages.count)
        var previousDay: Int?
        for (index, message) in messages.enumerated() {
            let day = MessageText.dayOrdinal(message.date)
            let newDay = day != previousDay
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let continuesRun = !newDay && previous.map { sameRun($0, message) } ?? false
            let endsRun = next.map { !sameRun(message, $0) || MessageText.dayOrdinal($0.date) != day } ?? true
            rows.append(MessageRow(message: message, dayLabel: newDay ? MessageText.day(message.date) : nil,
                                   continuesRun: continuesRun, showsTime: endsRun || message.error != 0,
                                   showsSender: !continuesRun, showsStatus: message.presentationID == latestOutgoing))
            previousDay = day
        }
        return rows
    }
    /// Same side, same sender, and close in time.
    static func sameRun(_ first: Message, _ second: Message) -> Bool {
        first.kind == .message && second.kind == .message && !first.isUnsent && !second.isUnsent
            && first.isFromMe == second.isFromMe && first.sender == second.sender && second.date.timeIntervalSince(first.date) < runGap
    }
}

/// Formatted strings for bubbles, cached: `Date.formatted` and attributed-string construction are
/// the slow parts of drawing a conversation, and the same values are needed on every render.
enum MessageText {
    private static let calendar = Calendar.autoupdatingCurrent
    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
    private static let times = NSCache<NSNumber, NSString>()
    private static let days = NSCache<NSNumber, NSString>()
    private static let attributed: NSCache<NSString, AttributedBox> = { let c = NSCache<NSString, AttributedBox>(); c.countLimit = 4000; return c }()
    private final class AttributedBox { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }

    static func dayOrdinal(_ date: Date) -> Int { calendar.ordinality(of: .day, in: .era, for: date) ?? 0 }
    static func time(_ date: Date) -> String {
        let key = NSNumber(value: Int(date.timeIntervalSinceReferenceDate / 60))
        if let hit = times.object(forKey: key) { return hit as String }
        let value = timeFormatter.string(from: date)
        times.setObject(value as NSString, forKey: key)
        return value
    }
    static func day(_ date: Date) -> String {
        let key = NSNumber(value: dayOrdinal(date))
        if let hit = days.object(forKey: key) { return hit as String }
        let value = dayFormatter.string(from: date)
        days.setObject(value as NSString, forKey: key)
        return value
    }
    /// Message text with web links made clickable.
    static func attributed(_ text: String) -> AttributedString {
        if let hit = attributed.object(forKey: text as NSString) { return hit.value }
        var value = AttributedString(text)
        for match in LinkDetector.links(in: text) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].link = match.url
        }
        attributed.setObject(AttributedBox(value), forKey: text as NSString)
        return value
    }
}

struct MessageBubble: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.zoomScale) private var zoom
    let message: Message
    /// The conversation (or New Message tile) the message is shown in, for retrying a refused send.
    var threadID = ""
    let group: Bool
    let senderName: String?
    let live: Bool
    let service: String
    /// Delivery and read receipts appear under the most recent sent message only, as in Messages.
    var showsStatus = true
    /// The time appears under the last message of a run, not under every message.
    var showsTime = true
    /// Who wrote it, for lines like "Alex unsent a message".
    var authorName = ""
    var reactions: [ReactionSummary] = []
    var reply: ReplyContext? = nil
    /// The original of a reply that was just jumped to.
    var highlighted = false
    var actorName: (ReactionActor) -> String = { _ in "Someone" }
    var replyAuthor: (Message) -> String = { _ in "" }
    var onShowOriginal: (Message) -> Void = { _ in }

    var body: some View {
        if message.isUnsent {
            ThreadNote(text: message.isFromMe ? "You unsent a message." : "\(authorName) unsent a message.")
        } else if message.kind == .activity {
            ThreadNote(text: message.text)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        let fromMe = message.isFromMe
        let previewURL = LinkDetector.previewURL(in: message.text)
        let showsText = !message.text.isEmpty && !LinkDetector.isOnlyLink(message.text)
        return VStack(alignment: fromMe ? .trailing : .leading, spacing: 4 * zoom) {
            if group && !fromMe, let senderName {
                Text(senderName).font(.system(size: 9 * zoom, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 4 * zoom)
            }
            if let reply {
                ReplyExcerpt(context: reply, senderName: replyAuthor, onShowOriginal: onShowOriginal)
            }
            VStack(alignment: fromMe ? .trailing : .leading, spacing: 4 * zoom) {
            ForEach(message.attachments) { attachment in AttachmentView(attachment: attachment) }
            if showsText {
                // Plain Text, not selectable: on macOS a selectable Text is a full text view (it
                // supports mouse range selection), and three or four hundred of them made opening
                // or resizing tiles visibly slow. Copy is in the context menu instead.
                bubbleText.font(.system(size: 12 * zoom)).lineSpacing(2 * zoom)
                    .foregroundStyle(fromMe ? Color.white : Color.primary)
                    .tint(fromMe ? Color.white : Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12 * zoom).padding(.vertical, 8 * zoom)
                    .background(fromMe ? Palette.outgoing(service: service) : Palette.incoming,
                                in: RoundedRectangle(cornerRadius: 15 * zoom, style: .continuous))
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        ForEach(LinkDetector.links(in: message.text), id: \.range.location) { match in
                            Button("Open \(LinkPreviewLoader.host(match.url))") { NSWorkspace.shared.open(match.url) }
                        }
                        failedSendActions
                    }
            }
            if let previewURL { LinkPreviewCard(url: previewURL) }
            }
            // Room for the reactions above the content, reserved only when there are some, so a
            // badge never covers the message above.
            .padding(.top, reactions.isEmpty ? 0 : 12 * zoom)
            .overlay(alignment: fromMe ? .topLeading : .topTrailing) {
                if !reactions.isEmpty {
                    ReactionBadges(reactions: reactions, names: actorName).offset(x: (fromMe ? -10 : 10) * zoom)
                }
            }
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 18 * zoom, style: .continuous).fill(Palette.accent.opacity(0.16)).padding(-5 * zoom)
                }
            }
            if showsTime || message.isEdited || message.sendState != nil || (fromMe && showsStatus && (message.isRead || message.isDelivered)) {
                HStack(spacing: 4) {
                    Text(MessageText.time(message.date))
                    if message.isEdited { Text("· Edited") }
                    if fromMe {
                        switch message.sendState {
                        // Being handed to Messages, handed over, or refused: the database has not
                        // reported the message, so this is Mosaic's own state, never "Delivered".
                        case .sending: Text("· Sending…")
                        case .submitted: Text("· Sent")
                        case .failed:
                            Text("· Not Delivered").foregroundStyle(.red)
                            Button("Try Again") { Task { await store.retrySend(message.presentationID, in: threadID) } }
                                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                        case nil:
                            // A sent message shows only its time until Messages reports delivery.
                            if message.error != 0 { Text("· Failed").foregroundStyle(.red) }
                            else if showsStatus && message.isRead { Text("· Read") }
                            else if showsStatus && message.isDelivered { Text("· Delivered") }
                        }
                    }
                }.font(.system(size: 9 * zoom)).foregroundStyle(.tertiary).padding(.horizontal, 3 * zoom)
                .contextMenu { failedSendActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .padding(fromMe ? .leading : .trailing, 36 * zoom)
    }

    /// What can be done with a message Messages refused: send it as it was, take it back into the
    /// composer to change it, or remove it. Nothing is ever resent on its own.
    @ViewBuilder private var failedSendActions: some View {
        if case .failed(let reason)? = message.sendState {
            Divider()
            Text(reason)
            Button("Try Again") { Task { await store.retrySend(message.presentationID, in: threadID) } }
            Button(message.attachments.isEmpty ? "Edit Message" : "Put Back in Composer") { store.reclaimFailedSend(message.presentationID, in: threadID) }
            Button("Delete", role: .destructive) { store.discardFailedSend(message.presentationID, in: threadID) }
        }
    }

    /// Attributed (clickable links) only when the message has a link; plain text lays out faster.
    @ViewBuilder private var bubbleText: some View {
        if LinkDetector.links(in: message.text).isEmpty { Text(verbatim: message.text) }
        else { Text(MessageText.attributed(message.text)) }
    }
}
