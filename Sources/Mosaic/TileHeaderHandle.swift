import SwiftUI
import AppKit

/// The tile header's mouse handling, done in AppKit so it keeps working inside the window's title
/// bar strip. macOS asks the view under the pointer whether a press should move the window; this view
/// says no, so presses reach it (the same mechanism Electron apps use to put controls on the row with
/// the window buttons). It drags the tile, focuses it on a click, and owns the close button.
struct TileHeaderHandle: NSViewRepresentable {
    var draggable: Bool
    var closeLabel: String
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onClick: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> HandleView { let view = HandleView(); apply(view); return view }
    func updateNSView(_ view: HandleView, context: Context) { apply(view) }
    private func apply(_ view: HandleView) {
        view.onDragChanged = onDragChanged; view.onDragEnded = onDragEnded; view.onClick = onClick; view.onClose = onClose
        view.closeButton.setAccessibilityLabel(closeLabel)
        if view.draggable != draggable {
            view.draggable = draggable
            view.window?.invalidateCursorRects(for: view)
        }
    }

    final class HandleView: NSView {
        var draggable = true
        var onDragChanged: ((CGSize) -> Void)?
        var onDragEnded: (() -> Void)?
        var onClick: (() -> Void)?
        var onClose: (() -> Void)?
        let closeButton = NSButton()
        private var pressOrigin: NSPoint?
        private var dragging = false
        private static let closeSize: CGFloat = 22
        private static let closeInset: CGFloat = 10

        override init(frame: NSRect) {
            super.init(frame: frame)
            closeButton.isBordered = false
            closeButton.imagePosition = .imageOnly
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            closeButton.contentTintColor = .labelColor
            closeButton.toolTip = "Close tile — your draft is kept"
            closeButton.target = self
            closeButton.action = #selector(close)
            addSubview(closeButton)
            placeCloseButton()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            placeCloseButton()
        }
        private func placeCloseButton() {
            closeButton.frame = NSRect(x: bounds.width - Self.closeInset - Self.closeSize, y: (bounds.height - Self.closeSize) / 2,
                                       width: Self.closeSize, height: Self.closeSize)
        }
        override func resetCursorRects() {
            if draggable { addCursorRect(bounds, cursor: .openHand) }
            addCursorRect(closeButton.frame, cursor: .arrow)
        }
        @objc private func close() { onClose?() }

        override func mouseDown(with event: NSEvent) {
            if dragging { dragging = false; NSCursor.pop(); onDragEnded?() } // a release that never arrived
            pressOrigin = event.locationInWindow
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin = pressOrigin else { return }
            let location = event.locationInWindow
            // Window coordinates grow upward; the tile canvas grows downward.
            let translation = CGSize(width: location.x - origin.x, height: origin.y - location.y)
            if !dragging {
                guard draggable, hypot(translation.width, translation.height) >= 4 else { return }
                dragging = true
                NSCursor.closedHand.push()
            }
            onDragChanged?(translation)
        }
        override func mouseUp(with event: NSEvent) {
            defer { pressOrigin = nil }
            if dragging { dragging = false; NSCursor.pop(); onDragEnded?() }
            else if pressOrigin != nil { onClick?() }
        }
    }
}

/// A click target backed by AppKit, for controls that must work inside the title bar strip (the
/// focus-mode chips). It covers the whole frame it is given, declines window dragging, and shows a
/// pointing hand.
struct ClickHandle: NSViewRepresentable {
    var label: String
    let onClick: () -> Void

    func makeNSView(context: Context) -> HandleView { let view = HandleView(); apply(view); return view }
    func updateNSView(_ view: HandleView, context: Context) { apply(view) }
    private func apply(_ view: HandleView) {
        view.onClick = onClick
        view.setAccessibilityLabel(label)
    }

    final class HandleView: NSView {
        var onClick: (() -> Void)?
        private var pressed = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func accessibilityPerformPress() -> Bool { onClick?(); return true }
        override func mouseDown(with event: NSEvent) { pressed = true }
        override func mouseUp(with event: NSEvent) {
            defer { pressed = false }
            guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick?()
        }
    }
}
