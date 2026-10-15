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
    func testTheTileAreaIsWhereTheTilesAre() throws {
        for layout in [WorkspaceLayout.grid, .columns] {
            for count in 1...5 {
                let ids = (0..<count).map { "t\($0)" }
                let plan = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 820), layout: layout)
                let union = plan.frames.values.reduce(CGRect.null) { $0.union($1) }
                XCTAssertEqual(union.minX, plan.area.minX, accuracy: 0.01); XCTAssertEqual(union.maxX, plan.area.maxX, accuracy: 0.01)
                XCTAssertEqual(union.minY, plan.area.minY, accuracy: 0.01); XCTAssertEqual(union.maxY, plan.area.maxY, accuracy: 0.01)
            }
        }
    }
    func testHeldTileIsDrawnInsideTheTileAreaWhileThePointerGoesPastIt() throws {
        let ids = ["a", "b", "c", "d"]
        let plan = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 820), layout: .grid)
        let area = plan.area, b = try XCTUnwrap(plan.frames["b"])
        var drag = TileDragSession(id: "b", origin: b, order: ids)
        // Far past the window's top right: drawn in the tile area's corner, which is its own place.
        drag.update(translation: CGSize(width: 400, height: -300), plan: plan)
        XCTAssertEqual(drag.frame, b.offsetBy(dx: 400, dy: -300), "the pointer's place is kept")
        XCTAssertEqual(drag.shownFrame, CGRect(x: area.maxX - b.width, y: area.minY, width: b.width, height: b.height))
        XCTAssertEqual(drag.order, ids)
        // Thrown over the sidebar in one move: drawn at the area's left edge, over a's place, and goes there.
        drag.update(translation: CGSize(width: -1500, height: 0), plan: plan)
        XCTAssertEqual(drag.shownFrame.origin, CGPoint(x: area.minX, y: b.minY))
        XCTAssertEqual(drag.order, ["b", "a", "c", "d"])
        // Inside the area, it is drawn where the pointer has it.
        drag.update(translation: CGSize(width: -20, height: 30), plan: plan)
        XCTAssertEqual(drag.shownFrame, drag.frame)
    }
    func testInScrolledColumnsTheHeldTileStaysInView() throws {
        let ids = ["a", "b", "c", "d", "e"]
        let plan = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 820), layout: .columns)
        let b = try XCTUnwrap(plan.frames["b"]), d = try XCTUnwrap(plan.frames["d"])
        // Scrolled so that b is in view and d only partly.
        let visible = CGRect(x: b.minX - 300, y: 0, width: 1000, height: 820)
        XCTAssertTrue(visible.contains(b) && visible.maxX > d.minX && visible.maxX < d.maxX)
        var drag = TileDragSession(id: "b", origin: b, order: ids)
        drag.update(translation: CGSize(width: 2000, height: 0), plan: plan, visible: visible)
        XCTAssertEqual(drag.shownFrame.maxX, visible.maxX, accuracy: 0.01, "stops at the edge of the view")
        drag.update(translation: CGSize(width: -2000, height: 0), plan: plan, visible: visible)
        XCTAssertEqual(drag.shownFrame.minX, visible.minX, accuracy: 0.01)
        // A tile picked up partly out of view may stay where it was, and go no further out.
        var partly = TileDragSession(id: "d", origin: d, order: ids)
        partly.update(translation: CGSize(width: 5, height: 0), plan: plan, visible: visible)
        XCTAssertEqual(partly.shownFrame.minX, d.minX, accuracy: 0.01)
        partly.update(translation: CGSize(width: -5, height: 0), plan: plan, visible: visible)
        XCTAssertEqual(partly.shownFrame.minX, d.minX - 5, accuracy: 0.01)
    }
    func testATileAsWideAsTheAreaStillGoesIntoAHalfOfARow() throws {
        let ids = ["a", "b", "c"]
        let plan = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 820), layout: .grid)
        let a = try XCTUnwrap(plan.frames["a"]), c = try XCTUnwrap(plan.frames["c"])
        XCTAssertEqual(c.width, plan.area.width, accuracy: 0.01)
        var drag = TileDragSession(id: "c", origin: c, order: ids)
        drag.update(translation: CGSize(width: a.midX - c.midX, height: a.midY - c.midY), plan: plan)
        XCTAssertEqual(drag.shownFrame.minX, c.minX, accuracy: 0.01, "it cannot be drawn further sideways")
        XCTAssertEqual(drag.shownFrame.minY, a.minY, accuracy: 0.01)
        XCTAssertEqual(drag.order, ["c", "a", "b"])
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

    /// A step starts where the step before it ended, even when it is given the plan drawn before
    /// that step (a quick press back, a held key): a step one way and one the other come back to
    /// an even split, exactly.
    func testKeyboardStepsEachWayComeBackToTheMiddle() throws {
        let order = ["a", "b", "c", "d"]
        let start = plan(order, .grid)
        for (id, step, back) in [("a", TileResizeStep.wider, TileResizeStep.narrower), ("b", .wider, .narrower),
                                 ("a", .taller, .shorter), ("d", .taller, .shorter)] {
            // Both steps are given the plan drawn before either.
            let one = try XCTUnwrap(TileLayout.resized(id, step, in: start, layout: .grid, proportions: .equal))
            XCTAssertNotEqual(one, .equal)
            let two = try XCTUnwrap(TileLayout.resized(id, back, in: start, layout: .grid, proportions: one))
            XCTAssertEqual(two, .equal, "\(id) \(step) then \(back): an even split again")
            XCTAssertEqual(plan(order, .grid, two).frames, start.frames)
        }
        // Three steps one way, each given the first plan, and three back.
        var proportions = TileProportions.equal
        for _ in 0..<3 { proportions = try XCTUnwrap(TileLayout.resized("b", .wider, in: start, layout: .grid, proportions: proportions)) }
        XCTAssertEqual(try XCTUnwrap(plan(order, .grid, proportions).frames["b"]).width,
                       try XCTUnwrap(start.frames["b"]).width + 3 * TileLayout.keyboardStep, accuracy: 0.5)
        for _ in 0..<3 { proportions = try XCTUnwrap(TileLayout.resized("b", .narrower, in: start, layout: .grid, proportions: proportions)) }
        XCTAssertEqual(proportions, .equal)
        // Columns too.
        let columns = plan(["a", "b", "c"], .columns, viewport: CGSize(width: 1400, height: 820))
        let wide = try XCTUnwrap(TileLayout.resized("b", .wider, in: columns, layout: .columns, proportions: .equal))
        XCTAssertEqual(TileLayout.resized("b", .narrower, in: columns, layout: .columns, proportions: wide), .equal)
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
