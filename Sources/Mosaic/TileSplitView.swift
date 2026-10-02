import SwiftUI
import AppKit

/// Native resize behavior with transparent dividers between the floating tiles.
struct TileSplitView: NSViewRepresentable {
    struct Pane {
        let id: String
        let content: AnyView
    }
    let axis: Axis
    let minimumPaneSize: CGFloat
    let panes: [Pane]

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FloatingSplitView {
        let split = FloatingSplitView()
        split.isVertical = axis == .horizontal
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        return split
    }
    func updateNSView(_ split: FloatingSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.minimumPaneSize = minimumPaneSize
        let ids = panes.map(\.id)
        if coordinator.ids != ids {
            let retained = Set(ids)
            for id in coordinator.hosts.keys.filter({ !retained.contains($0) }) {
                coordinator.hosts.removeValue(forKey: id)?.removeFromSuperview()
            }
            for view in split.subviews { view.removeFromSuperview() }
            for pane in panes {
                let host = coordinator.hosts[pane.id] ?? NSHostingView(rootView: pane.content)
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                coordinator.hosts[pane.id] = host
                split.addSubview(host)
            }
            coordinator.ids = ids
            split.needsEqualLayout = true
        }
        for pane in panes { coordinator.hosts[pane.id]?.rootView = pane.content }
        split.needsLayout = true
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var ids: [String] = []
        var hosts: [String: NSHostingView<AnyView>] = [:]
        var minimumPaneSize: CGFloat = 0

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            let frame = splitView.subviews[index].frame
            return max(proposed, (splitView.isVertical ? frame.minX : frame.minY) + minimumPaneSize)
        }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            let frame = splitView.subviews[index + 1].frame
            return min(proposed, (splitView.isVertical ? frame.maxX : frame.maxY) - minimumPaneSize - splitView.dividerThickness)
        }
        func splitView(_ splitView: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect, ofDividerAt index: Int) -> NSRect {
            drawn.insetBy(dx: splitView.isVertical ? -4 : 0, dy: splitView.isVertical ? 0 : -4)
        }
    }
}

final class FloatingSplitView: NSSplitView {
    var needsEqualLayout = true
    override var isFlipped: Bool { true }
    override var dividerColor: NSColor { .clear }
    override func drawDivider(in rect: NSRect) {}

    override func layout() {
        if needsEqualLayout, !subviews.isEmpty, bounds.width > 0, bounds.height > 0 {
            let extent = isVertical ? bounds.width : bounds.height
            let paneSize = max(0, (extent - CGFloat(subviews.count - 1) * dividerThickness) / CGFloat(subviews.count))
            for (index, view) in subviews.enumerated() {
                let position = CGFloat(index) * (paneSize + dividerThickness)
                view.frame = isVertical
                    ? NSRect(x: position, y: 0, width: paneSize, height: bounds.height)
                    : NSRect(x: 0, y: position, width: bounds.width, height: paneSize)
            }
            needsEqualLayout = false
        }
        super.layout()
    }
}
