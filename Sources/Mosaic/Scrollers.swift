import SwiftUI
import AppKit

/// An overlay scroller that draws the same slim knob whether idle, hovered, or being dragged.
/// The system scroller grows a track and a thicker knob under the pointer; this one never does.
final class ThinScroller: NSScroller {
    static let knobWidth: CGFloat = 6
    static let margin: CGFloat = 3

    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let knob = rect(for: .knob)
        let vertical = bounds.height >= bounds.width
        let frame = vertical
            ? NSRect(x: bounds.maxX - Self.margin - Self.knobWidth, y: knob.minY, width: Self.knobWidth, height: knob.height)
            : NSRect(x: knob.minX, y: bounds.maxY - Self.margin - Self.knobWidth, width: knob.width, height: Self.knobWidth)
        guard frame.width > 0, frame.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: frame, xRadius: Self.knobWidth / 2, yRadius: Self.knobWidth / 2).fill()
    }

    static func install(in scrollView: NSScrollView) {
        guard !(scrollView.verticalScroller is ThinScroller) else { return }
        let scroller = ThinScroller()
        scroller.controlSize = .small
        scrollView.verticalScroller = scroller
        scrollView.scrollerStyle = .overlay
    }
}

/// Placed inside a SwiftUI ScrollView's content, finds the AppKit scroll view that hosts it
/// and gives it a ThinScroller. Invisible and never part of hit testing.
struct ThinScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }
    func updateNSView(_ view: InstallerView, context: Context) { view.install() }

    final class InstallerView: NSView {
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.install() }
        }
        func install() {
            var view: NSView? = superview
            while let current = view {
                if let scrollView = current as? NSScrollView { ThinScroller.install(in: scrollView); return }
                view = current.superview
            }
        }
    }
}
