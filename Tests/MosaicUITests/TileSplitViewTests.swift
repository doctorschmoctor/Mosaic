import XCTest
import AppKit
@testable import Mosaic

final class TileSplitViewTests: XCTestCase {
    @MainActor func testTileResizeSurvivesLayoutAndWindowResize() {
        _ = NSApplication.shared
        for vertical in [true, false] {
            let split = FloatingSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
            split.isVertical = vertical
            split.dividerStyle = .thin
            split.addSubview(NSView())
            split.addSubview(NSView())
            split.layoutSubtreeIfNeeded()
            split.setPosition(325, ofDividerAt: 0)
            split.needsLayout = true
            split.layoutSubtreeIfNeeded()
            let first = split.subviews[0].frame
            XCTAssertEqual(vertical ? first.width : first.height, 325, accuracy: 1)

            let fraction = (vertical ? first.width : first.height) / (800 - split.dividerThickness)
            split.setFrameSize(NSSize(width: 1000, height: 1000))
            split.adjustSubviews()
            split.layoutSubtreeIfNeeded()
            let resized = split.subviews[0].frame
            XCTAssertEqual(vertical ? resized.width : resized.height, fraction * (1000 - split.dividerThickness), accuracy: 1)
            let last = split.subviews[1].frame
            XCTAssertEqual(vertical ? last.maxX : last.maxY, 1000, accuracy: 1)
        }
    }

    @MainActor func testInvisibleDividerKeepsMinimumTileSizes() {
        _ = NSApplication.shared
        let split = FloatingSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        split.isVertical = true
        split.dividerStyle = .thin
        let coordinator = TileSplitView.Coordinator()
        coordinator.minimumPaneSize = 275
        split.delegate = coordinator
        split.addSubview(NSView())
        split.addSubview(NSView())
        split.layoutSubtreeIfNeeded()
        split.setPosition(10, ofDividerAt: 0)
        XCTAssertGreaterThanOrEqual(split.subviews[0].frame.width, 275)
        split.setPosition(790, ofDividerAt: 0)
        XCTAssertGreaterThanOrEqual(split.subviews[1].frame.width, 275)
        let divider = NSRect(x: split.subviews[0].frame.maxX, y: 0, width: split.dividerThickness, height: 600)
        let handle = coordinator.splitView(split, effectiveRect: divider, forDrawnRect: divider, ofDividerAt: 0)
        XCTAssertGreaterThan(handle.width, divider.width)
        XCTAssertTrue(handle.contains(NSPoint(x: divider.midX, y: 300)))
    }
}
