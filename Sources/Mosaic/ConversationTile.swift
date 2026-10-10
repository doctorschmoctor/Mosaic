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
    /// Find in Conversation (⌥⌘F): whether the bar is open, what it looks for (as typed, and as
    /// the thread highlights it a moment later), and the match shown.
    @State private var finding = false
    @State private var findText = ""
    @State private var findQuery = ""
    @State private var findCurrent: String?
    @State private var findFocusToken = 0
    /// The details panel (⌘I) in place of the thread, and a message just shown from it.
    @State private var showingDetails = false
    @State private var revealedID: String?
    private var isFocused: Bool { store.focusedID == conversation.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if finding && !conversation.isComposeDraft {
                let matches = FindInConversation.matches(findQuery, in: conversation.messages)
                FindBar(text: $findText, matchCount: matches.count,
                        position: findCurrent.flatMap { current in matches.firstIndex(of: current).map { matches.count - $0 } },
                        searching: !findQuery.isEmpty,
                        onOlder: { step(older: true, in: matches) }, onNewer: { step(older: false, in: matches) }, onClose: endFind,
                        focusToken: findFocusToken)
                // Beyond what is loaded: a search of the older history, part by part, on request.
                if store.isLive, !findQuery.isEmpty {
                    OlderHistorySearchView(conversationID: conversation.id, query: findQuery,
                                           senderName: { handle in handle.map { senderNames[$0] ?? (conversation.isGroup ? Recipient.display($0) : conversation.name) } ?? conversation.name }) { messageID in
                        findCurrent = messageID
                        // Loaded already: the match is shown where it is; else the messages around it.
                        if conversation.messages.contains(where: { $0.id == messageID }) { store.leaveContext(conversation.id) }
                        else { Task { await store.showInContext(conversation.id, messageID: messageID) } }
                    }
                }
                Divider().opacity(0.6)
            }
            if let context = store.contextWindows[conversation.id], !conversation.isComposeDraft {
                ContextBanner(date: context.page.messages.first { $0.id == context.anchorID }?.date) { store.leaveContext(conversation.id) }
                Divider().opacity(0.6)
            }
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
            } else if showingDetails {
                ConversationDetailsPanel(conversation: conversation, hasOlderHistory: hasOlderHistory,
                                         onShowMessage: { id in reveal(id) }, onClose: { showingDetails = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let context = store.contextWindows[conversation.id] {
                // Older messages around a search result. Nothing here counts as read (it is not
                // the newest messages); the conversation keeps updating behind it.
                MessageList(conversation: contextConversation(context), isLive: store.isLive, canLoadMore: false,
                            senderNames: senderNames, zoom: zoom, animateNew: false,
                            findQuery: finding ? findQuery : "", findCurrent: findCurrent ?? context.anchorID,
                            showsLatestButton: false, onLoadMore: {})
                    .equatable()
                    .id("context-\(context.anchorID)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded { store.requestComposerFocus(conversation.id) })
            } else {
                MessageList(conversation: conversation, isLive: store.isLive,
                            canLoadMore: store.isLive && conversation.messages.count >= (store.historyLimits[conversation.id] ?? 100) && conversation.messages.count < 1000,
                            isLoadingMore: store.loadingMore.contains(conversation.id),
                            senderNames: senderNames, zoom: zoom, animateNew: store.animateMessages,
                            seenBoundary: store.seenBoundary(conversation.id),
                            findQuery: finding ? findQuery : "", findCurrent: finding ? findCurrent : revealedID,
                            historyCeiling: store.isLive && conversation.messages.count >= WorkspaceStore.maximumHistory,
                            onSearchOlder: { openFind() },
                            onLoadMore: { [store, id = conversation.id] in store.loadMore(id) },
                            onTailSeen: { [store, id = conversation.id] in store.tailSeen(id) },
                            onTailLeft: { [store, id = conversation.id] in store.tailLeft(id) })
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
        // The resting shadow comes from the tile's shape alone, so it costs nothing to move.
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.surface)
                .shadow(color: .black.opacity(0.025), radius: 5, y: 2)
        }
        // ⌥⌘F in this tile opens its find bar; ⌘G / ⇧⌘G step through the matches.
        .onReceive(NotificationCenter.default.publisher(for: .findInConversation)) { note in
            guard note.object as? String == conversation.id, !conversation.isComposeDraft else { return }
            if finding { findFocusToken += 1 } else { finding = true }
            store.findOpened(conversation.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showConversationDetails)) { note in
            guard note.object as? String == conversation.id, !conversation.isComposeDraft else { return }
            showingDetails.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .findNextInConversation)) { note in
            guard finding, let info = note.object as? FindStep, info.conversationID == conversation.id else { return }
            step(older: info.older, in: FindInConversation.matches(findQuery, in: conversation.messages))
        }
        // The highlight follows the typing a moment later, so a long thread is not redrawn per key.
        .task(id: findText) {
            guard finding else { return }
            if !findText.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            findQuery = findText
            // The newest match first.
            findCurrent = FindInConversation.matches(findText, in: conversation.messages).last
        }
        // A message edited or unsent away from the query: the current match moves to one that still matches.
        .onChange(of: conversation.messages) { _, messages in
            guard finding, let current = findCurrent else { return }
            let matches = FindInConversation.matches(findQuery, in: messages)
            if !matches.contains(current) { findCurrent = matches.last }
        }
        .onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value else { return }
                Task { @MainActor in
                    // Accept only known conversation IDs, never external text as a recipient.
                    guard store.conversations.contains(where: { $0.id == value }) else { return }
                    store.openAndType(value); store.reorder(value, before: conversation.id)
                }
            }
            return true
        }
    }

    /// Moves to the next older (or newer) match, wrapping around.
    private func step(older: Bool, in matches: [String]) {
        guard !matches.isEmpty else { return }
        guard let current = findCurrent, let index = matches.firstIndex(of: current) else { findCurrent = matches.last; return }
        findCurrent = matches[(index + (older ? matches.count - 1 : 1)) % matches.count]
    }
    /// Whether there is history before the loaded messages (more to scroll back to, or past the ceiling).
    private var hasOlderHistory: Bool {
        store.isLive && conversation.messages.count >= (store.historyLimits[conversation.id] ?? WorkspaceStore.pageSize)
    }
    /// Closes the details and shows a message where it was sent, outlined for a moment.
    private func reveal(_ id: String) {
        showingDetails = false
        store.leaveContext(conversation.id)
        revealedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if revealedID == id { revealedID = nil } }
    }
    /// Opens the find bar (the ceiling note's Search Older Messages).
    private func openFind() {
        if finding { findFocusToken += 1 } else { finding = true }
        store.findOpened(conversation.id)
    }
    /// The conversation as the window around a search result shows it.
    private func contextConversation(_ context: HistoryContext) -> Conversation {
        var shown = conversation
        shown.messages = context.page.messages
        shown.reactions = context.page.reactions
        shown.referencedMessages = context.page.referencedMessages
        shown.unreadCount = 0
        return shown
    }
    /// Closes the find bar; the keyboard goes back to this tile's message field.
    private func endFind() {
        finding = false; findText = ""; findQuery = ""; findCurrent = nil
        store.findClosed(conversation.id)
        store.cancelOlderSearch(conversation.id)
        store.leaveContext(conversation.id)
        store.requestComposerFocus(conversation.id)
    }

    private var senderNames: [String: String] {
        guard conversation.isGroup else { return [:] }
        return Dictionary(conversation.participants.map { ($0, store.name(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    private var header: some View {
        HStack(spacing: 9) {
            if conversation.isComposeDraft {
                NewMessageAvatar(size: 30)
            } else {
                Avatar(conversation: conversation, size: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conversation.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if store.needsReply(conversation.id) {
                        Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Palette.needsReply)
                            .help("Needs Reply — clear it from this header's menu or the sidebar")
                            .accessibilityLabel("Needs reply")
                    }
                    if store.isProtected(conversation.id) {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            .help("Protected: never replaced to make room for another conversation")
                            .accessibilityLabel("Protected from replacement")
                    }
                    // A new message came in while you were in another tile.
                    if store.tilesWithNews.contains(conversation.id) {
                        Circle().fill(Palette.accent).frame(width: 7, height: 7)
                            .accessibilityLabel("New message")
                            .help("New message — Tab or click to go to this conversation")
                    }
                }
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
            onCloseHover: { hovered in if closeHovered != hovered { closeHovered = hovered } },
            menuItems: headerMenu))
        .help(onDragChanged == nil ? "" : "Drag to move this tile")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(conversation.name + (store.isProtected(conversation.id) ? ", protected from replacement" : ""))
    }

    /// The header's menu (right-click): this tile's actions.
    private var headerMenu: [TileHeaderHandle.MenuItem] {
        let id = conversation.id
        let protected = store.isProtected(id)
        var items: [TileHeaderHandle.MenuItem] = []
        if !conversation.isComposeDraft {
            items.append(.init(title: "Conversation Details", action: { NotificationCenter.default.post(name: .showConversationDetails, object: id) }))
        }
        return items + [
            // Keeps this tile open when another conversation needs room (unlike a sidebar pin, which only orders the list).
            .init(title: protected ? "Allow Replacement" : "Protect from Replacement", action: { [store] in store.toggleProtection(id) }),
            .init(title: store.needsReply(id) ? "Clear Needs Reply" : "Mark as Needs Reply",
                  isEnabled: { [store] in store.conversations.contains { $0.id == id } }) { [store] in store.toggleNeedsReply(id) },
            .init(title: conversation.isComposeDraft ? "Discard New Message" : "Discard Draft",
                  isEnabled: { [store] in store.composeDrafts[id] != nil || store.hasDraft(id) }) { [store] in store.discardDraft(id) },
            .init(title: "Close Tile", action: { [store] in store.close(id) }, separatedAbove: true),
        ]
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
                    onPickPhotos: { identifiers in store.importPhotos(identifiers, to: conversation.id) },
                    onFinish: { store.requestComposerFocus(conversation.id) })
                    .frame(width: 31, height: 31).padding(.bottom, (ComposerEditor.barHeight - 31) / 2)
                VStack(spacing: 0) {
                    if let files = store.outgoing[conversation.id], !files.isEmpty {
                        // Pictures and files going out with the next message, above the text.
                        AttachmentStrip(files: files, onRemove: { store.removeAttachment($0, from: conversation.id) },
                                        onRetry: { store.retryImport($0, in: conversation.id) },
                                        onPreview: { store.previewOutgoing($0, in: conversation.id) })
                    }
                    ComposerEditor(text: store.draft(conversation.id), placeholder: placeholder, conversationID: conversation.id,
                        accessibilityLabel: "Message to \(conversation.name)",
                        focus: store.composerFocus,
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
                emojiButton.padding(.bottom, (ComposerEditor.barHeight - 31) / 2)
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
    /// Earlier messages are on their way (the spinner at the top shows).
    var isLoadingMore = false
    let senderNames: [String: String]
    /// The shared conversation zoom: fonts, bubbles and media scale; the tile around them does not.
    var zoom: CGFloat = 1
    /// Whether a newly arrived or sent message settles in with a short effect (Settings).
    var animateNew = true
    /// The newest row the reader has seen; incoming messages after it are new.
    var seenBoundary: Int64? = nil
    /// Find in Conversation: the words highlighted in the loaded messages, and the match shown
    /// (scrolled to and outlined).
    var findQuery = ""
    var findCurrent: String? = nil
    /// The "Latest" button while reading above the newest message (not in a window into older history).
    var showsLatestButton = true
    /// The tile shows as many messages as it can (1,000): a note at the top says older ones exist.
    var historyCeiling = false
    var onSearchOlder: () -> Void = {}
    let onLoadMore: () -> Void
    /// The newest message is in view (the store marks it seen once the reader can see the tile),
    /// and when it no longer is.
    var onTailSeen: () -> Void = {}
    var onTailLeft: () -> Void = {}
    @State private var isNearBottom = true
    /// A reply's original that was just jumped to, outlined for a moment.
    @State private var highlightedID: String?
    @State private var latestRequest = 0
    /// Where each row sits in the content, for the scroll anchor; a class, so rows reporting
    /// their frames cost no view invalidation.
    @State private var registry = ThreadRowRegistry()
    /// The rows that just arrived at the tail and settle in once.
    @State private var freshIDs: Set<String> = []
    /// Rows, reactions and lookups derived from the conversation, kept between renders (a class,
    /// so refreshing it costs no invalidation). Scrolling, highlights and resizes reuse them.
    @State private var presentation = ThreadPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: MessageList, rhs: MessageList) -> Bool {
        lhs.conversation == rhs.conversation && lhs.isLive == rhs.isLive && lhs.canLoadMore == rhs.canLoadMore
            && lhs.isLoadingMore == rhs.isLoadingMore
            && lhs.senderNames == rhs.senderNames && lhs.zoom == rhs.zoom && lhs.animateNew == rhs.animateNew
            && lhs.seenBoundary == rhs.seenBoundary && lhs.findQuery == rhs.findQuery && lhs.findCurrent == rhs.findCurrent
            && lhs.historyCeiling == rhs.historyCeiling
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
        let prepared = presentation.prepared(for: conversation)
        let rows = prepared.rows
        let content = ThreadContent(first: rows.first?.id, last: rows.last?.id, count: rows.count)
        let ids = prepared.ids
        let reactions = prepared.reactions
        let byGUID = prepared.byGUID
        // The New Messages line only while reading above them; at the tail everything is being seen.
        let firstUnread = isNearBottom ? nil : Self.firstUnread(in: rows, after: seenBoundary)
        let attachmentFiles = prepared.attachmentFiles
        ScrollViewReader { proxy in
        ScrollView {
            // A plain VStack: a lazy stack inserts and removes rows while a tile grows or shrinks,
            // which made rows jump.
            VStack(alignment: .leading, spacing: 10 * zoom) {
                // Earlier messages load by themselves as the reader nears the top; a small spinner
                // shows while they come.
                if historyCeiling {
                    // Not the start of the conversation: the most a tile shows.
                    VStack(spacing: 4) {
                        Text("Showing the newest \(WorkspaceStore.maximumHistory.formatted()) messages. Older ones are still on this Mac.")
                            .font(.system(size: 10 * zoom)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Search Older Messages", action: onSearchOlder).buttonStyle(.borderless).font(.system(size: 10 * zoom, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                if canLoadMore && isLoadingMore {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 4)
                        .accessibilityLabel("Loading earlier messages")
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
                                      highlighted: highlightedID == row.id || findCurrent == row.id,
                                      findQuery: findQuery,
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
            .environment(\.threadAttachments, attachmentFiles)
            .background(MessageScrollSupport(scrollToBottomRequest: latestRequest, content: content, registry: registry,
                                             onNearTop: canLoadMore ? onLoadMore : nil) { near in
                if isNearBottom != near { isNearBottom = near }
            })
        }
        // The find bar's current match is brought to the middle of the tile (also when the
        // thread first appears around one).
        .onChange(of: findCurrent) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        .onAppear { if let id = findCurrent { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } } }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom && showsLatestButton {
                Button { latestRequest += 1 } label: {
                    Label(conversation.unreadCount > 0 ? "\(conversation.unreadCount) new" : "Latest", systemImage: "arrow.down")
                        .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                }.buttonStyle(.plain).padding(12)
                .accessibilityLabel(conversation.unreadCount > 0 ? "\(conversation.unreadCount) new messages; go to the latest" : "Go to the latest message")
            }
        }
        .onAppear { if isNearBottom { onTailSeen() } }
        .onDisappear { onTailLeft() }
        .onChange(of: isNearBottom) { _, near in if near { onTailSeen() } else { onTailLeft() } }
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

/// A thread's presentation, rebuilt only when something it is made from changes: the messages
/// (text, edits, receipts), the reactions, or the clock's time zone and locale (day separators and
/// times are formatted with them). A render caused by scrolling, a highlight or a resize reuses it.
@MainActor final class ThreadPresentation {
    struct Prepared {
        let rows: [MessageRow]
        let ids: [String]
        let reactions: [String: [ReactionSummary]]
        let byGUID: [String: Message]
        let attachmentFiles: [URL]
    }
    private struct Inputs: Equatable {
        let messages: [Message]
        let reactions: [ReactionEvent]
        let clock: MessageText.Environment
    }
    private var inputs: Inputs?
    private var cached: Prepared?
    /// How many times the rows were built (tests).
    private(set) var buildCount = 0

    func prepared(for conversation: Conversation) -> Prepared {
        let clock = MessageText.currentEnvironment()
        let now = Inputs(messages: conversation.messages, reactions: conversation.reactions, clock: clock)
        if let cached, now == inputs { return cached }
        buildCount += 1
        let rows = MessageRow.rows(for: conversation)
        let prepared = Prepared(rows: rows, ids: rows.map(\.id), reactions: Reactions.reduce(conversation.reactions),
            byGUID: Dictionary(conversation.messages.compactMap { message in message.guid.map { ($0, message) } }, uniquingKeysWith: { first, _ in first }),
            attachmentFiles: conversation.messages.flatMap(\.attachments).compactMap { $0.path.map(URL.init(fileURLWithPath:)) })
        inputs = now
        cached = prepared
        return prepared
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

    /// The time zone and locale strings are formatted for. When either changes (travel, a new
    /// region setting) the formatters follow and cached strings are dropped.
    struct Environment: Equatable { let timeZone: String; let locale: String }
    private static var formattedFor: Environment?
    static func currentEnvironment() -> Environment {
        let now = Environment(timeZone: TimeZone.current.identifier, locale: Locale.current.identifier)
        if now != formattedFor {
            if formattedFor != nil {
                timeFormatter.timeZone = .current; timeFormatter.locale = .current
                dayFormatter.timeZone = .current; dayFormatter.locale = .current
                times.removeAllObjects(); days.removeAllObjects()
            }
            formattedFor = now
        }
        return now
    }

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
    /// Message text with every occurrence of `query` marked, as Find highlights it (links kept).
    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var value = attributed(text)
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: FindInConversation.options, range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: value),
               let upper = AttributedString.Index(found.upperBound, within: value) {
                value[lower..<upper].backgroundColor = Color(nsColor: .findHighlightColor)
                value[lower..<upper].foregroundColor = .black
            }
            searchRange = found.upperBound..<text.endIndex
        }
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
    /// The original of a reply that was just jumped to, or the find bar's current match.
    var highlighted = false
    /// Words to mark in the text (Find in Conversation).
    var findQuery = ""
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
        if !findQuery.isEmpty, FindInConversation.contains(message.text, findQuery) {
            Text(MessageText.highlighted(message.text, findQuery))
        } else if LinkDetector.links(in: message.text).isEmpty { Text(verbatim: message.text) }
        else { Text(MessageText.attributed(message.text)) }
    }
}

/// Matching for Find in Conversation: the loaded messages whose text contains the words, ignoring
/// case and accents. Unsent messages have no words to match, and activity lines are not messages.
enum FindInConversation {
    static let options = TextSearch.options
    static func contains(_ text: String, _ query: String) -> Bool { TextSearch.contains(text, query) }
    /// The matching messages' presentation ids, oldest first.
    static func matches(_ query: String, in messages: [Message]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return messages.filter { $0.kind == .message && !$0.isUnsent && contains($0.text, query) }.map(\.presentationID)
    }
}

/// Which way the find bar steps (⌘G older, ⇧⌘G newer), for one tile.
struct FindStep {
    let conversationID: String
    let older: Bool
}

extension Notification.Name {
    /// Opens (or focuses) the find bar of the tile whose id is the object.
    static let findInConversation = Notification.Name("Mosaic.findInConversation")
    /// Steps through a tile's matches; the object is a `FindStep`.
    static let findNextInConversation = Notification.Name("Mosaic.findNextInConversation")
}

/// A tile's find bar: the words to look for in its loaded messages, how many match and which one
/// is shown, and buttons to the older and newer match. Return (or ↑) goes to the older match,
/// Shift–Return (or ↓) to the newer one, and Esc closes the bar. It searches the messages
/// loaded in the tile — the scope the placeholder names.
struct FindBar: View {
    @Binding var text: String
    let matchCount: Int
    /// Which match is shown, counted from the newest (1).
    let position: Int?
    /// Whether there are words to look for (so "No matches" can be said).
    let searching: Bool
    let onOlder: () -> Void
    let onNewer: () -> Void
    let onClose: () -> Void
    /// Changes when ⌥⌘F asks for the field again while the bar is open.
    var focusToken = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            RecipientTextField(text: $text, takesFocus: true, placeholder: "Find in loaded messages", focusToken: focusToken) { command in
                switch command {
                case .submit:
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onNewer() } else { onOlder() }
                    return true
                case .moveUp: onOlder(); return true
                case .moveDown: onNewer(); return true
                case .cancel: onClose(); return true
                case .deleteBackwardWhenEmpty: return false
                }
            }
            .frame(height: 22)
            .accessibilityLabel("Find in loaded messages")
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                .accessibilityLabel(status)
            Button(action: onOlder) { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                .disabled(matchCount == 0).help("Older match (Return or ⌘G)").accessibilityLabel("Older match")
            Button(action: onNewer) { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                .disabled(matchCount == 0).help("Newer match (Shift–Return or ⇧⌘G)").accessibilityLabel("Newer match")
            Button("Done", action: onClose).buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.primary.opacity(0.035))
    }

    private var status: String {
        guard searching else { return "Loaded messages" }
        guard matchCount > 0 else { return "No matches" }
        return position.map { "\($0) of \(matchCount)" } ?? "\(matchCount) found"
    }
}

/// Above a window into older history: when it is from, and the way back to the newest messages.
struct ContextBanner: View {
    let date: Date?
    let onBack: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(date.map { "Older messages around \(MessageText.day($0))" } ?? "Older messages")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button("Back to Latest", action: onBack).buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Palette.accent.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}

/// Searching a tile's history older than what it has loaded, for the find bar's words: a button
/// to start, the matches as they are found (date, who, the line), and a way to go further. Each
/// part reads a bounded number of older messages; their words — plain and rich text — are
/// matched on this Mac, and nothing is indexed or kept.
struct OlderHistorySearchView: View {
    @Environment(WorkspaceStore.self) private var store
    let conversationID: String
    let query: String
    let senderName: (String?) -> String
    let onChoose: (String) -> Void

    var body: some View {
        let search = store.historySearches[conversationID].flatMap { $0.query == query ? $0 : nil }
        VStack(alignment: .leading, spacing: 4) {
            if let search {
                if !search.matches.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(search.matches) { match in row(match) }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                HStack(spacing: 6) {
                    if search.isSearching {
                        ProgressView().controlSize(.small)
                        Text("Searching older messages…")
                        Spacer(minLength: 4)
                        Button("Stop") { store.cancelOlderSearch(conversationID) }.buttonStyle(.borderless)
                    } else {
                        Text(summary(search)).lineLimit(1)
                        Spacer(minLength: 4)
                        if search.next != nil {
                            Button("Search Further") { store.continueOlderSearch(conversationID) }.buttonStyle(.borderless)
                                .help("Look through the next \(WorkspaceStore.searchScanLimit) older messages")
                        }
                    }
                }
            } else {
                Button { store.searchOlderHistory(conversationID, query: query) } label: {
                    Label("Search older messages for “\(query)”", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Looks through this conversation's older messages on this Mac, \(WorkspaceStore.searchScanLimit) at a time: their words, plain or rich text — not attachments or earlier versions of edited messages")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func summary(_ search: HistorySearch) -> String {
        if search.failed { return "Couldn't search older messages right now." }
        let found = search.matches.isEmpty ? "No older matches" : search.matches.count == 1 ? "1 older match" : "\(search.matches.count) older matches"
        let scope = search.next == nil ? "searched back to the first message" : "in the \(search.scanned) messages before these"
        return "\(found) · \(scope)"
    }

    private func row(_ match: Message) -> some View {
        Button { onChoose(match.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MessageText.day(match.date)).monospacedDigit().frame(width: 84, alignment: .leading)
                Text(match.isFromMe ? "You" : senderName(match.sender)).fontWeight(.medium).foregroundStyle(.primary).lineLimit(1)
                    .frame(maxWidth: 90, alignment: .leading)
                Text(MessageText.highlighted(MessageExcerpt.of(match), query)).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(match.isFromMe ? "You" : senderName(match.sender)), \(MessageText.day(match.date)): \(MessageExcerpt.of(match))")
    }
}
