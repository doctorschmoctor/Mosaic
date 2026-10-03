import SwiftUI
import AppKit

/// Each tile owns a separate NSTextView. Send is dispatched from that editor's
/// keyDown handler, so Return cannot invoke a different tile's default button.
struct ComposerEditor: NSViewRepresentable {
    static let font = NSFont.systemFont(ofSize: 12)
    /// Text sits 8pt from the field's left, top and right edges; one line of text plus those margins
    /// is the field's resting height, so the margins are the same whatever font metrics the Mac uses.
    static let margin: CGFloat = 8
    static let minimumHeight: CGFloat = (NSLayoutManager().defaultLineHeight(for: font) + margin * 2).rounded(.up)
    /// After about six lines the field stops growing and scrolls.
    static let maximumHeight: CGFloat = (NSLayoutManager().defaultLineHeight(for: font) * 6 + margin * 2).rounded(.up)

    @Binding var text: String
    var placeholder = ""
    var conversationID = ""
    let accessibilityLabel: String
    /// A changed non-zero value asks this editor to become first responder (keyboard traversal).
    var focusRequest: Int
    var height: Binding<CGFloat>? = nil
    let onFocus: () -> Void
    let onSend: () -> Void
    var onTab: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: Self.minimumHeight))
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
        let font = Self.font
        // TextKit 1, set up by AppKit itself: its insertion point follows textContainerInset in every
        // state, including an empty field, where the default stack could draw the caret at the edge.
        let editor = DraftTextView(usingTextLayoutManager: false)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: Self.margin, height: Self.margin)
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
        scroll.documentView = editor
        ThinScroller.install(in: scroll)
        if let layoutManager = editor.layoutManager, let container = editor.textContainer { layoutManager.ensureLayout(for: container) }
        apply(to: editor, coordinator: context.coordinator)
        if focusRequest != 0 { editor.requestFocus() }
        context.coordinator.focusRequest = focusRequest
        return scroll
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
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            if focusRequest != 0 { editor.requestFocus() }
        }
    }

    private func apply(to editor: DraftTextView, coordinator: Coordinator) {
        editor.onFocus = onFocus
        editor.onSend = onSend
        editor.onTab = onTab
        editor.conversationID = conversationID
        DraftTextView.register(editor, for: conversationID)
        if editor.placeholder != placeholder { editor.placeholder = placeholder; editor.needsDisplay = true }
        editor.onHeightChange = { [weak coordinator] value in coordinator?.report(value) }
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityPlaceholderValue(placeholder)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        var focusRequest = 0
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func report(_ value: CGFloat) {
            let clamped = min(max(value.rounded(.up), ComposerEditor.minimumHeight), ComposerEditor.maximumHeight)
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
    var onHeightChange: ((CGFloat) -> Void)?
    var conversationID = ""
    var placeholder = ""
    private var pendingFocus = false
    private var lastReportedWidth: CGFloat = 0

    // Each tile's editor by conversation, so the emoji button next to a field can reach that field.
    private final class WeakEditor { weak var view: DraftTextView?; init(_ view: DraftTextView) { self.view = view } }
    @MainActor private static var registry: [String: WeakEditor] = [:]
    @MainActor static func register(_ editor: DraftTextView, for conversationID: String) {
        guard !conversationID.isEmpty else { return }
        registry = registry.filter { $0.value.view != nil }
        registry[conversationID] = WeakEditor(editor)
    }
    @MainActor static func editor(for conversationID: String) -> DraftTextView? { registry[conversationID]?.view }

    /// Opens the system Emoji & Symbols palette; a chosen emoji is inserted at this field's caret.
    func showEmojiPicker() {
        requestFocus()
        NSApp.orderFrontCharacterPalette(nil)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !event.modifierFlags.contains(.shift), !hasMarkedText() {
            if !event.isARepeat { onSend?() }
            return
        }
        super.keyDown(with: event)
    }
    // Tab and Shift–Tab move between tiles instead of inserting a tab character.
    override func insertTab(_ sender: Any?) { onTab?(true) }
    override func insertBacktab(_ sender: Any?) { onTab?(false) }

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
        guard pendingFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.requestFocus() }
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
    func requestFocus() {
        guard let window else { pendingFocus = true; return }
        pendingFocus = false
        // Already typing here: leave the caret where it is.
        guard window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }
    override func scrollRangeToVisible(_ range: NSRange) {
        // Nothing to bring into view while the whole draft fits; scrolling would only shift the text.
        if let clip = enclosingScrollView?.contentSize, frame.height <= clip.height + 0.5 { return }
        super.scrollRangeToVisible(range)
    }

    /// Height of the laid-out text. An empty field measures as exactly one line, so every tile's
    /// composer is the same height whatever the layout manager reports for its empty line.
    private var textHeight: CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: 12))
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
