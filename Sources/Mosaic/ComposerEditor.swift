import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Each tile owns a separate NSTextView. Send is dispatched from that editor's
/// keyDown handler, so Return cannot invoke a different tile's default button.
struct ComposerEditor: NSViewRepresentable {
    /// The text size at 100%. The shared zoom scales the text only: the field, the + button and
    /// the emoji button keep their size at every zoom.
    static let baseFontSize: CGFloat = 11
    /// The field's resting height, one line, at every zoom (the + and emoji buttons are as tall).
    static let barHeight: CGFloat = 31
    /// Text sits 8pt from the field's left and right edges.
    static let sideMargin: CGFloat = 8
    static func font(zoom: CGFloat) -> NSFont { .systemFont(ofSize: (baseFontSize * zoom).rounded()) }
    static func lineHeight(zoom: CGFloat) -> CGFloat { NSLayoutManager().defaultLineHeight(for: font(zoom: zoom)) }
    /// Above and below the text: one line sits centered in the bar, whatever its size.
    static func verticalMargin(zoom: CGFloat) -> CGFloat { max(2, (barHeight - lineHeight(zoom: zoom)) / 2) }
    static func minimumHeight(zoom: CGFloat) -> CGFloat { barHeight }
    /// The field grows with the draft up to this height (about six lines at 100%), then scrolls.
    static let maximumHeight: CGFloat = (barHeight + lineHeight(zoom: 1) * 5).rounded(.up)
    static func maximumHeight(zoom: CGFloat) -> CGFloat { maximumHeight }
    static let minimumHeight = barHeight

    @Binding var text: String
    var placeholder = ""
    var conversationID = ""
    let accessibilityLabel: String
    /// Hands this field the keyboard when the workspace asks for it (see `ComposerFocus`).
    var focus: ComposerFocus? = nil
    /// The shared conversation zoom; the font and margins follow it, in place.
    var zoom: CGFloat = 1
    var height: Binding<CGFloat>? = nil
    let onFocus: () -> Void
    let onSend: () -> Void
    var onTab: (Bool) -> Void = { _ in }
    /// Esc, when the field has a use for it (closing a new-message tile).
    var onCancel: (() -> Void)? = nil
    /// Files pasted or dropped into the field (a Finder copy, a drag from the desktop).
    var onAttachFiles: ([URL]) -> Void = { _ in }
    /// Picture data pasted or dropped into the field (a screenshot, Copy Image in a browser).
    var onAttachPicture: (Data, UTType) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: Self.minimumHeight(zoom: zoom)))
        let clip = PinnedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        // The field only scrolls once the text is taller than its maximum height; it never bounces.
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        let font = Self.font(zoom: zoom)
        // TextKit 1, set up by AppKit itself: its insertion point follows textContainerInset in every
        // state, including an empty field, where the default stack could draw the caret at the edge.
        let editor = DraftTextView(usingTextLayoutManager: false)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: Self.sideMargin, height: Self.verticalMargin(zoom: zoom))
        editor.textContainer?.widthTracksTextView = true
        // Insets first, then the frame: the container's width is derived from both at frame time.
        editor.frame = NSRect(origin: .zero, size: scroll.contentSize)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = font
        editor.textColor = .labelColor
        editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.string = text
        // Files and pictures can be dropped on the field; they become attachments, not text.
        editor.registerForDraggedTypes(editor.registeredDraggedTypes + DraftTextView.attachmentTypes)
        scroll.documentView = editor
        ThinScroller.install(in: scroll)
        if let layoutManager = editor.layoutManager, let container = editor.textContainer { layoutManager.ensureLayout(for: container) }
        apply(to: editor, coordinator: context.coordinator)
        return scroll
    }

    /// The field is exactly as large as the layout around it says (its height comes from the
    /// `height` binding). SwiftUI must never size it through Auto Layout: a fitting-size query on an
    /// NSScrollView during the window's constraint pass can make that pass start over.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: proposal.height ?? Self.minimumHeight(zoom: zoom))
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? DraftTextView else { return }
        apply(to: editor, coordinator: context.coordinator)
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            editor.needsDisplay = true
            editor.fitToClip(scroll.contentSize)
            editor.reportHeight()
        }
        // The keyboard is never moved here, inside a SwiftUI update: becoming first responder
        // reports focus back to the store, and changing state mid-update re-runs the update.
        // `ComposerFocus` hands it over at the next moment of rest.
    }

    private func apply(to editor: DraftTextView, coordinator: Coordinator) {
        // The zoom changed: the same editor keeps its text, selection, undo and marked text; only
        // the font changes, re-centered in the same bar.
        let font = Self.font(zoom: zoom)
        if editor.font?.pointSize != font.pointSize {
            editor.font = font
            editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
            editor.textContainerInset = NSSize(width: Self.sideMargin, height: Self.verticalMargin(zoom: zoom))
            editor.needsDisplay = true
            if let scroll = editor.enclosingScrollView { editor.fitToClip(scroll.contentSize) }
            editor.reportHeight()
        }
        editor.onFocus = onFocus
        editor.onSend = onSend
        editor.onTab = onTab
        editor.onCancel = onCancel
        editor.onAttachFiles = onAttachFiles
        editor.onAttachPicture = onAttachPicture
        editor.conversationID = conversationID
        editor.focusController = focus
        DraftTextView.register(editor, for: conversationID)
        if editor.placeholder != placeholder { editor.placeholder = placeholder; editor.needsDisplay = true }
        editor.onHeightChange = { [weak coordinator] value in coordinator?.report(value) }
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityPlaceholderValue(placeholder)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func report(_ value: CGFloat) {
            let clamped = min(max(value.rounded(.up), ComposerEditor.minimumHeight(zoom: parent.zoom)), ComposerEditor.maximumHeight(zoom: parent.zoom))
            guard let height = parent.height, abs(height.wrappedValue - clamped) > 0.5 else { return }
            // Defer: this runs during AppKit layout, never mutate SwiftUI state inside a view update.
            DispatchQueue.main.async { if abs(height.wrappedValue - clamped) > 0.5 { height.wrappedValue = clamped } }
        }
    }
}

/// Keeps the text view exactly as wide as the visible area. Autoresizing alone drifts when SwiftUI
/// first sizes the scroll view from zero, which put long lines and the caret outside the field.
final class ComposerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? DraftTextView)?.fitToClip(contentSize)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (self.documentView as? DraftTextView)?.fitToClip(self.contentSize)
        }
    }
}

/// Keeps the text pinned to the top whenever it fits in the field. AppKit otherwise keeps a scroll
/// offset left over from an earlier, taller state, which showed a new tile's composer with its
/// placeholder shifted until the field was scrolled by hand.
final class PinnedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.x = 0
        if let document = documentView, document.frame.height <= bounds.height + 0.5 { rect.origin.y = 0 }
        return rect
    }
}

final class DraftTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onSend: (() -> Void)?
    var onTab: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachPicture: ((Data, UTType) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var conversationID = ""
    var placeholder = ""
    /// Hands this field the keyboard when asked; told when the field joins a window.
    weak var focusController: ComposerFocus?
    private var lastReportedWidth: CGFloat = 0

    // The tiles' editors by conversation, so the emoji button next to a field — and a focus
    // request — can reach the field that is live now. Weak: a field that went away drops out.
    private final class WeakEditor { weak var view: DraftTextView?; init(_ view: DraftTextView) { self.view = view } }
    @MainActor private static var registry: [String: [WeakEditor]] = [:]
    @MainActor static func register(_ editor: DraftTextView, for conversationID: String) {
        guard !conversationID.isEmpty else { return }
        var editors = (registry[conversationID] ?? []).filter { $0.view != nil && $0.view !== editor }
        editors.append(WeakEditor(editor))
        registry[conversationID] = editors
        if registry.count > 32 { registry = registry.filter { $0.value.contains { $0.view != nil } } }
    }
    /// The fields registered for a conversation, the most recently registered last.
    @MainActor static func editors(for conversationID: String) -> [DraftTextView] {
        registry[conversationID]?.compactMap(\.view).filter { $0.conversationID == conversationID } ?? []
    }
    /// The conversation's field that is in a window, else the most recent one.
    @MainActor static func editor(for conversationID: String) -> DraftTextView? {
        let editors = editors(for: conversationID)
        return editors.last { $0.window != nil } ?? editors.last
    }

    /// Opens the system Emoji & Symbols palette; a chosen emoji is inserted at this field's caret.
    func showEmojiPicker() {
        if let window, window.firstResponder !== self, window.makeFirstResponder(self) { placeCaretAtEnd() }
        NSApp.orderFrontCharacterPalette(nil)
    }
    /// The caret at the end of the draft, in view.
    func placeCaretAtEnd() {
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            // Shift–Return is a line break; Return sends. Inserting the break here (rather than through
            // key-event interpretation) makes it the same in every input context.
            if event.modifierFlags.contains(.shift) { insertNewline(nil); return }
            if !event.isARepeat { onSend?() }
            return
        }
        super.keyDown(with: event)
    }
    // Tab and Shift–Tab move between tiles instead of inserting a tab character.
    override func insertTab(_ sender: Any?) { onTab?(true) }
    override func insertBacktab(_ sender: Any?) { onTab?(false) }
    // Esc closes a New Message tile; elsewhere it does nothing. (NSResponder declares
    // cancelOperation(_:) without implementing it: calling super raised an exception.)
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // MARK: Pictures and files

    static let attachmentTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + [UTType.png, .jpeg, .gif, .heic, .tiff].map { NSPasteboard.PasteboardType($0.identifier) }

    /// Pasting a picture or a file attaches it to the message; anything else pastes as text.
    override func paste(_ sender: Any?) { if !attach(from: NSPasteboard.general) { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { if !attach(from: NSPasteboard.general) { super.pasteAsPlainText(sender) } }
    /// Paste (the Edit menu item, and so ⌘V) stays enabled when the pasteboard holds a picture or
    /// a file. NSTextView otherwise disables it for anything it cannot read as text, and a
    /// disabled item never sends `paste:`.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) || item.action == #selector(pasteAsPlainText(_:)),
           NSPasteboard.general.availableType(from: Self.attachmentTypes) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }
    /// Takes the files or picture a pasteboard carries, if any.
    @discardableResult func attach(from pasteboard: NSPasteboard) -> Bool {
        switch OutgoingFiles.contents(of: pasteboard) {
        case .files(let urls): onAttachFiles?(urls); return true
        case .picture(let data, let type): onAttachPicture?(data, type); return true
        case nil: return false
        }
    }
    private func carriesAttachment(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: Self.attachmentTypes) != nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesAttachment(sender) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesAttachment(sender) ? .copy : super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        carriesAttachment(sender) ? true : super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if carriesAttachment(sender), attach(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        if let scroll = enclosingScrollView { fitToClip(scroll.contentSize) }
        reportHeight()
    }

    /// Makes the text view exactly as tall as the visible area, or as tall as its text when that is
    /// taller. After a long draft is sent, the view used to stay tall inside a short field, which left
    /// an empty composer that scrolled and clipped its placeholder.
    func fitToClip(_ clip: NSSize) {
        guard clip.width > 0, clip.height > 0, let layoutManager, let textContainer else { return }
        minSize = NSSize(width: 0, height: clip.height)
        if frame.origin != .zero { setFrameOrigin(.zero) }
        if abs(frame.width - clip.width) > 0.5 { setFrameSize(NSSize(width: clip.width, height: frame.height)) }
        syncContainerWidth()
        layoutManager.ensureLayout(for: textContainer)
        // An empty field is never taller than its visible area, so it can never be scrolled.
        let used = string.isEmpty ? clip.height : textHeight + textContainerInset.height * 2
        let height = max(used.rounded(.up), clip.height)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: clip.width, height: height)) }
        if height <= clip.height + 0.5, let clipView = enclosingScrollView?.contentView, clipView.bounds.origin != .zero {
            clipView.scroll(to: .zero)
            enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scroll = enclosingScrollView { fitToClip(scroll.contentSize) }
        // A request may be waiting for this field (a tile that just opened).
        if window != nil { focusController?.editorDidMoveToWindow(self) }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncContainerWidth()
        if abs(newSize.width - lastReportedWidth) > 0.5 {
            lastReportedWidth = newSize.width
            reportHeight()
        }
    }
    /// Text always starts exactly one margin in from the left and top. AppKit derives this point from
    /// the container's width and can center a container sized before the inset was set, which put the
    /// first line at the field's edge until the next resize.
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: textContainerInset.height) }
    /// The container is as wide as the view minus both side margins, whatever order things were set in.
    private func syncContainerWidth() {
        guard let textContainer else { return }
        let width = max(1, bounds.width - textContainerInset.width * 2)
        if abs(textContainer.size.width - width) > 0.5 {
            textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            needsDisplay = true
        }
    }
    override func viewWillDraw() {
        syncContainerWidth()
        super.viewWillDraw()
    }
    override func scrollRangeToVisible(_ range: NSRange) {
        // Nothing to bring into view while the whole draft fits; scrolling would only shift the text.
        if let clip = enclosingScrollView?.contentSize, frame.height <= clip.height + 0.5 { return }
        super.scrollRangeToVisible(range)
    }

    /// Height of the laid-out text. An empty field measures as exactly one line, so every tile's
    /// composer is the same height whatever the layout manager reports for its empty line.
    private var textHeight: CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: ComposerEditor.baseFontSize))
        guard !string.isEmpty, let layoutManager, let textContainer else { return line }
        layoutManager.ensureLayout(for: textContainer)
        return max(layoutManager.usedRect(for: textContainer).height, line)
    }

    /// Reported so the composer can grow up to a few lines.
    func reportHeight() {
        guard let onHeightChange else { return }
        onHeightChange(textHeight + textContainerInset.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        // Drawn at the text container's own origin, so the caret and the placeholder always line up.
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = textContainerOrigin
        let line = layoutManager?.defaultLineHeight(for: font) ?? 16
        // The same margins as the typed text, so the placeholder and the first character line up.
        let rect = NSRect(x: origin.x + padding, y: origin.y, width: max(0, bounds.width - origin.x - textContainerInset.width - padding * 2), height: line)
        NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
