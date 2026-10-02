import SwiftUI
import AppKit

/// Each tile owns a separate NSTextView. Send is dispatched from that editor's
/// keyDown handler, so Return cannot invoke a different tile's default button.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    var focusRequest: Int
    let onFocus: () -> Void
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = DraftTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 42))
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 12)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 7, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.string = text
        editor.onFocus = onFocus
        editor.onSend = onSend
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? DraftTextView else { return }
        editor.onFocus = onFocus; editor.onSend = onSend
        editor.setAccessibilityLabel(accessibilityLabel)
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            editor.window?.makeFirstResponder(editor)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        var focusRequest = 0
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

final class DraftTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onSend: (() -> Void)?
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
}
