import SwiftUI
import AppKit

/// An overlay scroller that draws the same slim knob whether idle, hovered, or being dragged.
/// The system scroller grows a track and a thicker knob under the pointer; this one never does.
final class ThinScroller: NSScroller {
    static let knobWidth: CGFloat = 6
    static let margin: CGFloat = 3
    /// While the pointer is swiping sideways (a list row's swipe action), the scroller draws nothing:
    /// AppKit flashes the vertical scroller on any scroll gesture, including horizontal ones.
    var isSuppressed = false { didSet { if isSuppressed != oldValue { needsDisplay = true } } }

    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        guard !isSuppressed else { return }
        let knob = rect(for: .knob)
        let vertical = bounds.height >= bounds.width
        let frame = vertical
            ? NSRect(x: bounds.maxX - Self.margin - Self.knobWidth, y: knob.minY, width: Self.knobWidth, height: knob.height)
            : NSRect(x: knob.minX, y: bounds.maxY - Self.margin - Self.knobWidth, width: knob.width, height: Self.knobWidth)
        guard frame.width > 0, frame.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: frame, xRadius: Self.knobWidth / 2, yRadius: Self.knobWidth / 2).fill()
    }

    /// Whether a sideways swipe (a list row's swipe action) is under way over the scroll view, or
    /// has left its action showing. It ends when the swipe is closed again (a sideways gesture
    /// back, or one too short to have opened the action), or with the next click, key press or
    /// vertical scroll. Reported through `onSwipeModeChange`.
    private(set) var isSwiping = false {
        didSet {
            guard isSwiping != oldValue else { return }
            onSwipeModeChange?(isSwiping)
            if !isSwiping { NotificationCenter.default.post(name: .thinScrollerSwipeEnded, object: self) }
        }
    }
    var onSwipeModeChange: ((Bool) -> Void)?
    /// A sideways gesture that travels less than this to the left is taken to have snapped back
    /// without opening the action.
    static let swipeOpenTravel: CGFloat = 40

    private var observer: NSObjectProtocol?
    private var swipeMonitor: Any?
    /// The direction a trackpad gesture settled on, held for the rest of that gesture: a finger
    /// that wanders a little during a sideways swipe must not flip the state back and forth.
    private var gestureIsSideways: Bool?
    /// The gesture's horizontal travel so far (negative to the left).
    private var gestureTravelX: CGFloat = 0
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
    }

    /// Watches the gestures over `scrollView` (the sidebar list): a sideways swipe hides the knob
    /// and starts swipe mode; a click, a key or a vertical scroll ends it.
    func watchSwipes(in scrollView: NSScrollView) {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) {
            [weak self, weak scrollView] event in
            guard let self, let scrollView, let window = scrollView.window, event.window === window else { return event }
            guard event.type == .scrollWheel else { self.isSwiping = false; return event }
            let inside = scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
            guard inside else { return event }
            self.track(event)
            self.needsDisplay = true
            return event
        }
    }
    /// Classifies one scroll event of a gesture over the watched scroll view.
    func track(_ event: NSEvent) {
        track(phase: event.phase, momentumPhase: event.momentumPhase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
    }
    func track(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat) {
        if phase == .began { gestureIsSideways = nil; gestureTravelX = 0 }
        let inGesture = phase == .began || phase == .changed || momentumPhase == .began
        if inGesture {
            gestureTravelX += deltaX
            if gestureIsSideways == nil, deltaX != 0 || deltaY != 0 { gestureIsSideways = abs(deltaX) > abs(deltaY) }
            guard let sideways = gestureIsSideways else { return }
            isSuppressed = sideways
            isSwiping = sideways
        } else if phase == .ended || phase == .cancelled {
            // A sideways gesture back to the right closes the action; a short one never opened it.
            if gestureIsSideways == true, gestureTravelX > -Self.swipeOpenTravel { isSwiping = false }
        } else if phase.isEmpty, momentumPhase.isEmpty {
            // A mouse wheel: no gesture, nothing sideways.
            isSuppressed = false
            isSwiping = false
        }
    }

    static func install(in scrollView: NSScrollView) {
        guard !(scrollView.verticalScroller is ThinScroller) else { return }
        let scroller = ThinScroller()
        scroller.controlSize = .small
        scrollView.verticalScroller = scroller
        scrollView.scrollerStyle = .overlay
        // The knob is drawn into a layer that some scroll views (a List's) do not invalidate when
        // their content moves, which left the scroller invisible while scrolling. Redraw on every
        // scroll of the clip view.
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scroller.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak scroller] _ in
            scroller?.needsDisplay = true
        }
    }
}

/// Keeps a conversation's scroll position meaningful while its content and its frame change: the
/// distance from the bottom is preserved, so a list that shows the newest message stays on it when
/// a tile is resized, the layout switches, history arrives or a message is added, and a list the
/// reader scrolled up stays on the same rows when older messages load above them. This is done in
/// AppKit, synchronously with the size change, so nothing is drawn at an interim position first.
final class ScrollPinner: NSObject {
    /// Within this many points of the end the list counts as following the newest message.
    static let nearBottomTolerance: CGFloat = 24
    private(set) weak var scrollView: NSScrollView?
    var onNearBottomChanged: ((Bool) -> Void)?
    private(set) var distanceFromBottom: CGFloat = 0
    private(set) var isNearBottom = true {
        didSet {
            guard isNearBottom != oldValue else { return }
            // Reported on the next turn: the change can be noticed during a layout pass, and SwiftUI
            // state must not change in the middle of one.
            let value = isNearBottom
            DispatchQueue.main.async { [weak self] in self?.onNearBottomChanged?(value) }
        }
    }
    private var lastClipSize = CGSize.zero
    private var lastDocumentSize = CGSize.zero
    private var observers: [NSObjectProtocol] = []
    private var adjusting = false

    deinit { detach() }

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        // Views post these synchronously on the main thread. A scroll changes the clip view's
        // bounds; a resize changes its frame (and the document's frame when content changes).
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            self?.clipBoundsChanged()
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            self?.sizeChanged()
        })
        if let document = scrollView.documentView {
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
                self?.sizeChanged()
            })
        }
        lastClipSize = clip.bounds.size
        lastDocumentSize = scrollView.documentView?.frame.size ?? .zero
        // A list starts on its newest message.
        distanceFromBottom = 0
        isNearBottom = true
        sizeChanged()
    }
    func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        scrollView = nil
    }

    private var geometry: (clip: NSClipView, documentHeight: CGFloat, flipped: Bool)? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        return (scrollView.contentView, document.frame.height, document.isFlipped)
    }
    /// The distance between the visible area's bottom edge and the content's end.
    private func currentDistance() -> CGFloat? {
        guard let geometry else { return nil }
        let (clip, documentHeight, flipped) = geometry
        return max(0, flipped ? documentHeight - clip.bounds.maxY : clip.bounds.minY)
    }

    private func clipBoundsChanged() {
        guard !adjusting, let scrollView else { return }
        let clipSize = scrollView.contentView.bounds.size
        let documentSize = scrollView.documentView?.frame.size ?? .zero
        if clipSize != lastClipSize || documentSize != lastDocumentSize { sizeChanged() } else { remember() }
    }
    /// The viewport or the content changed size: put the content back at the remembered distance.
    private func sizeChanged() {
        guard !adjusting, let geometry else { return }
        let (clip, documentHeight, flipped) = geometry
        lastClipSize = clip.bounds.size
        lastDocumentSize = scrollView?.documentView?.frame.size ?? .zero
        let maximum = max(0, documentHeight - clip.bounds.height)
        let distance = min(distanceFromBottom, maximum)
        let targetY = flipped ? maximum - distance : distance
        if abs(clip.bounds.origin.y - targetY) > 0.5 { scroll(toY: targetY) }
    }
    private func remember() {
        guard let distance = currentDistance() else { return }
        distanceFromBottom = distance
        isNearBottom = distance <= Self.nearBottomTolerance
    }
    private func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        adjusting = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        adjusting = false
    }
    /// Shows the newest message and follows it from now on.
    func scrollToBottom() {
        guard let geometry else { return }
        let (clip, documentHeight, flipped) = geometry
        let maximum = max(0, documentHeight - clip.bounds.height)
        scroll(toY: flipped ? maximum : 0)
        distanceFromBottom = 0
        isNearBottom = true
    }
}

extension Notification.Name {
    /// A ThinScroller's sideways swipe ended (the row's action closed); rows re-check the pointer.
    static let thinScrollerSwipeEnded = Notification.Name("Mosaic.thinScrollerSwipeEnded")
}

/// Placed inside a SwiftUI ScrollView or List, finds the AppKit scroll view that hosts it and
/// gives it a ThinScroller. With `hidesForHorizontalSwipes`, a sideways trackpad gesture over the
/// scroll view (a row's swipe action) keeps the scroller from showing. As a list row's background
/// it also reports whether the pointer is over the row (`onPointer`), from AppKit tracking of the
/// row's own frame: SwiftUI's hover tracking lives on the row content, which a swipe slides away
/// from under the pointer and does not always report again. Invisible and never part of hit
/// testing or layout.
struct ThinScrollerInstaller: NSViewRepresentable {
    var hidesForHorizontalSwipes = false
    /// Called as a sideways swipe over the scroll view begins and ends (see `ThinScroller.isSwiping`).
    var onSwipeModeChange: ((Bool) -> Void)? = nil
    /// Called as the pointer enters (true) and leaves (false) the view's frame, and again when a
    /// swipe ends, so the row under the pointer is known the moment the swipe closes.
    var onPointer: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> InstallerView { let view = InstallerView(); configure(view); return view }
    func updateNSView(_ view: InstallerView, context: Context) { configure(view); view.install() }
    private func configure(_ view: InstallerView) {
        view.watchesSwipes = hidesForHorizontalSwipes
        view.onSwipeModeChange = onSwipeModeChange
        view.onPointer = onPointer
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InstallerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class InstallerView: NSView {
        var watchesSwipes = false
        var onSwipeModeChange: ((Bool) -> Void)?
        var onPointer: ((Bool) -> Void)?
        private weak var scrollView: NSScrollView?
        private var trackingArea: NSTrackingArea?
        private var swipeObserver: NSObjectProtocol?

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.install() }
            if let swipeObserver { NotificationCenter.default.removeObserver(swipeObserver); self.swipeObserver = nil }
            guard window != nil else { return }
            swipeObserver = NotificationCenter.default.addObserver(forName: .thinScrollerSwipeEnded, object: nil, queue: nil) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let scroller = notification.object as? NSScroller, scroller.window === self.window else { return }
                    self.reportPointer()
                }
            }
        }
        deinit { if let swipeObserver { NotificationCenter.default.removeObserver(swipeObserver) } }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }
        override func mouseEntered(with event: NSEvent) { onPointer?(true) }
        override func mouseExited(with event: NSEvent) { onPointer?(false) }
        /// Tells the row whether the pointer is over it right now.
        func reportPointer() {
            guard let window else { return }
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            onPointer?(bounds.contains(local))
        }

        func install() {
            var view: NSView? = superview
            while let current = view {
                if let found = current as? NSScrollView {
                    ThinScroller.install(in: found)
                    scrollView = found
                    if watchesSwipes, let scroller = found.verticalScroller as? ThinScroller {
                        scroller.watchSwipes(in: found)
                        if let onSwipeModeChange { scroller.onSwipeModeChange = onSwipeModeChange }
                    }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// Placed inside a conversation's SwiftUI ScrollView, finds the AppKit scroll view that hosts it,
/// gives it a ThinScroller and a ScrollPinner. Invisible and never part of hit testing or layout.
struct MessageScrollSupport: NSViewRepresentable {
    /// Changes when the reader asks for the newest message.
    var scrollToBottomRequest: Int
    var onNearBottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.pinner = context.coordinator.pinner
        context.coordinator.pinner.onNearBottomChanged = onNearBottomChanged
        context.coordinator.request = scrollToBottomRequest
        return view
    }
    func updateNSView(_ view: InstallerView, context: Context) {
        context.coordinator.pinner.onNearBottomChanged = onNearBottomChanged
        view.install()
        if scrollToBottomRequest != context.coordinator.request {
            context.coordinator.request = scrollToBottomRequest
            DispatchQueue.main.async { [pinner = context.coordinator.pinner] in pinner.scrollToBottom() }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InstallerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class Coordinator {
        let pinner = ScrollPinner()
        var request = 0
    }

    final class InstallerView: NSView {
        var pinner: ScrollPinner?
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.install() }
        }
        func install() {
            var view: NSView? = superview
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    ThinScroller.install(in: scrollView)
                    pinner?.attach(to: scrollView)
                    return
                }
                view = current.superview
            }
        }
    }
}
