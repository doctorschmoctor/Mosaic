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
                    MessageList(conversation: conversation, isLive: store.isLive, canLoadMore: false, senderNames: [:], onLoadMore: {})
                        .equatable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                MessageList(conversation: conversation, isLive: store.isLive,
                            canLoadMore: store.isLive && conversation.messages.count >= (store.historyLimits[conversation.id] ?? 100) && conversation.messages.count < 1000,
                            senderNames: senderNames, onLoadMore: { [store, id = conversation.id] in store.loadMore(id) })
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
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Photos, GIFs and files, as in Messages.
                AttachmentMenuButton(conversationName: conversation.name, tenorKey: store.tenorKey,
                    onFiles: { urls in store.attach(urls, to: conversation.id) },
                    onOpenSettings: { store.showSetup = true })
                    .frame(width: 31, height: 31).padding(.bottom, (ComposerEditor.minimumHeight - 31) / 2)
                VStack(spacing: 0) {
                    if let files = store.outgoing[conversation.id], !files.isEmpty {
                        // Pictures and files going out with the next message, above the text.
                        AttachmentStrip(files: files) { store.removeAttachment($0, from: conversation.id) }
                    }
                    ComposerEditor(text: store.draft(conversation.id), placeholder: placeholder, conversationID: conversation.id,
                        accessibilityLabel: "Message to \(conversation.name)",
                        focusRequest: store.focusTarget == conversation.id ? store.focusToken : 0,
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
    let onLoadMore: () -> Void
    @State private var isNearBottom = true
    @State private var latestRequest = 0

    static func == (lhs: MessageList, rhs: MessageList) -> Bool {
        lhs.conversation == rhs.conversation && lhs.isLive == rhs.isLive && lhs.canLoadMore == rhs.canLoadMore && lhs.senderNames == rhs.senderNames
    }

    var body: some View {
        let rows = MessageRow.rows(for: conversation)
        ScrollView {
            // A plain VStack: a lazy stack inserts and removes rows while a tile grows or shrinks,
            // which made rows jump.
            VStack(alignment: .leading, spacing: 10) {
                if canLoadMore {
                    Button("Load earlier messages", action: onLoadMore).font(.caption).frame(maxWidth: .infinity)
                }
                if conversation.messages.isEmpty {
                    Text(isLive ? "Loading this conversation…" : "Start the conversation.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
                ForEach(rows) { row in
                    VStack(spacing: 10) {
                        if let day = row.dayLabel {
                            Text(day).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        MessageBubble(message: row.message, group: conversation.isGroup,
                                      senderName: row.showsSender ? row.message.sender.map { senderNames[$0] ?? $0 } : nil,
                                      live: isLive, service: conversation.service,
                                      showsStatus: row.showsStatus, showsTime: row.showsTime)
                    }
                    // Messages in a run from the same person sit close together; a new run gets the full gap.
                    .padding(.top, row.continuesRun ? -7 : 0)
                }
            }
            .padding(16)
            .background(MessageScrollSupport(scrollToBottomRequest: latestRequest) { near in
                if isNearBottom != near { isNearBottom = near }
            })
        }
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom {
                Button { latestRequest += 1 } label: {
                    Label("Latest", systemImage: "arrow.down").font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                }.buttonStyle(.plain).padding(12)
            }
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
        first.isFromMe == second.isFromMe && first.sender == second.sender && second.date.timeIntervalSince(first.date) < runGap
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
    let message: Message
    let group: Bool
    let senderName: String?
    let live: Bool
    let service: String
    /// Delivery and read receipts appear under the most recent sent message only, as in Messages.
    var showsStatus = true
    /// The time appears under the last message of a run, not under every message.
    var showsTime = true

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
                // Plain Text, not selectable: on macOS a selectable Text is a full text view (it
                // supports mouse range selection), and three or four hundred of them made opening
                // or resizing tiles visibly slow. Copy is in the context menu instead.
                bubbleText.font(.system(size: 12)).lineSpacing(2)
                    .foregroundStyle(fromMe ? Color.white : Color.primary)
                    .tint(fromMe ? Color.white : Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(fromMe ? Palette.outgoing(service: service) : Palette.incoming,
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        ForEach(LinkDetector.links(in: message.text), id: \.range.location) { match in
                            Button("Open \(LinkPreviewLoader.host(match.url))") { NSWorkspace.shared.open(match.url) }
                        }
                    }
            }
            if let previewURL { LinkPreviewCard(url: previewURL) }
            if showsTime || (fromMe && showsStatus && (message.isRead || message.isDelivered)) {
                HStack(spacing: 4) {
                    Text(MessageText.time(message.date))
                    if fromMe {
                        // A sent message shows only its time until Messages reports delivery.
                        if message.error != 0 { Text("· Failed").foregroundStyle(.red) }
                        else if showsStatus && message.isRead { Text("· Read") }
                        else if showsStatus && message.isDelivered { Text("· Delivered") }
                    }
                }.font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .padding(fromMe ? .leading : .trailing, 36)
    }

    /// Attributed (clickable links) only when the message has a link; plain text lays out faster.
    @ViewBuilder private var bubbleText: some View {
        if LinkDetector.links(in: message.text).isEmpty { Text(verbatim: message.text) }
        else { Text(MessageText.attributed(message.text)) }
    }
}
