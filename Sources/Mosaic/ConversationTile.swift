import SwiftUI
import QuartzCore
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

struct ConversationTile: View, Equatable {
    @Environment(WorkspaceStore.self) private var store
    let conversation: Conversation
    var onDragChanged: ((CGSize) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    /// Two tiles draw the same when they show the same conversation and both can be moved or
    /// neither can. The drag callbacks are left out: the workspace makes them afresh each time it
    /// lays out, so they always differ, yet they do the same thing (they ask the store, which knows
    /// the current layout). Comparing them redrew every tile whenever any tile moved.
    static func == (lhs: ConversationTile, rhs: ConversationTile) -> Bool {
        lhs.conversation == rhs.conversation && (lhs.onDragChanged == nil) == (rhs.onDragChanged == nil)
    }
    @State private var isDropTarget = false
    @State private var composerHeight = ComposerEditor.minimumHeight
    @Environment(\.zoomScale) private var zoom
    @State private var closeHovered = false
    /// Find in Conversation (⌥⌘F): whether the bar is open, what it looks for (a moment after
    /// typing stops — the typing itself stays in the bar), and the match shown.
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findCurrent: String?
    @State private var findFocusToken = 0
    /// The loaded messages' matches, worked out once per query and history (not per render).
    @State private var findIndex = FindIndex()
    /// The details panel (⌘I) in place of the thread, and a message just shown from it.
    @State private var showingDetails = false
    @State private var revealedID: String?
    private var isFocused: Bool { store.focusedID == conversation.id }

    var body: some View {
        let _ = TileTrace.note("tile body")
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if finding && !conversation.isComposeDraft {
                let matches = findMatches
                FindBar(matchCount: matches.count,
                        position: findCurrent.flatMap { matches.firstIndex(of: $0).map { $0 + 1 } },
                        searching: !findWords.isEmpty, searchingOlder: isSearchingOlder,
                        onQuery: { setFindQuery($0) },
                        onOlder: { step(older: true) }, onNewer: { step(older: false) }, onClose: endFind,
                        focusToken: findFocusToken)
                // Beyond what is loaded: the older history, searched by itself as the words settle.
                if store.isLive, findWords.count >= WorkspaceStore.historySearchMinimumLength {
                    OlderHistorySearchView(conversationID: conversation.id, query: findWords,
                                           senderName: { handle in handle.map { senderNames[$0] ?? (conversation.isGroup ? Recipient.display($0) : conversation.name) } ?? conversation.name },
                                           onChoose: { chooseMatch($0) })
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
                ConversationDetailsPanel(conversation: conversation,
                                         onShowMessage: { id in reveal(id) }, onClose: { closeDetails() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let context = store.contextWindows[conversation.id] {
                // Older messages around a search result. Nothing here counts as read (it is not
                // the newest messages); the conversation keeps updating behind it.
                MessageList(conversation: contextConversation(context), isLive: store.isLive, canLoadMore: false,
                            senderNames: senderNames, zoom: zoom, animateNew: false,
                            findQuery: finding ? findQuery : "", findCurrent: findCurrent ?? context.anchorID,
                            showsLatestButton: false, startsAt: context.anchorID, onLoadMore: {})
                    .equatable()
                    .id("context-\(context.anchorID)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded { store.requestComposerFocus(conversation.id) })
            } else {
                TileThread(conversation: conversation, senderNames: senderNames, zoom: zoom,
                           findQuery: finding ? findQuery : "", findCurrent: finding ? findCurrent : revealedID,
                           onSearchOlder: { openFind() })
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
            if showingDetails { closeDetails() } else { showingDetails = true; store.detailsOpened(conversation.id) }
        }
        // Esc while the details are open (KeyboardRouter): back to the thread.
        .onReceive(NotificationCenter.default.publisher(for: .closeConversationDetails)) { note in
            guard note.object as? String == conversation.id, showingDetails else { return }
            closeDetails()
        }
        .onReceive(NotificationCenter.default.publisher(for: .findNextInConversation)) { note in
            guard finding, let info = note.object as? FindStep, info.conversationID == conversation.id else { return }
            step(older: info.older)
        }
        // The older history is searched by itself once the words have settled a moment longer
        // (a new word supersedes it; closing the bar stops it).
        .task(id: finding ? findWords : nil) {
            guard finding, store.isLive, !conversation.isComposeDraft else { return }
            guard findWords.count >= WorkspaceStore.historySearchMinimumLength else { store.cancelOlderSearch(conversation.id); return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            store.searchOlderHistory(conversation.id, query: findWords)
        }
        // A loaded message edited or unsent away from the query: the current match moves to one that still matches.
        .onChange(of: conversation.messages) { _, messages in
            guard finding, let current = findCurrent, messages.contains(where: { $0.presentationID == current }) else { return }
            let loaded = findIndex.matches(findQuery, in: messages)
            if !loaded.contains(current) { findCurrent = loaded.last }
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

    /// The find bar's words, trimmed.
    private var findWords: String { findQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Every match, newest first: the loaded messages', then the older history's as its search
    /// finds them (a message that has since been loaded counts once).
    private var findMatches: [String] {
        let loaded = findIndex.matches(findQuery, in: conversation.messages)
        guard let search = store.historySearches[conversation.id], search.query == findWords, !search.matches.isEmpty else { return loaded.reversed() }
        let loadedRows = findIndex.rowIDs(of: conversation.messages)
        return loaded.reversed() + search.matches.map(\.id).filter { !loadedRows.contains($0) }
    }
    private var isSearchingOlder: Bool {
        store.historySearches[conversation.id].map { $0.query == findWords && $0.isSearching } ?? false
    }
    /// New words from the find bar: the thread marks them, the newest loaded match is shown, and
    /// a window into older history from the last words closes.
    private func setFindQuery(_ query: String) {
        guard query != findQuery else { return }
        findQuery = query
        findCurrent = findIndex.matches(query, in: conversation.messages).last
        store.leaveContext(conversation.id)
    }
    /// Moves to the next older (or newer) match — from the loaded messages on into the older
    /// history — wrapping around once the whole history has been searched.
    private func step(older: Bool) {
        let matches = findMatches
        guard !matches.isEmpty else { NSSound.beep(); return }
        guard let current = findCurrent, let index = matches.firstIndex(of: current) else { show(matches[0]); return }
        var next = index + (older ? 1 : -1)
        if next >= matches.count {
            // More may still be found further back.
            if isSearchingOlder { NSSound.beep(); return }
            next = 0
        }
        if next < 0 { next = matches.count - 1 }
        show(matches[next])
    }
    /// A match chosen from the older matches' list: the find bar closes and the tile shows that
    /// message, outlined, among the messages around it (or where it is, if it is loaded).
    private func chooseMatch(_ id: String) {
        finding = false; findQuery = ""; findCurrent = nil
        store.findClosed(conversation.id)
        store.cancelOlderSearch(conversation.id)
        reveal(id)
        store.requestComposerFocus(conversation.id)
    }
    /// Shows a match: where it is among the loaded messages, or else the messages around it.
    private func show(_ id: String) {
        findCurrent = id
        if conversation.messages.contains(where: { $0.presentationID == id || $0.id == id }) { store.leaveContext(conversation.id) }
        else { Task { await store.showInContext(conversation.id, messageID: id) } }
    }
    /// Closes the details and shows a message where it was sent, outlined for a moment.
    /// Back from the details to the thread, with the keyboard in the message field.
    private func closeDetails() {
        showingDetails = false
        store.detailsClosed(conversation.id)
        store.requestComposerFocus(conversation.id)
    }
    private func reveal(_ id: String) {
        if showingDetails { showingDetails = false; store.detailsClosed(conversation.id) }
        // From further back than the tile has loaded: the messages around it.
        guard conversation.messages.contains(where: { $0.id == id || $0.presentationID == id }) else {
            Task { await store.showInContext(conversation.id, messageID: id) }
            return
        }
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
        finding = false; findQuery = ""; findCurrent = nil
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
            onPress: { [store, id = conversation.id] in store.prepareTileDrag(id) },
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
        // Keeps this tile open when another conversation needs room (unlike a sidebar pin, which only orders the list).
        items.append(.init(title: protected ? "Allow Replacement" : "Protect from Replacement", action: { [store] in store.toggleProtection(id) }))
        // Mosaic's own notifications for this conversation (Messages is not changed).
        if store.notificationsEnabled && !conversation.isComposeDraft {
            if store.isMuted(id) {
                items.append(.init(title: "Unmute Notifications", action: { [store] in store.unmute(id) }))
            } else {
                items.append(.init(title: "Mute Notifications", action: { [store] in store.mute(id, .untilUnmuted) }))
            }
        }
        return items + [
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
                        // The reader is in this tile while its field has the keyboard: what it
                        // shows of its newest messages is read (`WorkspaceStore.canRead`).
                        onFocus: { store.composerTookKeyboard(conversation.id) },
                        onBlur: { store.composerLostKeyboard(conversation.id) },
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

/// The thread's rows one under another, leading-aligned (as a VStack lays them out), telling the
/// row registry where it put each one. The registry used to hear from every row through a
/// geometry observer, and SwiftUI asks every such observer again on each scroll step (the rows'
/// place in the window changes, even though their place in the thread does not): a thread of a
/// few hundred rows spent most of each scroll step there. Layout runs only when the content or
/// the tile's size changes.
struct ThreadStack: Layout {
    var spacing: CGFloat
    /// Room is kept above the rows (`ThreadPresentation.keepsRoomAbove`): older rows laid out come
    /// into it, and nothing already laid out moves.
    var roomAbove = false
    let registry: ThreadRowRegistry
    /// How much room is kept above the rows, each time it is made.
    static let room: CGFloat = 12_000

    /// Where the first row goes. With room kept above the rows, the topmost row that was laid out
    /// in the last pass stays where it was: rows added above it take room that was there, rows
    /// added below make the thread taller at its end, rows left out above leave room behind — so
    /// the scroll view never needs putting back in place for them (each time it did, the whole
    /// window was laid out twice more) and its scroller does not jump. When the room runs out, it
    /// is made again (everything moves down once). Without room, the rows start at the top.
    private func top(_ sizes: [CGSize], _ subviews: Subviews) -> CGFloat {
        guard roomAbove, ThreadRenderingProbe.rowGeometry else { return 0 }
        var above: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            if let id = subview[ThreadRowID.self], let frame = registry.frames[id] {
                let top = frame.minY - above
                return top >= 0 ? top : Self.room
            }
            above += sizes[index].height + spacing
        }
        return Self.room
    }
    private static func total(_ sizes: [CGSize], spacing: CGFloat) -> CGFloat {
        sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, sizes.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let started = CACurrentMediaTime()
        let rowProposal = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(rowProposal) }
        let width = sizes.map(\.width).max() ?? 0
        let height = top(sizes, subviews) + Self.total(sizes, spacing: spacing)
        TileTrace.note("thread stack sized \(subviews.count) rows in \(String(format: "%.1f", (CACurrentMediaTime() - started) * 1000)) ms")
        return CGSize(width: proposal.width ?? width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let started = CACurrentMediaTime()
        defer { TileTrace.note("thread stack placed \(subviews.count) rows in \(String(format: "%.1f", (CACurrentMediaTime() - started) * 1000)) ms") }
        let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(rowProposal) }
        // Worked out from where rows were in the last pass, before this one records where they are.
        let top = top(sizes, subviews)
        registry.rowsTop = top
        var y = bounds.minY + top
        let reports = ThreadRenderingProbe.rowGeometry
        if reports { registry.beginPass() }
        var spaceTop: CGFloat?
        for (index, subview) in subviews.enumerated() {
            if index > 0 { y += spacing }
            let size = sizes[index]
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            if reports, let id = subview[ThreadRowID.self] {
                registry.update(id, CGRect(x: 0, y: y - bounds.minY, width: bounds.width, height: size.height))
            }
            if subview[ThreadSpace.self] { spaceTop = y - bounds.minY }
            y += size.height
        }
        registry.spaceTop = spaceTop
    }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
/// A thread row's message, for the row registry.
struct ThreadRowID: LayoutValueKey { static let defaultValue: String? = nil }
/// The space standing in for rows left out below (`ThreadPresentation.window`).
struct ThreadSpace: LayoutValueKey { static let defaultValue = false }

/// Starts a scroll view at its end (macOS 15), for a thread's first frame.
struct OpensAtNewest: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            if enabled { content.defaultScrollAnchor(.bottom, for: .initialOffset) } else { content }
        } else {
            content
        }
    }
}

/// A tile's thread, with what the store knows of its loading (how deep it goes, whether older
/// messages are on their way, what was seen). A view of its own: those are kept in collections
/// for every tile, and reading them in the tile made each tile draw again — header, composer
/// and all — whenever any tile loaded older messages. Here only this small view is asked again,
/// and the thread itself only when its own values changed.
struct TileThread: View {
    @Environment(WorkspaceStore.self) private var store
    let conversation: Conversation
    let senderNames: [String: String]
    let zoom: CGFloat
    let findQuery: String
    let findCurrent: String?
    let onSearchOlder: () -> Void

    var body: some View {
        let count = conversation.messages.count
        MessageList(conversation: conversation, isLive: store.isLive,
                    canLoadMore: store.isLive && count >= (store.historyLimits[conversation.id] ?? WorkspaceStore.pageSize) && count < WorkspaceStore.maximumHistory,
                    isLoadingMore: store.loadingMore.contains(conversation.id),
                    senderNames: senderNames, zoom: zoom, animateNew: store.animateMessages,
                    seenBoundary: store.seenBoundary(conversation.id),
                    findQuery: findQuery, findCurrent: findCurrent,
                    historyCeiling: store.isLive && count >= WorkspaceStore.maximumHistory,
                    onSearchOlder: onSearchOlder,
                    onLoadMore: { [store, id = conversation.id] in store.loadMore(id) },
                    onTailSeen: { [store, id = conversation.id] in store.tailSeen(id) },
                    onTailLeft: { [store, id = conversation.id] in store.tailLeft(id) })
            .equatable()
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
    /// The row the thread opens on instead of the newest message (a window around a search result).
    var startsAt: String? = nil
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
    /// Changes when more (or fewer) rows are to be laid out (`ThreadPresentation.window`).
    @State private var windowRevision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: MessageList, rhs: MessageList) -> Bool {
        lhs.conversation == rhs.conversation && lhs.isLive == rhs.isLive && lhs.canLoadMore == rhs.canLoadMore
            && lhs.isLoadingMore == rhs.isLoadingMore
            && lhs.senderNames == rhs.senderNames && lhs.zoom == rhs.zoom && lhs.animateNew == rhs.animateNew
            && lhs.seenBoundary == rhs.seenBoundary && lhs.findQuery == rhs.findQuery && lhs.findCurrent == rhs.findCurrent
            && lhs.historyCeiling == rhs.historyCeiling && lhs.startsAt == rhs.startsAt
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
        // The rows laid out: the newest ones, and older ones as the reader scrolls up to them (or
        // a match or a reply's original is shown), so resizing, moving or opening a tile lays out
        // what can be seen and a little more — not every loaded message.
        let _ = windowRevision
        let spacing = 10 * zoom
        let shown = presentation.window(rows, following: isNearBottom, registry: registry, spacing: spacing, zoom: zoom)
        // Standing in for the rows left out below, as tall as they were (none while following).
        let spaceBelow = presentation.spaceBelow
        // Room above the rows while reading back, for older rows to come into without moving any.
        let roomAbove = presentation.keepsRoomAbove(moreAbove: shown.startIndex > 0 || canLoadMore)
        let showsStart = shown.startIndex == 0
        // Only the matching bubbles are given the find bar's words: a new query redraws those
        // alone, never the whole thread.
        let findMatches = presentation.findMatches(findQuery)
        // What the bubbles' names come from, so a bubble that skips redrawing still shows names that changed.
        let nameContext = senderNames.hashValue ^ conversation.name.hashValue ^ (conversation.isGroup ? 1 : 0)
        let content = ThreadContent(first: shown.first?.id, last: shown.last?.id, count: shown.count)
        let ids = prepared.ids
        let reactions = prepared.reactions
        let byGUID = prepared.byGUID
        // The New Messages line only while reading above them; at the tail everything is being seen.
        let firstUnread = isNearBottom ? nil : Self.firstUnread(in: rows, after: seenBoundary)
        let attachmentFiles = prepared.attachmentFiles
        ScrollViewReader { proxy in
        ScrollView {
            // A plain stack, not a lazy one: a lazy stack inserts and removes rows while a tile
            // grows or shrinks, which made rows jump. It tells the row registry where each row is
            // as it places them (ThreadStack).
            ThreadStack(spacing: spacing, roomAbove: roomAbove, registry: registry) {
                // Earlier messages load by themselves as the reader nears the top; a small spinner
                // shows while they come.
                if historyCeiling && showsStart {
                    // Not the start of the conversation: the most a tile shows.
                    VStack(spacing: 4) {
                        Text("Showing the newest \(WorkspaceStore.maximumHistory.formatted()) messages. Older ones are still on this Mac.")
                            .font(.system(size: 10 * zoom)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Search Older Messages", action: onSearchOlder).buttonStyle(.borderless).font(.system(size: 10 * zoom, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                if canLoadMore && isLoadingMore && showsStart {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 4)
                        .accessibilityLabel("Loading earlier messages")
                }
                if conversation.messages.isEmpty {
                    Text(isLive ? "Loading this conversation…" : "Start the conversation.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
                ForEach(shown) { row in
                    VStack(spacing: 10 * zoom) {
                        // The first row laid out always says its day.
                        if let day = row.dayLabel ?? (row.id == shown.first?.id ? MessageText.day(row.message.date) : nil) {
                            Text(day).font(.system(size: 10 * zoom, weight: .medium))
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 4 * zoom)
                                .allowsHitTesting(false)
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
                                      findQuery: findMatches.contains(row.id) ? findQuery : "",
                                      nameContext: nameContext,
                                      actorName: { name(of: $0) }, replyAuthor: { author(of: $0) },
                                      onShowOriginal: { original in jump(to: original.presentationID, proxy: proxy) })
                            // A bubble whose own values are unchanged is not redrawn (its closures
                            // are left out of the comparison: what they read is in `nameContext`).
                            .equatable()
                    }
                    .id(row.id)
                    // Messages in a run from the same person sit close together; a new run gets the full gap.
                    .padding(.top, row.continuesRun ? -7 * zoom : 0)
                    // A row that just arrived at the tail settles in once; everything else is still.
                    .modifier(NewMessageEffect(animated: freshIDs.contains(row.id),
                                               incoming: !row.message.isFromMe, reduceMotion: reduceMotion))
                    // Which row this is, for the registry (ThreadStack reports where it placed it).
                    .layoutValue(key: ThreadRowID.self, value: row.id)
                }
                if spaceBelow > 0 {
                    Color.clear.frame(height: spaceBelow).accessibilityHidden(true).layoutValue(key: ThreadSpace.self, value: true)
                }
            }
            .coordinateSpace(name: "thread")
            .padding(16 * zoom)
            .environment(\.threadAttachments, attachmentFiles)
            .background(MessageScrollSupport(scrollToBottomRequest: latestRequest, content: content, registry: registry, startRow: startsAt,
                                             onNearTop: { [presentation, registry] in
                // Near the top of what is laid out: a few more of the older loaded rows (and rows
                // far below the view left out), and once few are left above, the next page of
                // history is read — in good time, well before the reader gets there.
                if presentation.expand(rows, registry: registry, zoom: zoom) {
                    TileTrace.note("thread window grows")
                    windowRevision += 1
                }
                if canLoadMore, presentation.rowsAbove(rows) < ThreadPresentation.prefetchRows {
                    TileTrace.note("older page asked")
                    onLoadMore()
                }
            }, onNearSpaceBelow: { [presentation, registry] in
                // Back down towards the rows left out below: some are laid out again.
                if presentation.nearSpaceBelow(rows, registry: registry) { windowRevision += 1 }
            }, onScrollIdle: { [presentation, registry] distanceFromTop in
                // Stopped a long way back: older rows are laid out ahead while nothing moves.
                guard distanceFromTop < ThreadPresentation.idleAhead else { return }
                if presentation.expand(rows, by: ThreadPresentation.idleStep, registry: registry, zoom: zoom) {
                    TileTrace.note("thread window grows while still")
                    windowRevision += 1
                }
                if canLoadMore, presentation.rowsAbove(rows) < ThreadPresentation.prefetchRows { onLoadMore() }
            }) { near in
                if isNearBottom != near { isNearBottom = near }
            })
        }
        // The find bar's current match is brought to the middle of the tile (also when the
        // thread first appears around one), laid out first if it was further up.
        .onChange(of: findCurrent) { _, id in
            guard let id else { return }
            if presentation.include(id, in: rows) {
                windowRevision += 1
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .onAppear { if startsAt == nil, let id = findCurrent { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } } }
        // A thread opens on its newest message from its very first frame (the pinner, which
        // keeps it there, attaches a moment later); a window into older history opens on its row.
        .modifier(OpensAtNewest(enabled: startsAt == nil))
        }
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom && showsLatestButton {
                Button {
                    // The newest rows laid out first, so the way down shows them, not the space
                    // standing in for rows left out below.
                    if presentation.release() { windowRevision += 1 }
                    latestRequest += 1
                } label: {
                    Label(conversation.unreadCount > 0 ? "\(conversation.unreadCount) new" : "Latest", systemImage: "arrow.down")
                        .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
                }.buttonStyle(.plain).padding(12)
                .accessibilityLabel(conversation.unreadCount > 0 ? "\(conversation.unreadCount) new messages; go to the latest" : "Go to the latest message")
            }
        }
        .onAppear { if isNearBottom { onTailSeen() } }
        .onDisappear { onTailLeft() }
        .onChange(of: isNearBottom) { _, near in
            if near {
                onTailSeen()
                // Back at the newest message: the older rows laid out on the way up can go.
                if presentation.release() { windowRevision += 1 }
            } else { onTailLeft() }
        }
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
        if presentation.include(id, in: presentation.prepared(for: conversation).rows) {
            windowRevision += 1
            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
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
        /// Each row's place in `rows`, by its id.
        let index: [String: Int]
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
    private var findQuery = ""
    private var findBuild = -1
    private var findSet: Set<String> = []

    // MARK: The rows laid out

    /// How many rows a thread lays out at least: far more than a tile shows, far fewer than a
    /// long history.
    static let windowSize = 80
    /// How many older rows are added each time the reader nears the top of what is laid out. A
    /// few at a time: the thread asks again on the next scroll step while still near the top, so
    /// rows come a handful per frame — never a page at once, which held frames up.
    static let step = 8
    /// How many are added at once when the reader stops scrolling a long way back
    /// (`idleAhead`): while nothing moves, so the next stretch up needs few added on the way.
    static let idleStep = 32
    /// How far above the view rows are laid out ahead of the reader when they stop scrolling.
    static let idleAhead: CGFloat = 6000
    /// How far beyond the view (points) laid-out rows are kept. Rows further below are left out,
    /// a space as tall as they were standing in for them, and rows further above are left out
    /// while the reader goes back down: however far back the reader goes, about the same number
    /// of rows are laid out, and adding the next ones costs the same.
    static let keptBeyondView: CGFloat = 3200
    /// How few loaded rows may be left above what is laid out before the next page of history is
    /// read: a page and a half, so it has arrived long before the reader gets there.
    static let prefetchRows = 150
    /// The first row laid out last time.
    private var windowFirst: String?
    /// The last row laid out, when the rows below it are left out; nil when every row down to the
    /// newest is laid out.
    private var windowLast: String?
    /// The width and zoom the rows left out below were laid out at: they are as tall as that then.
    private var leftOutAt: (width: CGFloat, zoom: CGFloat)?
    /// How tall the space standing in for the rows left out below is (0: there is none).
    private(set) var spaceBelow: CGFloat = 0
    /// Older rows were laid out on purpose (scrolled to, a match, a reply's original): following
    /// the newest message does not drop them until the reader is back there.
    private var holdsOlder = false
    /// Whether room is kept above the rows (`ThreadStack.roomAbove`): while the reader reads back
    /// from the newest message and there is more above to lay out — not at the start of the
    /// conversation, or at the most a tile shows, so the reader never scrolls into empty room.
    func keepsRoomAbove(moreAbove: Bool) -> Bool { holdsOlder && moreAbove }

    /// A row's place in `rows` (the rows of the last build, looked up at once).
    private func position(of id: String, in rows: [MessageRow]) -> Int? {
        if let cached, cached.rows.count == rows.count, let at = cached.index[id], rows[at].id == id { return at }
        return rows.firstIndex { $0.id == id }
    }
    /// One past the last row laid out.
    private func windowEnd(_ rows: [MessageRow]) -> Int {
        windowLast.flatMap { position(of: $0, in: rows) }.map { $0 + 1 } ?? rows.count
    }

    /// The rows to lay out: the newest `windowSize` while following the newest message; else from
    /// where the window began, so nothing in view moves when rows arrive below, and an older page
    /// that loads above waits there until the reader nears it (`expand`). Rows left out below stop
    /// it short (`spaceBelow` stands in for them) while they are as tall as when they were laid
    /// out — same width, same zoom.
    func window(_ rows: [MessageRow], following: Bool, registry: ThreadRowRegistry? = nil, spacing: CGFloat = 0, zoom: CGFloat = 1) -> ArraySlice<MessageRow> {
        spaceBelow = 0
        guard !rows.isEmpty else { windowFirst = nil; windowLast = nil; return rows[...] }
        let start: Int
        if following && !holdsOlder {
            start = max(0, rows.count - Self.windowSize)
            windowLast = nil
        } else if let first = windowFirst, let index = position(of: first, in: rows) {
            start = index
        } else {
            start = max(0, rows.count - Self.windowSize)
        }
        windowFirst = rows[start].id
        var end = rows.count
        if let last = windowLast, let index = position(of: last, in: rows), index >= start, index + 1 < rows.count,
           let registry, let leftOutAt, leftOutAt.zoom == zoom, abs(leftOutAt.width - registry.width) < 0.5 {
            end = index + 1
            spaceBelow = Self.height(of: rows[end...], registry: registry, spacing: spacing)
        } else {
            windowLast = nil
        }
        return rows[start..<end]
    }
    /// How tall rows were when last laid out, with the gaps between them. Rows never laid out (new
    /// messages that arrived while the reader was a long way back) take no room until they are.
    static func height(of rows: ArraySlice<MessageRow>, registry: ThreadRowRegistry, spacing: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        var known = 0
        for row in rows {
            guard let height = registry.heights[row.id] else { continue }
            total += height
            known += 1
        }
        return known == 0 ? 0 : total + spacing * CGFloat(known - 1)
    }
    /// Lays out `count` more of the older loaded rows, and leaves out the rows more than
    /// `keptBeyondView` below the view. False when every row is laid out already.
    func expand(_ rows: [MessageRow], by count: Int = ThreadPresentation.step, registry: ThreadRowRegistry? = nil, zoom: CGFloat = 1) -> Bool {
        guard let first = windowFirst, let index = position(of: first, in: rows), index > 0 else { return false }
        let start = max(0, index - count)
        windowFirst = rows[start].id
        holdsOlder = true
        if let registry { leaveOutBelow(rows, from: start, registry: registry, zoom: zoom) }
        return true
    }
    /// Leaves out the laid-out rows wholly more than `keptBeyondView` below the view: they were
    /// just laid out, so the space standing in for them is exactly as tall as they are, and nothing
    /// in view moves.
    private func leaveOutBelow(_ rows: [MessageRow], from start: Int, registry: ThreadRowRegistry, zoom: CGFloat) {
        guard let visible = registry.visible else { return }
        let end = windowEnd(rows)
        guard end - start > Self.windowSize else { return }
        let limit = visible.upperBound + Self.keptBeyondView
        var newEnd = end
        while newEnd - 1 > start, let frame = registry.frames[rows[newEnd - 1].id], frame.minY >= limit { newEnd -= 1 }
        guard newEnd < end else { return }
        windowLast = rows[newEnd - 1].id
        leftOutAt = (registry.width, zoom)
        TileTrace.note("rows left out below: \(end - newEnd)")
    }
    /// The reader nears the space standing in for the rows left out below. If many rows are laid
    /// out, those wholly more than `keptBeyondView` above the view are left out first (rows above
    /// the view leaving is the same as rows arriving there: the view keeps its place); otherwise
    /// `count` of the rows below are laid out again, as tall as they were, so nothing in view moves.
    /// False when nothing changed.
    func nearSpaceBelow(_ rows: [MessageRow], by count: Int = ThreadPresentation.step, registry: ThreadRowRegistry) -> Bool {
        guard let last = windowLast, let lastIndex = position(of: last, in: rows),
              let first = windowFirst, let start = position(of: first, in: rows) else { return false }
        let end = lastIndex + 1
        if end - start > Self.windowSize, let visible = registry.visible {
            let limit = visible.lowerBound - Self.keptBeyondView
            var newStart = start
            while newStart + 1 < end, let frame = registry.frames[rows[newStart].id], frame.maxY <= limit { newStart += 1 }
            if newStart > start {
                windowFirst = rows[newStart].id
                TileTrace.note("rows left out above: \(newStart - start)")
                return true
            }
        }
        let newEnd = min(rows.count, end + count)
        windowLast = newEnd < rows.count ? rows[newEnd - 1].id : nil
        if windowLast == nil { leftOutAt = nil }
        TileTrace.note("rows laid out again below: \(newEnd - end)")
        return true
    }
    /// How many loaded rows are above what is laid out.
    func rowsAbove(_ rows: [MessageRow]) -> Int {
        windowFirst.flatMap { position(of: $0, in: rows) } ?? 0
    }
    /// Makes sure a row is laid out, with a few above it. True when the window had to grow.
    func include(_ id: String, in rows: [MessageRow]) -> Bool {
        guard let index = position(of: id, in: rows) else { return false }
        holdsOlder = true
        // Among the rows left out below: they are all laid out again.
        if windowLast != nil, index >= windowEnd(rows) - 3 {
            windowLast = nil
            leftOutAt = nil
            return true
        }
        let current = windowFirst.flatMap { position(of: $0, in: rows) } ?? max(0, rows.count - Self.windowSize)
        guard index < current + 3, current > 0 else { return false }
        let start = max(0, index - 10)
        windowFirst = rows[start].id
        return true
    }
    /// Back at the newest message: the window may shrink to the newest rows again, every row
    /// down to the newest laid out. True when it held older ones or left rows out below.
    func release() -> Bool {
        guard holdsOlder || windowLast != nil else { return false }
        holdsOlder = false
        windowLast = nil
        leftOutAt = nil
        return true
    }

    /// The rows whose text has the find bar's words, worked out once per query and build.
    func findMatches(_ query: String) -> Set<String> {
        guard !query.isEmpty, let cached else { return [] }
        if query == findQuery, findBuild == buildCount { return findSet }
        findQuery = query
        findBuild = buildCount
        findSet = Set(FindInConversation.matches(query, in: cached.rows.map(\.message)))
        return findSet
    }

    func prepared(for conversation: Conversation) -> Prepared {
        let clock = MessageText.currentEnvironment()
        let now = Inputs(messages: conversation.messages, reactions: conversation.reactions, clock: clock)
        if let cached, now == inputs { return cached }
        buildCount += 1
        let rows = MessageRow.rows(for: conversation)
        let ids = rows.map(\.id)
        let prepared = Prepared(rows: rows, ids: ids, index: Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }),
            reactions: Reactions.reduce(conversation.reactions),
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

struct MessageBubble: View, Equatable {
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
    /// Changes when the names the closures below give change (a contact was named, a group renamed).
    var nameContext = 0
    var actorName: (ReactionActor) -> String = { _ in "Someone" }
    var replyAuthor: (Message) -> String = { _ in "" }
    var onShowOriginal: (Message) -> Void = { _ in }

    init(message: Message, threadID: String = "", group: Bool, senderName: String?, live: Bool, service: String,
         showsStatus: Bool = true, showsTime: Bool = true, authorName: String = "", reactions: [ReactionSummary] = [],
         reply: ReplyContext? = nil, highlighted: Bool = false, findQuery: String = "", nameContext: Int = 0,
         actorName: @escaping (ReactionActor) -> String = { _ in "Someone" }, replyAuthor: @escaping (Message) -> String = { _ in "" },
         onShowOriginal: @escaping (Message) -> Void = { _ in }) {
        self.message = message; self.threadID = threadID; self.group = group; self.senderName = senderName; self.live = live
        self.service = service; self.showsStatus = showsStatus; self.showsTime = showsTime; self.authorName = authorName
        self.reactions = reactions; self.reply = reply; self.highlighted = highlighted; self.findQuery = findQuery
        self.nameContext = nameContext; self.actorName = actorName; self.replyAuthor = replyAuthor; self.onShowOriginal = onShowOriginal
    }

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message && lhs.threadID == rhs.threadID && lhs.group == rhs.group && lhs.senderName == rhs.senderName
            && lhs.live == rhs.live && lhs.service == rhs.service && lhs.showsStatus == rhs.showsStatus && lhs.showsTime == rhs.showsTime
            && lhs.authorName == rhs.authorName && lhs.reactions == rhs.reactions && lhs.reply == rhs.reply
            && lhs.highlighted == rhs.highlighted && lhs.findQuery == rhs.findQuery && lhs.nameContext == rhs.nameContext
    }

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
                    // VoiceOver reads who wrote it, and offers the context menu's actions by name.
                    .applying(ThreadRenderingProbe.accessibilityLabels) {
                        $0.accessibilityElement(children: .ignore)
                            .accessibilityLabel(fromMe ? "You: \(message.text)" : "\(authorName): \(message.text)")
                    }
                    .applying(ThreadRenderingProbe.accessibilityActions) {
                        $0.accessibilityActions {
                            Button("Copy") { copyText() }
                            ForEach(LinkDetector.links(in: message.text), id: \.range.location) { match in
                                Button("Open \(LinkPreviewLoader.host(match.url))") { NSWorkspace.shared.open(match.url) }
                            }
                            if message.sendState?.isFailed == true {
                                Button("Try Again") { Task { await store.retrySend(message.presentationID, in: threadID) } }
                            }
                        }
                    }
                    .applying(ThreadRenderingProbe.contextMenus) {
                        $0.contextMenu {
                            Button("Copy") { copyText() }
                            ForEach(LinkDetector.links(in: message.text), id: \.range.location) { match in
                                Button("Open \(LinkPreviewLoader.host(match.url))") { NSWorkspace.shared.open(match.url) }
                            }
                            failedSendActions
                        }
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
                // Only a refused send has anything to offer here; elsewhere the line takes no
                // clicks, which keeps the pointer's hit-testing over a long thread light.
                .applying(message.sendState?.isFailed == true) { $0.contextMenu { failedSendActions } }
                .allowsHitTesting(message.sendState?.isFailed == true)
            }
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .padding(fromMe ? .leading : .trailing, 36 * zoom)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
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

/// The loaded messages' matches for the find bar, worked out once for each query and history and
/// reused by every render that asks (the bar's count, stepping, the thread's marks).
@MainActor final class FindIndex {
    private var query = ""
    private var messages: [Message] = []
    private var result: [String] = []
    private var rowsFor: [Message] = []
    private var rows: Set<String> = []
    /// The matches' presentation ids, oldest first.
    func matches(_ query: String, in messages: [Message]) -> [String] {
        // Comparing arrays that share their storage (an unchanged history) costs nothing.
        if query == self.query, messages == self.messages { return result }
        self.query = query
        self.messages = messages
        result = FindInConversation.matches(query, in: messages)
        return result
    }
    /// The database rows of the loaded messages, to leave out older matches that are loaded now.
    func rowIDs(of messages: [Message]) -> Set<String> {
        if messages != rowsFor { rowsFor = messages; rows = Set(messages.map(\.id)) }
        return rows
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

/// A tile's find bar: the words to look for, how many messages match and which one is shown, and
/// buttons to the older and newer match. Return (or ↑) goes to the older match, Shift–Return (or
/// ↓) to the newer one, and Esc closes the bar. What is typed stays in the bar's own state, so a
/// keystroke redraws the bar alone; the words go to the tile (`onQuery`) a moment after typing
/// stops.
struct FindBar: View {
    let matchCount: Int
    /// Which match is shown, counted from the newest (1).
    let position: Int?
    /// Whether there are words to look for (so "No matches" can be said).
    let searching: Bool
    /// The older history is still being searched (more matches may come).
    var searchingOlder = false
    let onQuery: (String) -> Void
    let onOlder: () -> Void
    let onNewer: () -> Void
    let onClose: () -> Void
    /// Changes when ⌥⌘F asks for the field again while the bar is open.
    var focusToken = 0
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            RecipientTextField(text: $text, takesFocus: true, placeholder: "Find in conversation", focusToken: focusToken) { command in
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
            .accessibilityLabel("Find in conversation")
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
        // The thread marks the words a moment after typing stops, so a keystroke never redraws it.
        .task(id: text) {
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            onQuery(text)
        }
    }

    private var status: String {
        guard searching else { return "" }
        guard matchCount > 0 else { return searchingOlder ? "Searching…" : "No matches" }
        let count = searchingOlder ? "\(matchCount)+" : "\(matchCount)"
        return position.map { "\($0) of \(count)" } ?? "\(count) found"
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

/// The find bar's matches in the history older than what the tile has loaded, listed as the
/// search finds them (date, who, the line). The search starts by itself when the words settle and
/// goes back part by part on a connection of its own, so loading is never held up; their words —
/// plain and rich text — are matched on this Mac, and nothing is indexed or kept.
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
                        Text(search.matches.isEmpty ? "Searching older messages…" : "\(summary(search)) · searching…").lineLimit(1)
                        Spacer(minLength: 4)
                    } else {
                        Text(summary(search)).lineLimit(1)
                        Spacer(minLength: 4)
                        // Stopped at its bounds (very many matches, or a very long history): on request only.
                        if search.next != nil {
                            Button("Search Further") { store.continueOlderSearch(conversationID) }.buttonStyle(.borderless)
                                .help("Look further back in this conversation")
                        }
                    }
                }
                .help("Older messages on this Mac are searched by their words, plain or rich text — not attachments or earlier versions of edited messages")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func summary(_ search: HistorySearch) -> String {
        if search.failed { return "Couldn't search older messages right now." }
        let found = search.matches.isEmpty ? "No older matches" : search.matches.count == 1 ? "1 older match" : "\(search.matches.count.formatted()) older matches"
        if search.isSearching { return found }
        let scope = search.next == nil ? "searched back to the first message" : "in the \(search.scanned.formatted()) messages before these"
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

/// What a thread's bubbles carry, switchable so a test can measure what each part costs when a
/// tile is resized. Always all on in the app.
enum ThreadRenderingProbe {
    nonisolated(unsafe) static var accessibilityLabels = true
    nonisolated(unsafe) static var accessibilityActions = true
    nonisolated(unsafe) static var contextMenus = true
    nonisolated(unsafe) static var rowGeometry = true
    static func reset() { accessibilityLabels = true; accessibilityActions = true; contextMenus = true; rowGeometry = true }
}

extension View {
    /// The view with `change` applied when `condition` holds.
    @ViewBuilder func applying<Changed: View>(_ condition: Bool, _ change: (Self) -> Changed) -> some View {
        if condition { change(self) } else { self }
    }
}
