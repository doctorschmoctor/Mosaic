import SwiftUI
import AppKit

/// The tile header's mouse handling, done in AppKit. It drags the tile, focuses it on a click, and
/// owns the close button's hit area, telling the three apart like a real title bar. It declines window
/// dragging (`mouseDownCanMoveWindow` is false), so a press on a header never moves the window. It is
/// laid over the header, transparent, drawing nothing: the × glyph and the name are SwiftUI views
/// drawn underneath, and only this handle is hit-tested. The glyph's frame matches `closeRect`.
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
    /// The header's menu (right-click or Control-click): actions on this tile.
    var menuItems: [MenuItem] = []

    /// One entry in the header's menu.
    struct MenuItem {
        var title: String
        /// Asked when the menu opens (so the header need not re-render as it changes).
        var isEnabled: () -> Bool = { true }
        var action: () -> Void
        /// A line between this item and the one before it.
        var separatedAbove = false
    }

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
        view.menuItems = menuItems
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
        var menuItems: [MenuItem] = []
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
        /// True between a press and its release.
        var isTracking: Bool { pressOrigin != nil }

        // The press is followed with a local event monitor rather than mouseDragged/mouseUp alone:
        // raising the dragged tile re-inserts this view in the window's view tree, and AppKit stops
        // delivering drag events to a view that left the window mid-press. The monitor keeps
        // receiving them, so the first tiles in the order drag as freely as the last one.
        private var monitor: Any?
        private weak var pressWindow: NSWindow?
        private weak var handledEvent: NSEvent?

        /// The tile's actions, for a right-click or Control-click on the header.
        override func menu(for event: NSEvent) -> NSMenu? { actionsMenu() }
        private func actionsMenu() -> NSMenu? {
            guard !menuItems.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in menuItems {
                if item.separatedAbove, !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(ActionMenuItem(item.title, enabled: item.isEnabled(), action: item.action))
            }
            return menu
        }
        override func accessibilityPerformShowMenu() -> Bool {
            guard let menu = actionsMenu() else { return false }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
            return true
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = actionsMenu() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
            if dragging { dragging = false; NSCursor.pop(); onDragEnded?() } // a release that never arrived
            endTracking()
            pressOrigin = event.locationInWindow
            pressWindow = event.window ?? window
            pressedClose = isOnClose(convert(event.locationInWindow, from: nil))
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.pressWindow else { return event }
                self.handledEvent = event
                switch event.type {
                case .leftMouseDragged: self.drag(to: event.locationInWindow)
                case .leftMouseUp: self.release(at: event.locationInWindow)
                default: break
                }
                return event
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard event !== handledEvent else { return }
            drag(to: event.locationInWindow)
        }
        override func mouseUp(with event: NSEvent) {
            guard event !== handledEvent else { return }
            release(at: event.locationInWindow)
        }
        private func endTracking() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressWindow = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private func drag(to location: NSPoint) {
            guard let origin = pressOrigin, !pressedClose else { return }
            // Window coordinates grow upward; the tile canvas grows downward.
            let translation = CGSize(width: location.x - origin.x, height: origin.y - location.y)
            if !dragging {
                guard draggable, hypot(translation.width, translation.height) >= 4 else { return }
                dragging = true
                NSCursor.closedHand.push()
            }
            onDragChanged?(translation)
        }
        private func release(at location: NSPoint) {
            defer { pressOrigin = nil; pressedClose = false; endTracking() }
            if dragging { dragging = false; NSCursor.pop(); onDragEnded?(); return }
            guard pressOrigin != nil else { return }
            let point = convert(location, from: nil)
            if pressedClose {
                // Like a button: the press must end on the target to count.
                if isOnClose(point) { onClose?() }
            } else if bounds.contains(point) { onClick?() }
        }
        override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { handler() }
}

/// An accessibility-only element (a child with no view of its own) that can be pressed by VoiceOver.
final class PressableAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func isAccessibilityElement() -> Bool { true }
}
