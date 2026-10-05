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
    private(set) var isSwiping = false { didSet { if isSwiping != oldValue { onSwipeModeChange?(isSwiping) } } }
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
        // The knob is also shown for a moment on each scroll, whichever way the content moved (a
        // wheel, a trackpad, the keyboard, a scrollTo): overlay scrollers otherwise show only for
        // scroll events the scroll view itself handled, and some SwiftUI scroll views take those.
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scroller.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak scroller, weak scrollView] _ in
            MainActor.assumeIsolated {
                scroller?.needsDisplay = true
                scrollView?.flashScrollers()
            }
        }
    }
}

/// What a conversation's scroll view currently holds, by message identity: enough to tell an
/// append (a new message at the end) from a prepend (older history above) when the content
/// changes size, which pixel arithmetic alone cannot.
struct ThreadContent: Equatable {
    var first: String?
    var last: String?
    var count = 0
}

/// Where each message row sits within the thread's content, in the content's own coordinates
/// (which do not move when the thread scrolls). Rows report their frames as layout places them;
/// nothing observes this class, so updates cost no view invalidation. The pinner uses it to put
/// the same message back at the same place after a reflow (a width change, a zoom change).
final class ThreadRowRegistry {
    private(set) var frames: [String: CGRect] = [:]
    func update(_ id: String, _ frame: CGRect) { frames[id] = frame }
    /// The row at this offset from the content's top, else the nearest one below it.
    func row(at y: CGFloat) -> (id: String, frame: CGRect)? {
        var below: (id: String, frame: CGRect)?
        for (id, frame) in frames {
            if frame.minY <= y && y < frame.maxY { return (id, frame) }
            if frame.minY >= y, below == nil || frame.minY < below!.frame.minY { below = (id, frame) }
        }
        return below
    }
}

/// Keeps a conversation's scroll position meaningful while its content and its frame change.
/// Near the bottom, the list follows the newest message (tail mode). Scrolled up, the reader is
/// reading history, and what they are reading stays put: a new message appended below moves
/// nothing, older messages prepended above keep the same rows in view, a viewport resize keeps
/// the row at the top of the view, and a reflow (width or zoom change) puts the remembered
/// message back at its remembered place using the row registry. Pixel adjustments happen in
/// AppKit, synchronously with the size change, so nothing is drawn at an interim position first;
/// the reflow correction lands one turn later, once layout has reported the new row frames.
final class ScrollPinner: NSObject {
    /// Within this many points of the end the list counts as following the newest message.
    static let nearBottomTolerance: CGFloat = 24
    private(set) weak var scrollView: NSScrollView?
    var onNearBottomChanged: ((Bool) -> Void)?
    /// The reader scrolled to within `nearTopDistance` of the top of what is loaded: time to load
    /// earlier messages. Called for scrolls only (not for content changes), on the next turn.
    var onNearTop: (() -> Void)?
    static let nearTopDistance: CGFloat = 600
    private(set) var distanceFromBottom: CGFloat = 0
    /// The distance between the visible area's top edge and the content's top.
    private(set) var distanceFromTop: CGFloat = 0
    /// Row frames by message, for reflow anchoring; nil outside a message thread.
    var registry: ThreadRowRegistry?
    /// The message at the top of the view and how far into it the view starts, captured whenever
    /// the reader scrolls; what a reflow puts back.
    private(set) var anchor: (id: String, offset: CGFloat)?
    /// What the thread holds now, and what the next layout will hold (set by SwiftUI before
    /// AppKit lays the new content out, so the size change can be classified when it arrives).
    private var content = ThreadContent()
    private var pendingContent: ThreadContent?
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
    /// The content the next layout pass will show. Called from the SwiftUI update, which runs
    /// before AppKit resizes the document for it.
    func expect(_ next: ThreadContent) {
        guard next != (pendingContent ?? content) else { return }
        pendingContent = next
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
    /// The visible area's top edge, as an offset from the content's top.
    private func currentTop() -> CGFloat? {
        guard let geometry else { return nil }
        let (clip, documentHeight, flipped) = geometry
        return max(0, flipped ? clip.bounds.minY : documentHeight - clip.bounds.maxY)
    }

    private func clipBoundsChanged() {
        guard !adjusting, let scrollView else { return }
        let clipSize = scrollView.contentView.bounds.size
        let documentSize = scrollView.documentView?.frame.size ?? .zero
        if clipSize != lastClipSize || documentSize != lastDocumentSize { sizeChanged() } else { remember() }
    }
    /// What kind of change a size change was, from the content descriptors around it.
    enum ContentChange { case none, append, prepend, mixed }
    static func classify(from old: ThreadContent, to new: ThreadContent) -> ContentChange {
        guard old.count > 0, new.count > 0, new != old else { return .none }
        if old.first == new.first, old.last == new.last { return .none }
        if old.first == new.first { return .append }
        if old.last == new.last { return .prepend }
        return .mixed
    }

    /// The viewport or the content changed size: keep the reader's place.
    private func sizeChanged() {
        guard !adjusting, let geometry else { return }
        let (clip, documentHeight, flipped) = geometry
        let documentGrewOrShrank = abs(documentHeight - lastDocumentSize.height) > 0.5
        let widthChanged = abs(clip.bounds.width - lastClipSize.width) > 0.5
        let change = pendingContent.map { Self.classify(from: content, to: $0) } ?? ContentChange.none
        if let pendingContent { content = pendingContent; self.pendingContent = nil }
        lastClipSize = clip.bounds.size
        lastDocumentSize = scrollView?.documentView?.frame.size ?? .zero
        let maximum = max(0, documentHeight - clip.bounds.height)
        if isNearBottom {
            // Tail mode: stay on the newest message through everything.
            let targetY = flipped ? maximum : 0
            if abs(clip.bounds.origin.y - targetY) > 0.5 { scroll(toY: targetY) }
            distanceFromBottom = 0
            distanceFromTop = currentTop() ?? 0
            return
        }
        func keepTop() {
            let top = min(distanceFromTop, maximum)
            let targetY = flipped ? top : maximum - top
            if abs(clip.bounds.origin.y - targetY) > 0.5 { scroll(toY: targetY) }
        }
        func keepBottom() {
            let distance = min(distanceFromBottom, maximum)
            let targetY = flipped ? maximum - distance : distance
            if abs(clip.bounds.origin.y - targetY) > 0.5 { scroll(toY: targetY) }
        }
        switch change {
        case .append:
            // New messages below what is being read: nothing in view moves.
            keepTop()
        case .prepend:
            // Older messages above: the same rows stay in view.
            keepBottom()
        case .mixed:
            keepBottom()
            scheduleAnchorCorrection()
        case .none:
            if documentGrewOrShrank || widthChanged {
                // The content itself changed height with no classification: a reflow (width or
                // zoom change), or an unclassified update. Hold the bottom distance for now and
                // put the remembered message back once layout has reported the new row frames.
                keepBottom()
                scheduleAnchorCorrection()
            } else {
                // Only the viewport changed (a tile resize): the row at the top stays the row at the top.
                keepTop()
            }
        }
        distanceFromBottom = currentDistance() ?? distanceFromBottom
        distanceFromTop = currentTop() ?? distanceFromTop
    }
    private func remember() {
        guard let distance = currentDistance() else { return }
        distanceFromBottom = distance
        distanceFromTop = currentTop() ?? 0
        isNearBottom = distance <= Self.nearBottomTolerance
        if distanceFromTop <= Self.nearTopDistance, !isNearBottom, let onNearTop {
            DispatchQueue.main.async { onNearTop() }
        }
        // The row under the view's top edge, for putting the same message back after a reflow.
        if !isNearBottom, let registry, let top = currentTop(), let row = registry.row(at: top) {
            anchor = (row.id, top - row.frame.minY)
        } else if isNearBottom {
            anchor = nil
        }
    }
    /// After a reflow, put the remembered message back where it was. Runs one turn after the
    /// synchronous adjustment, once SwiftUI layout has reported the new row frames.
    private func scheduleAnchorCorrection() {
        guard anchor != nil, registry != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.correctToAnchor() }
    }
    private func correctToAnchor() {
        guard !isNearBottom, let anchor, let registry, let frame = registry.frames[anchor.id],
              let geometry else { return }
        let (clip, documentHeight, flipped) = geometry
        let maximum = max(0, documentHeight - clip.bounds.height)
        // The offset into the row is kept, bounded to the row as it is now.
        let target = min(max(0, frame.minY + min(anchor.offset, max(0, frame.height - 1))), maximum)
        let targetY = flipped ? target : maximum - target
        if abs(clip.bounds.origin.y - targetY) > 0.5 { scroll(toY: targetY) }
        distanceFromBottom = currentDistance() ?? distanceFromBottom
        distanceFromTop = currentTop() ?? distanceFromTop
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
        distanceFromTop = currentTop() ?? 0
        isNearBottom = true
        anchor = nil
    }
}

/// Placed inside a SwiftUI ScrollView or List, finds the AppKit scroll view that hosts it and
/// gives it a ThinScroller. With `hidesForHorizontalSwipes`, a sideways trackpad gesture over the
/// scroll view (a row's swipe action) keeps the scroller from showing. Invisible and never part
/// of hit testing or layout.
struct ThinScrollerInstaller: NSViewRepresentable {
    var hidesForHorizontalSwipes = false
    /// Called as a sideways swipe over the scroll view begins and ends (see `ThinScroller.isSwiping`).
    var onSwipeModeChange: ((Bool) -> Void)? = nil
    /// Hands over the AppKit scroll view once it is found.
    var onScrollView: ((NSScrollView) -> Void)? = nil
    /// Where the scroller's track starts and ends, inside the scroll view's edges (to line it up
    /// with content that is inset from them).
    var scrollerInsets: NSEdgeInsets? = nil

    func makeNSView(context: Context) -> InstallerView { let view = InstallerView(); configure(view); return view }
    func updateNSView(_ view: InstallerView, context: Context) { configure(view); view.install() }
    private func configure(_ view: InstallerView) {
        view.watchesSwipes = hidesForHorizontalSwipes
        view.onSwipeModeChange = onSwipeModeChange
        view.onScrollView = onScrollView
        view.scrollerInsets = scrollerInsets
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InstallerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class InstallerView: NSView {
        var watchesSwipes = false
        var onSwipeModeChange: ((Bool) -> Void)?
        var onScrollView: ((NSScrollView) -> Void)?
        var scrollerInsets: NSEdgeInsets?
        private weak var scrollView: NSScrollView?

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        func install() {
            var view: NSView? = superview
            while let current = view {
                if let found = current as? NSScrollView {
                    ThinScroller.install(in: found)
                    scrollView = found
                    if let scrollerInsets, !NSEdgeInsetsEqual(found.scrollerInsets, scrollerInsets) { found.scrollerInsets = scrollerInsets }
                    onScrollView?(found)
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

/// Keeps the conversation list on its top conversation. A message that moves a conversation to
/// the top while the list is at the top keeps the list at the top: a List otherwise holds on to
/// the row that was first, leaving the new arrival just above the visible area. A list scrolled
/// down on purpose stays where it is.
@MainActor final class ListTopPin {
    private weak var scrollView: NSScrollView?
    func attach(_ scrollView: NSScrollView) { if self.scrollView !== scrollView { self.scrollView = scrollView } }

    /// After the list changed its first row from `oldFirst`: whether the list was at the top, which
    /// is when the row that was first now starts at the top edge of the visible area (the list
    /// kept it there) or the list is at the top already.
    func wasAtTop(oldFirst: String, in order: [String]) -> Bool {
        guard let scrollView, let table = scrollView.documentView as? NSTableView,
              let index = order.firstIndex(of: oldFirst), index < table.numberOfRows else { return false }
        let visible = table.visibleRect
        let row = table.rect(ofRow: index)
        return abs(row.minY - visible.minY) <= 2 || visible.minY <= table.rect(ofRow: 0).minY + 2
    }
    static func firstChanged(from old: String?, to new: String?) -> Bool { old != nil && new != nil && old != new }
}

/// Placed inside a conversation's SwiftUI ScrollView, finds the AppKit scroll view that hosts it,
/// gives it a ThinScroller and a ScrollPinner. Invisible and never part of hit testing or layout.
struct MessageScrollSupport: NSViewRepresentable {
    /// Changes when the reader asks for the newest message.
    var scrollToBottomRequest: Int
    /// What the thread is about to show, so a size change can be told apart: append, prepend or reflow.
    var content = ThreadContent()
    var registry: ThreadRowRegistry? = nil
    /// Scrolled near the top of what is loaded (see `ScrollPinner.onNearTop`).
    var onNearTop: (() -> Void)? = nil
    var onNearBottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.pinner = context.coordinator.pinner
        context.coordinator.pinner.onNearBottomChanged = onNearBottomChanged
        context.coordinator.pinner.onNearTop = onNearTop
        context.coordinator.pinner.registry = registry
        context.coordinator.pinner.expect(content)
        context.coordinator.request = scrollToBottomRequest
        return view
    }
    func updateNSView(_ view: InstallerView, context: Context) {
        context.coordinator.pinner.onNearBottomChanged = onNearBottomChanged
        context.coordinator.pinner.onNearTop = onNearTop
        context.coordinator.pinner.registry = registry
        // SwiftUI updates run before the document is laid out for the new content, so the pinner
        // knows what the coming size change means before it arrives.
        context.coordinator.pinner.expect(content)
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
