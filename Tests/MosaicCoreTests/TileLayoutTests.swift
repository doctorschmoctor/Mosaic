import XCTest
import CoreGraphics
@testable import MosaicCore

final class TileLayoutTests: XCTestCase {
    func testOneThroughEightTilesFillRowsWithoutOverlap() throws {
        for count in 1...8 {
            let ids = (0..<count).map(String.init)
            let plan = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 820), layout: .grid)
            XCTAssertEqual(plan.frames.count, count)
            XCTAssertEqual(plan.size.height, 820, "the grid never grows past the window")
            let rows = CGFloat((count + 1) / 2)
            let rowHeight = (820 - TileLayout.inset * 2 - (rows - 1) * TileLayout.gap) / rows
            for id in ids {
                let frame = try XCTUnwrap(plan.frames[id])
                XCTAssertGreaterThanOrEqual(frame.width, TileLayout.minimumWidth)
                XCTAssertEqual(frame.height, rowHeight, accuracy: 0.01)
                XCTAssertGreaterThanOrEqual(frame.minX, TileLayout.inset)
                XCTAssertLessThanOrEqual(frame.maxX, plan.size.width - TileLayout.inset + 0.01)
                for other in ids where id != other { XCTAssertFalse(frame.intersects(try XCTUnwrap(plan.frames[other]))) }
            }
            let last = try XCTUnwrap(plan.frames[ids.last!])
            XCTAssertEqual(last.maxY, plan.size.height - TileLayout.inset, accuracy: 0.01)
            XCTAssertEqual(last.maxX, plan.size.width - TileLayout.inset, accuracy: 0.01)
        }
    }
    func testClosingTilesGivesTheirSpaceToSurvivors() throws {
        let four = TileLayout.plan(order: ["a", "b", "c", "d"], viewport: CGSize(width: 1000, height: 820), layout: .grid)
        let three = TileLayout.plan(order: ["a", "b", "c"], viewport: four.size, layout: .grid)
        let two = TileLayout.plan(order: ["a", "b"], viewport: four.size, layout: .grid)
        XCTAssertGreaterThan(try XCTUnwrap(three.frames["c"]).width, try XCTUnwrap(four.frames["c"]).width)
        XCTAssertGreaterThan(try XCTUnwrap(two.frames["a"]).height, try XCTUnwrap(four.frames["a"]).height)
    }
    func testDraggingPreviewsOrderWithoutChangingTheGrabbedCardSizeAndAvoidsJitter() throws {
        let ids = ["a", "b", "c", "d"]
        let first = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 820), layout: .grid)
        let a = try XCTUnwrap(first.frames["a"]), d = try XCTUnwrap(first.frames["d"])
        var drag = TileDragSession(id: "a", origin: a, order: ids)
        let translation = CGSize(width: d.midX - a.midX, height: d.midY - a.midY)
        drag.update(translation: translation, plan: first)
        XCTAssertEqual(drag.order, ["b", "c", "d", "a"])
        XCTAssertEqual(drag.frame.size, a.size)
        let preview = TileLayout.plan(order: drag.order, viewport: first.size, layout: .grid)
        drag.update(translation: translation, plan: preview)
        XCTAssertEqual(drag.order, ["b", "c", "d", "a"])
        XCTAssertEqual(drag.frame.midX, d.midX, accuracy: 0.01)
    }
    func testResizeKeepsMinimumsAndOnlyChangesTheAdjacentPair() {
        XCTAssertEqual(TileLayout.resizedPair([350, 450, 400], at: 0, delta: 1000, minimum: 300), [500, 300, 400])
        let shrunk = TileLayout.distribute(total: 910, count: 3, minimum: 300, weights: [800, 300, 300])
        XCTAssertEqual(shrunk.reduce(0, +), 910, accuracy: 0.01)
        XCTAssertTrue(shrunk.allSatisfy { $0 >= 300 })
    }
    func testColumnsScrollAndFocusUsesTheWholeAvailableSpace() throws {
        let columns = TileLayout.plan(order: ["a", "b", "c", "d"], viewport: CGSize(width: 800, height: 600), layout: .columns)
        XCTAssertGreaterThan(columns.size.width, 800)
        XCTAssertTrue(columns.frames.values.allSatisfy { $0.width >= 300 })
        let focused = TileLayout.plan(order: ["a"], viewport: CGSize(width: 800, height: 600), layout: .focus)
        XCTAssertEqual(try XCTUnwrap(focused.frames["a"]), CGRect(x: 4, y: 4, width: 792, height: 592))
    }
    /// A top inset (Focus's chip row) keeps the top of the canvas free while the plan still
    /// covers the whole viewport: the tile sits below the inset, and the canvas reaches the bottom.
    func testTopInsetKeepsTheCanvasWholeAndMovesTheTileDown() throws {
        let plan = TileLayout.plan(order: ["a"], viewport: CGSize(width: 800, height: 600), layout: .focus, topInset: 44)
        XCTAssertEqual(plan.size, CGSize(width: 800, height: 600), "the canvas is as tall as the viewport")
        XCTAssertEqual(try XCTUnwrap(plan.frames["a"]), CGRect(x: 4, y: 48, width: 792, height: 548))
        let grid = TileLayout.plan(order: ["a", "b", "c"], viewport: CGSize(width: 800, height: 600), layout: .grid, topInset: 44)
        XCTAssertEqual(grid.frames.values.map(\.minY).min(), 48)
        XCTAssertEqual(grid.frames.values.map(\.maxY).max(), 596)
    }
}
