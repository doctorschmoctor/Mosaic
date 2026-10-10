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

    // MARK: Keyboard steps

    private func plan(_ order: [String], _ layout: WorkspaceLayout, _ proportions: TileProportions = .equal,
                      viewport: CGSize = CGSize(width: 1000, height: 820)) -> TilePlan {
        TileLayout.plan(order: order, viewport: viewport, layout: layout, gridFractions: proportions.gridFractions,
                        rowWeights: proportions.rowWeights, columnWeights: proportions.columnWeights)
    }

    /// A grid tile's wider/narrower moves the divider in its row, from either side; the other row
    /// is untouched, and a tile alone in its row cannot change width.
    func testKeyboardWidthStepsMoveTheDividerInTheTilesRow() throws {
        let order = ["a", "b", "c"]
        let start = plan(order, .grid)
        let a = try XCTUnwrap(start.frames["a"]), b = try XCTUnwrap(start.frames["b"])
        let wider = try XCTUnwrap(TileLayout.resized("a", .wider, in: start, layout: .grid, proportions: .equal))
        let afterA = plan(order, .grid, wider)
        XCTAssertEqual(try XCTUnwrap(afterA.frames["a"]).width, a.width + TileLayout.keyboardStep, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(afterA.frames["b"]).width, b.width - TileLayout.keyboardStep, accuracy: 0.5)
        XCTAssertEqual(afterA.frames["c"], start.frames["c"], "the other row keeps its size")
        // The right-hand tile grows leftwards.
        let bWider = try XCTUnwrap(TileLayout.resized("b", .wider, in: start, layout: .grid, proportions: .equal))
        XCTAssertEqual(try XCTUnwrap(plan(order, .grid, bWider).frames["b"]).width, b.width + TileLayout.keyboardStep, accuracy: 0.5)
        let bNarrower = try XCTUnwrap(TileLayout.resized("b", .narrower, in: start, layout: .grid, proportions: .equal))
        XCTAssertEqual(try XCTUnwrap(plan(order, .grid, bNarrower).frames["b"]).width, b.width - TileLayout.keyboardStep, accuracy: 0.5)
        XCTAssertNil(TileLayout.resized("c", .wider, in: start, layout: .grid, proportions: .equal), "alone in its row")
    }

    /// Steps stop at the minimum width: the last one that changes anything lands on it, and the
    /// next is refused.
    func testKeyboardStepsStopAtTheMinimum() throws {
        let order = ["a", "b"]
        var proportions = TileProportions.equal
        var steps = 0
        while let next = TileLayout.resized("a", .narrower, in: plan(order, .grid, proportions), layout: .grid, proportions: proportions) {
            proportions = next
            steps += 1
            XCTAssertLessThan(steps, 50)
        }
        XCTAssertGreaterThan(steps, 0)
        XCTAssertEqual(try XCTUnwrap(plan(order, .grid, proportions).frames["a"]).width, TileLayout.minimumWidth, accuracy: 0.5)
    }

    /// Taller and shorter trade height with the row below — or above, for the last row — and a
    /// single row has nothing to trade with.
    func testKeyboardHeightStepsTradeWithTheNeighbouringRow() throws {
        let order = ["a", "b", "c", "d"]
        let start = plan(order, .grid)
        let top = try XCTUnwrap(start.frames["a"]).height, bottom = try XCTUnwrap(start.frames["c"]).height
        let taller = try XCTUnwrap(TileLayout.resized("b", .taller, in: start, layout: .grid, proportions: .equal))
        let afterTop = plan(order, .grid, taller)
        XCTAssertEqual(try XCTUnwrap(afterTop.frames["a"]).height, top + TileLayout.keyboardStep, accuracy: 0.5, "the whole row grows")
        XCTAssertEqual(try XCTUnwrap(afterTop.frames["d"]).height, bottom - TileLayout.keyboardStep, accuracy: 0.5)
        let lastTaller = try XCTUnwrap(TileLayout.resized("d", .taller, in: start, layout: .grid, proportions: .equal))
        XCTAssertEqual(try XCTUnwrap(plan(order, .grid, lastTaller).frames["d"]).height, bottom + TileLayout.keyboardStep, accuracy: 0.5)
        let lastShorter = try XCTUnwrap(TileLayout.resized("c", .shorter, in: start, layout: .grid, proportions: .equal))
        XCTAssertEqual(try XCTUnwrap(plan(order, .grid, lastShorter).frames["a"]).height, top + TileLayout.keyboardStep, accuracy: 0.5)
        XCTAssertNil(TileLayout.resized("a", .taller, in: plan(["a", "b"], .grid), layout: .grid, proportions: .equal), "one row")
    }

    /// In Columns a tile trades width with the next column (the one before, for the last);
    /// height and Focus have nothing to change.
    func testKeyboardStepsInColumnsAndFocus() throws {
        let order = ["a", "b", "c"]
        let start = plan(order, .columns, viewport: CGSize(width: 1400, height: 820))
        let c = try XCTUnwrap(start.frames["c"]).width, b = try XCTUnwrap(start.frames["b"]).width
        let wider = try XCTUnwrap(TileLayout.resized("c", .wider, in: start, layout: .columns, proportions: .equal))
        let after = plan(order, .columns, wider, viewport: CGSize(width: 1400, height: 820))
        XCTAssertEqual(try XCTUnwrap(after.frames["c"]).width, c + TileLayout.keyboardStep, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(after.frames["b"]).width, b - TileLayout.keyboardStep, accuracy: 0.5)
        XCTAssertEqual(after.frames["a"], start.frames["a"])
        XCTAssertNil(TileLayout.resized("a", .taller, in: start, layout: .columns, proportions: .equal))
        let focus = plan(["a"], .focus)
        for step in [TileResizeStep.wider, .narrower, .taller, .shorter] {
            XCTAssertNil(TileLayout.resized("a", step, in: focus, layout: .focus, proportions: .equal))
        }
        XCTAssertNil(TileLayout.resized("missing", .wider, in: start, layout: .columns, proportions: .equal))
    }
}
