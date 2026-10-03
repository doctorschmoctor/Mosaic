import SwiftUI
import AppKit

/// The tile header's mouse handling, done in AppKit so it keeps working inside the window's title
/// bar strip. macOS asks the view under the pointer whether a press should move the window; this view
/// says no, so presses reach it (the same mechanism Electron apps use to put controls on the row with
/// the window buttons). It drags the tile, focuses it on a click, and owns the close button's hit area;
/// the × glyph itself is drawn by SwiftUI on top, so it always looks like the rest of the header.
struct TileHeaderHandle: NSViewRepresentable {
    /// Size of the close target and its distance from the header's trailing edge; the SwiftUI glyph
    /// uses the same numbers so the hit area and the drawing coincide.
    static let closeSize: CGFloat = 22
    static let closeInset: CGFloat = 10

    var draggable: Bool
    var closeLabel: String
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onClick: () -> Void
    let onClose: () -> Void
    var onCloseHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> HandleView { let view = HandleView(); apply(view); return view }
    func updateNSView(_ view: HandleView, context: Context) { apply(view) }
    /// A background view takes exactly the size it is offered; never let SwiftUI consult Auto Layout
    /// for it (fitting-size queries during a window's constraint pass were part of a crash loop).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HandleView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    private func apply(_ view: HandleView) {
        view.onDragChanged = onDragChanged; view.onDragEnded = onDragEnded; view.onClick = onClick; view.onClose = onClose
        view.onCloseHover = onCloseHover
        view.closeLabel = closeLabel
        if view.draggable != draggable {
            view.draggable = draggable
            view.window?.invalidateCursorRects(for: view)
        }
    }

    /// Where the close target sits for a header of the given size (flipped coordinates).
    static func closeRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - closeInset - closeSize, y: bounds.midY - closeSize / 2, width: closeSize, height: closeSize)
    }

    final class HandleView: NSView {
        var draggable = true
        var onDragChanged: ((CGSize) -> Void)?
        var onDragEnded: (() -> Void)?
        var onClick: (() -> Void)?
        var onClose: (() -> Void)?
        var onCloseHover: ((Bool) -> Void)?
        var closeLabel = "Close tile" { didSet { closeElement.setAccessibilityLabel(closeLabel) } }
        private var pressOrigin: NSPoint?
        private var pressedClose = false
        private var dragging = false
        private var closeHovered = false { didSet { if closeHovered != oldValue { onCloseHover?(closeHovered) } } }
        private var tracking: NSTrackingArea?
        private let closeElement = PressableAccessibilityElement()

        override init(frame: NSRect) {
            super.init(frame: frame)
            closeElement.setAccessibilityRole(.button)
            closeElement.setAccessibilityLabel(closeLabel)
            closeElement.setAccessibilityParent(self)
            closeElement.onPress = { [weak self] in self?.onClose?() }
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityChildren([closeElement])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var closeRect: CGRect { TileHeaderHandle.closeRect(in: bounds) }
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            if draggable { addCursorRect(bounds, cursor: .openHand) }
            addCursorRect(closeRect, cursor: .arrow)
        }
        override func layout() {
            super.layout()
            closeElement.setAccessibilityFrameInParentSpace(closeRect)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: closeRect, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { closeHovered = closeRect.contains(convert(event.locationInWindow, from: nil)) }
        override func mouseMoved(with event: NSEvent) { closeHovered = closeRect.contains(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { closeHovered = false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { closeHovered = false }
        }

        /// True when the point (in this view's coordinates) is on the close target.
        func isOnClose(_ point: NSPoint) -> Bool { closeRect.contains(point) }

        override func mouseDown(with event: NSEvent) {
            if dragging { dragging = false; NSCursor.pop(); onDragEnded?() } // a release that never arrived
            pressOrigin = event.locationInWindow
            pressedClose = isOnClose(convert(event.locationInWindow, from: nil))
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin = pressOrigin, !pressedClose else { return }
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
            defer { pressOrigin = nil; pressedClose = false }
            if dragging { dragging = false; NSCursor.pop(); onDragEnded?(); return }
            guard pressOrigin != nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            if pressedClose {
                // Like a button: the press must end on the target to count.
                if isOnClose(point) { onClose?() }
            } else if bounds.contains(point) { onClick?() }
        }
        override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    }
}

/// An accessibility-only element (a child with no view of its own) that can be pressed by VoiceOver.
final class PressableAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func isAccessibilityElement() -> Bool { true }
}
