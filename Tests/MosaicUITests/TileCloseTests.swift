import XCTest
import AppKit
import SwiftUI
import MosaicCore
@testable import Mosaic

/// Closing a tile in a real window: the tiles left take its place at once, even when they hold
/// long threads. Fictional conversations only.
final class TileCloseTests: XCTestCase {
    @MainActor private func settle(_ view: NSView, seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private func handleViews(in view: NSView) -> [TileHeaderHandle.HandleView] {
        (view as? TileHeaderHandle.HandleView).map { [$0] } ?? view.subviews.flatMap { handleViews(in: $0) }
    }
    /// Where a tile's message field is in the window: it moves with its tile.
    @MainActor private func field(_ id: String) -> NSRect? {
        DraftTextView.editor(for: id).map { $0.convert($0.bounds, to: nil) }
    }

    @MainActor func testTheTilesLeftFillAClosedTilesPlaceAtOnce() async throws {
        try await closeAndTime(sidebarRows: 0)
    }
    /// The same with a full sidebar, as a real Messages history has: closing a tile changes what
    /// every row shows (the open-tile mark), which must not hold the tiles up.
    @MainActor func testWithAFullSidebarToo() async throws {
        try await closeAndTime(sidebarRows: 500)
    }

    @MainActor private func closeAndTime(sidebarRows: Int) async throws {
        _ = NSApplication.shared
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        store.setLayout(.grid)
        XCTAssertEqual(store.openIDs.count, 4)
        store.close(store.openIDs[3])
        let ids = store.openIDs
        if sidebarRows > 0 {
            store.conversations += (1...sidebarRows).map {
                Conversation(id: "extra-\($0)", name: "Person \($0)", participants: ["person\($0)@example.test"], preview: "Hello there",
                             lastActivity: Date(timeIntervalSinceReferenceDate: 600_000_000 - Double($0)))
            }
        }
        // Long threads, as real conversations have.
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for id in ids {
            guard let index = store.conversations.firstIndex(where: { $0.id == id }) else { continue }
            store.conversations[index].messages = (1...600).map {
                Message(id: "\(id)-\($0)", text: "Message \($0): a few words that wrap across the bubble when the tile is narrow",
                        date: day + Double($0) * 60, isFromMe: $0 % 3 == 0)
            }
        }
        let hosting = NSHostingView(rootView: AnyView(WorkspaceView().environment(store).frame(width: 1320, height: 860)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        try await settle(hosting, seconds: 1.2)
        let before = try ids.map { try XCTUnwrap(field($0), "tile \($0) has its message field") }
        XCTAssertGreaterThan(abs(before[2].minY - before[1].minY), 50, "three tiles: two rows")

        // The close button of the first tile's header, pressed and released as the reader does.
        let handles = handleViews(in: hosting).filter { $0.window != nil }
        let handle = try XCTUnwrap(handles.min { a, b in
            let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
            return (fa.maxY, -fa.minX) > (fb.maxY, -fb.minX)
        }, "a tile header")
        let point = handle.convert(NSPoint(x: handle.closeRect.midX, y: handle.closeRect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = Date()
        handle.mouseDown(with: event(.leftMouseDown))
        handle.mouseUp(with: event(.leftMouseUp))
        XCTAssertFalse(store.openIDs.contains(ids[0]), "the top-left tile closed")
        hosting.layoutSubtreeIfNeeded()
        let firstPass = Date().timeIntervalSince(start)
        var settled: TimeInterval?
        while Date().timeIntervalSince(start) < 4 {
            if let a = field(ids[1]), let b = field(ids[2]), abs(a.minY - b.minY) < 2, abs(a.minX - b.minX) > 100 {
                settled = Date().timeIntervalSince(start)
                break
            }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        print("Closing a tile (\(sidebarRows) more sidebar rows): first layout \(Int(firstPass * 1000)) ms; tiles in their new places after \(settled.map { "\(Int($0 * 1000)) ms" } ?? "never")")
        let after = try XCTUnwrap(settled, "the two tiles left sit side by side in one row")
        XCTAssertLessThan(after, 1.0, "and get there at once")
    }
}

/// In Focus, every open conversation stays built, hidden under the one shown: choosing another
/// shows its tile as it was (drawn, scrolled, loaded) instead of building it afresh, whose first
/// frames showed it unscrolled — the blink between conversations. Fictional conversations only.
final class FocusSwitchTests: XCTestCase {
    @MainActor func testChoosingAConversationShowsItsTileAsItWas() async throws {
        _ = NSApplication.shared
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        store.setLayout(.focus)
        let ids = store.openIDs
        XCTAssertGreaterThan(ids.count, 2)
        let hosting = NSHostingView(rootView: AnyView(WorkspaceView().environment(store).frame(width: 1320, height: 860)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        let end = Date().addingTimeInterval(1)
        while Date() < end { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }

        let built = ids.compactMap { id in DraftTextView.editor(for: id).map { (id, $0) } }
        XCTAssertEqual(built.count, ids.count, "every open conversation is built in Focus")
        XCTAssertTrue(built.allSatisfy { $0.1.window != nil })
        let next = try XCTUnwrap(ids.first { $0 != store.focused?.id })
        store.requestComposerFocus(next)
        for _ in 0..<20 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.focused?.id, next)
        XCTAssertTrue(DraftTextView.editor(for: next) === built.first { $0.0 == next }?.1, "shown as it was, not built afresh")
        // The one shown before is still built, hidden, for when it is chosen again.
        let previous = try XCTUnwrap(built.first { $0.0 != next })
        XCTAssertTrue(DraftTextView.editor(for: previous.0) === previous.1)
    }
}

/// The menus read `store.menu`, which follows the store once a change is done — on the next turn
/// of the main queue, never inside the change (MenuState says why).
final class MenuStateTests: XCTestCase {
    @MainActor func testTheMenusFollowTheStoreOnceAChangeIsDone() async throws {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        store.setLayout(.grid)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.menu.values.canArrangeTiles)
        XCTAssertFalse(store.menu.values.canReopenClosedTile, "nothing closed yet")
        XCTAssertEqual(store.menu.values.sidebarFilter, .all)

        store.close(store.openIDs[0])
        XCTAssertFalse(store.menu.values.canReopenClosedTile, "not inside the change")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.menu.values.canReopenClosedTile, "once it is done")

        store.setSidebarFilter(.drafts)
        store.setLayout(.focus)
        store.zoomIn()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.menu.values.sidebarFilter, .drafts)
        XCTAssertFalse(store.menu.values.canArrangeTiles, "Focus shows one tile")
        XCTAssertFalse(store.menu.values.isActualSize)
        XCTAssertEqual(store.menu.values.zoomLabel, store.zoomLabel)

        store.reopenLastClosedTile()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(store.menu.values.canReopenClosedTile, "reopened: nothing left to reopen")
    }
}

/// The arrows resize the focused tile by moving its edge their way: Make Tile Wider is → for a
/// tile with a neighbour on its right and ← for the last in its row, and the same for Taller
/// with ↓ and ↑ — so the edge always moves the way the arrow points.
final class ResizeKeyTests: XCTestCase {
    @MainActor func testTheArrowsMoveTheFocusedTilesEdgeTheirWay() async throws {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        for layout in [WorkspaceLayout.grid, .columns] {
            // Wide enough for four columns to grow and shrink (they are at least 300 points).
            let viewport = CGSize(width: layout == .columns ? 1600 : 1000, height: 820)
            store.setLayout(layout)
            let ids = store.openIDs
            XCTAssertEqual(ids.count, 4)
            let plan = TileLayout.plan(order: ids, viewport: viewport, layout: layout)
            for id in ids {
                store.focus(id)
                let edges = store.resizeEdges
                let before = try XCTUnwrap(plan.frames[id])
                // Wider: the edge that moves goes left (←) or right (→), as its key says.
                let wider = try XCTUnwrap(TileLayout.resized(id, .wider, in: plan, layout: layout, proportions: .equal), "\(layout) \(id)")
                let after = try XCTUnwrap(TileLayout.plan(order: ids, viewport: viewport, layout: layout, gridFractions: wider.gridFractions,
                                                          rowWeights: wider.rowWeights, columnWeights: wider.columnWeights).frames[id])
                if edges.left {
                    XCTAssertLessThan(after.minX, before.minX, "\(layout) \(id): ← moves its left edge left")
                    XCTAssertEqual(after.maxX, before.maxX, accuracy: 0.5)
                } else {
                    XCTAssertGreaterThan(after.maxX, before.maxX, "\(layout) \(id): → moves its right edge right")
                    XCTAssertEqual(after.minX, before.minX, accuracy: 0.5)
                }
                guard layout == .grid else { XCTAssertFalse(edges.top); continue }
                let taller = try XCTUnwrap(TileLayout.resized(id, .taller, in: plan, layout: layout, proportions: .equal))
                let higher = try XCTUnwrap(TileLayout.plan(order: ids, viewport: viewport, layout: layout, gridFractions: taller.gridFractions,
                                                           rowWeights: taller.rowWeights, columnWeights: taller.columnWeights).frames[id])
                if edges.top {
                    XCTAssertLessThan(higher.minY, before.minY, "\(id): ↑ moves its top edge up")
                } else {
                    XCTAssertGreaterThan(higher.maxY, before.maxY, "\(id): ↓ moves its bottom edge down")
                }
            }
            // The keys in the menu follow the focused tile.
            store.focus(ids[3])
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(store.menu.values.movesLeftEdge, "\(layout): the last tile grows with ←")
            XCTAssertEqual(store.menu.values.movesTopEdge, layout == .grid)
            store.focus(ids[0])
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(store.menu.values.movesLeftEdge)
            XCTAssertFalse(store.menu.values.movesTopEdge)
        }
    }
}

/// A window into older history opens on the message it is around, not on its newest one.
final class StartRowTests: XCTestCase {
    final class Flipped: NSView { override var isFlipped: Bool { true } }

    @MainActor func testAWindowIntoOlderHistoryStartsOnItsMessage() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let document = Flipped(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        scroll.documentView = document
        let registry = ThreadRowRegistry()
        for index in 0..<30 { registry.update("m\(index)", CGRect(x: 0, y: CGFloat(index) * 100, width: 300, height: 100)) }
        let pinner = ScrollPinner()
        pinner.registry = registry
        pinner.startRow = "m12"
        pinner.attach(to: scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1250 - 200, accuracy: 0.5, "the row is in the middle of the view")
        XCTAssertFalse(pinner.isNearBottom, "not following the newest message")
        // The rows around it settle (a picture above it loads): the row stays in the middle.
        document.setFrameSize(NSSize(width: 300, height: 3200))
        for index in 0..<30 { registry.update("m\(index)", CGRect(x: 0, y: CGFloat(index) * 100 + (index >= 5 ? 200 : 0), width: 300, height: 100)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1450 - 200, accuracy: 1, "held while the rows settle")
        // Without a start row, a list starts on its newest message.
        let plain = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        plain.documentView = Flipped(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        let tail = ScrollPinner()
        tail.attach(to: plain)
        XCTAssertEqual(plain.contentView.bounds.origin.y, 2600, accuracy: 0.5)
    }
}

/// While the reader reads back, a thread keeps room above its rows: rows added above come into it
/// and the rows already laid out stay where they are; rows added below make it taller at its end.
final class ThreadRoomTests: XCTestCase {
    private struct Rows: View {
        let ids: [Int]
        let room: Bool
        let registry: ThreadRowRegistry
        var body: some View {
            ThreadStack(spacing: 10, roomAbove: room, registry: registry) {
                ForEach(ids, id: \.self) { id in
                    Color.clear.frame(height: 50).layoutValue(key: ThreadRowID.self, value: "\(id)")
                }
            }
        }
    }

    @MainActor func testRowsAddedAboveComeIntoRoomAndNothingLaidOutMoves() throws {
        let registry = ThreadRowRegistry()
        let host = NSHostingView(rootView: Rows(ids: Array(10..<20), room: false, registry: registry))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        func show(_ ids: Range<Int>, room: Bool) throws -> (Int) throws -> CGFloat {
            host.rootView = Rows(ids: Array(ids), room: room, registry: registry)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            return { id in try XCTUnwrap(registry.frames["\(id)"]).minY }
        }
        var y = try show(10..<20, room: false)
        XCTAssertEqual(try y(10), 0, accuracy: 0.5, "no room: the rows start at the top")
        // Reading back: room is made above the rows, and older rows come into it.
        y = try show(5..<20, room: true)
        let anchored = try y(10)
        XCTAssertEqual(try y(5), anchored - 5 * 60, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(try y(5), ThreadStack.room - 1)
        y = try show(0..<20, room: true)
        XCTAssertEqual(try y(10), anchored, accuracy: 0.5, "rows added above: nothing laid out moves")
        XCTAssertEqual(try y(0), anchored - 10 * 60, accuracy: 0.5)
        // Rows left out above leave room behind; rows added below go at the end.
        y = try show(3..<25, room: true)
        XCTAssertEqual(try y(10), anchored, accuracy: 0.5)
        XCTAssertEqual(try y(24), anchored + 14 * 60, accuracy: 0.5)
        // No more room needed: the rows start at the top again.
        y = try show(3..<25, room: false)
        XCTAssertEqual(try y(3), 0, accuracy: 0.5)
    }
}

/// A long thread lays out its newest rows, and older ones only as the reader goes up to them.
final class ThreadWindowTests: XCTestCase {
    @MainActor private func rows(_ count: Int, from: Int = 1) -> [MessageRow] {
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let messages = (from..<(from + count)).map { Message(id: "\($0)", text: "note \($0)", date: day + Double($0) * 60, isFromMe: $0 % 2 == 0) }
        return ThreadPresentation().prepared(for: Conversation(id: "c", name: "Alex", participants: ["a@example.test"], messages: messages)).rows
    }

    @MainActor func testTheWindowGrowsUpwardAndShrinksBackAtTheNewest() {
        let all = rows(300)
        let presentation = ThreadPresentation()
        let size = ThreadPresentation.windowSize, step = ThreadPresentation.step
        XCTAssertEqual(presentation.window(all, following: true).count, size, "following the newest: the newest rows only")
        XCTAssertEqual(presentation.window(all, following: true).last?.id, "300")
        XCTAssertEqual(presentation.rowsAbove(all), 300 - size)
        XCTAssertTrue(presentation.expand(all))
        XCTAssertEqual(presentation.window(all, following: false).count, size + step, "near the top: a step of older rows")
        XCTAssertEqual(presentation.window(all, following: true).count, size + step, "kept while the reader is up there")
        // New rows arrive below while reading: the window keeps its start.
        let more = all + rows(5, from: 301)
        XCTAssertEqual(presentation.window(more, following: false).first?.id, all[300 - size - step].id)
        // Back at the newest message: it shrinks again.
        XCTAssertTrue(presentation.release())
        XCTAssertEqual(presentation.window(more, following: true).count, size)
        // A match far up is laid out, with a few rows above it.
        XCTAssertTrue(presentation.include("15", in: more))
        let window = presentation.window(more, following: true)
        XCTAssertEqual(window.first?.id, "5")
        XCTAssertFalse(presentation.include("200", in: more), "already laid out")
        XCTAssertTrue(presentation.include("3", in: more))
        XCTAssertEqual(presentation.window(more, following: false).count, more.count, "every loaded row")
        // An older page loading above waits until the reader nears it, then comes a step at a time.
        let paged = rows(50, from: -49) + more
        XCTAssertEqual(presentation.window(paged, following: false).first?.id, "1", "the new page is not laid out at once")
        XCTAssertEqual(presentation.rowsAbove(paged), 50)
        XCTAssertTrue(presentation.expand(paged))
        XCTAssertEqual(presentation.window(paged, following: false).count, more.count + step)
        var steps = 1
        while presentation.expand(paged) { steps += 1 }
        XCTAssertEqual(steps, (50 + step - 1) / step, "a few rows at a time")
        XCTAssertEqual(presentation.window(paged, following: false).count, paged.count)
        XCTAssertFalse(presentation.expand(paged), "every row is laid out")
        // A short thread is laid out whole.
        let short = rows(40)
        XCTAssertEqual(ThreadPresentation().window(short, following: true).count, 40)
    }

    /// A long way back, rows far below the view are left out — a space as tall as they were
    /// stands in for them, the newest rows still laid out below it — so about the same number of
    /// rows are laid out however far back the reader goes. Going back down lays them out again,
    /// and leaves rows far above out instead.
    @MainActor func testRowsFarFromTheViewAreLeftOutHoweverFarBackTheReaderGoes() throws {
        let all = rows(600)
        let presentation = ThreadPresentation()
        let registry = ThreadRowRegistry()
        let height: CGFloat = 50, spacing: CGFloat = 10
        let bound = ThreadPresentation.windowSize + ThreadPresentation.step
        let tailKept = ThreadPresentation.tailKept
        // What ThreadStack does with the rows: each `rowHeight` tall, then the space standing in
        // for the rows left out, then the newest rows.
        func layOut(_ window: ArraySlice<MessageRow>, rowHeight: CGFloat? = nil) {
            let rowHeight = rowHeight ?? height
            registry.beginPass()
            var y: CGFloat = 0
            for row in window {
                registry.update(row.id, CGRect(x: 0, y: y, width: 300, height: rowHeight))
                y += rowHeight + spacing
            }
            registry.spaceTop = presentation.spaceBelow > 0 ? y : nil
            if presentation.spaceBelow > 0 { y += presentation.spaceBelow + spacing }
            for row in presentation.tail {
                registry.update(row.id, CGRect(x: 0, y: y, width: 300, height: rowHeight))
                y += rowHeight + spacing
            }
        }
        func show(_ following: Bool = false) -> ArraySlice<MessageRow> {
            let window = presentation.window(all, following: following, registry: registry, spacing: spacing)
            layOut(window)
            return window
        }
        /// How many rows are laid out: the window, and the newest ones below the space.
        func laidOut(_ window: ArraySlice<MessageRow>) -> Int { window.count + presentation.tail.count }
        /// The view: 400 points tall, `top` points down what is laid out.
        func view(_ top: CGFloat) { registry.visible = top...(top + 400) }

        var window = show(true)
        var most = 0
        // Up and up, near the top of what is laid out each time.
        for _ in 0..<60 {
            view(0)
            XCTAssertTrue(presentation.expand(all, registry: registry, trim: true))
            window = show()
            most = max(most, laidOut(window))
        }
        XCTAssertEqual(window.first?.id, all[600 - 80 - 60 * 8].id, "480 rows further back")
        XCTAssertLessThanOrEqual(most, bound + tailKept, "about as many rows laid out as at the start, and the newest few")
        XCTAssertEqual(presentation.tail.map(\.id), all.suffix(tailKept).map(\.id), "the newest rows stay laid out")
        let lastIndex = try XCTUnwrap(all.firstIndex { $0.id == window.last?.id })
        let leftOut = all.count - tailKept - lastIndex - 1
        XCTAssertGreaterThan(leftOut, 400)
        XCTAssertEqual(presentation.spaceBelow, CGFloat(leftOut) * height + CGFloat(leftOut - 1) * spacing, accuracy: 0.01,
                       "the space is as tall as the rows left out were")

        // Back down: the rows below are laid out again, a step at a time, and rows far above go.
        var turns = 0
        while presentation.spaceBelow > 0, turns < 300 {
            turns += 1
            view(try XCTUnwrap(registry.spaceTop) - 600)
            XCTAssertTrue(presentation.nearSpaceBelow(all, registry: registry))
            window = show()
            most = max(most, laidOut(window))
        }
        XCTAssertEqual(window.last?.id, "600", "every row below laid out again")
        XCTAssertTrue(presentation.tail.isEmpty)
        XCTAssertLessThanOrEqual(most, bound + tailKept, "and never many more on the way")

        // Left out again, then the tile changes width or zoom: the rows left out stay left out —
        // the space as tall as they were, scaled with the zoom — not all laid out at once.
        for _ in 0..<20 {
            view(0)
            _ = presentation.expand(all, registry: registry, trim: true)
            window = show()
        }
        let space = presentation.spaceBelow
        XCTAssertGreaterThan(space, 0)
        layOut(window, rowHeight: 70) // narrower: the rows laid out are taller
        XCTAssertEqual(presentation.window(all, following: false, registry: registry, spacing: spacing).map(\.id), window.map(\.id))
        XCTAssertEqual(presentation.spaceBelow, space, "as tall as they were, until they are laid out again")
        XCTAssertEqual(presentation.window(all, following: false, registry: registry, spacing: spacing * 2, zoom: 2).map(\.id), window.map(\.id))
        XCTAssertEqual(presentation.spaceBelow, space * 2, accuracy: 0.01, "twice the zoom: twice as tall")
        XCTAssertEqual(presentation.window(all, following: false, registry: registry, spacing: spacing, zoom: 1).map(\.id), window.map(\.id))
        XCTAssertEqual(presentation.spaceBelow, space, accuracy: 0.01)
        window = show()

        // A match among the rows left out: the window moves to it, with the rows below it still
        // left out; one among the newest rows is laid out already.
        let match = try XCTUnwrap(all.firstIndex { $0.id == window.last?.id }) + 60
        XCTAssertTrue(presentation.include(all[match].id, in: all))
        window = show()
        XCTAssertEqual(window.first?.id, all[match - 10].id)
        XCTAssertEqual(window.last?.id, all[match + ThreadPresentation.belowIncluded].id)
        XCTAssertGreaterThan(presentation.spaceBelow, 0)
        XCTAssertEqual(presentation.tail.count, tailKept)
        XCTAssertFalse(presentation.include("590", in: all), "the newest rows are laid out already")

        // Scrolling on without stopping: rows are left out only once very many are laid out.
        var scrolling = 0
        for _ in 0..<40 {
            view(0)
            _ = presentation.expand(all, registry: registry)
            window = show()
            scrolling = max(scrolling, laidOut(window))
        }
        XCTAssertLessThanOrEqual(scrolling, ThreadPresentation.mostLaidOut + ThreadPresentation.step)
        XCTAssertGreaterThan(scrolling, bound + tailKept)
        // Stopped: those far below are left out.
        view(0)
        XCTAssertTrue(presentation.leaveOutFarBelow(all, registry: registry, zoom: 1))
        XCTAssertLessThanOrEqual(laidOut(show()), bound + tailKept)
    }

    /// Back at the newest message after a long way back — Latest, or scrolled there — the newest
    /// rows shown are those kept laid out all along: nothing is laid out on the way, and the rows
    /// above them go a step at a time.
    @MainActor func testGoingBackToTheNewestLaysOutNothingNew() {
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let messages = (1...600).map { Message(id: "\($0)", text: "note \($0)", date: day + Double($0) * 60, isFromMe: $0 % 2 == 0) }
        let presentation = ThreadPresentation()
        let all = presentation.prepared(for: Conversation(id: "c", name: "Alex", participants: ["a@example.test"], messages: messages)).rows
        let registry = ThreadRowRegistry()
        func show(_ following: Bool = false) -> ArraySlice<MessageRow> {
            let window = presentation.window(all, following: following, registry: registry, spacing: 10)
            registry.beginPass()
            var y: CGFloat = 0
            for row in window + presentation.tail {
                registry.update(row.id, CGRect(x: 0, y: y, width: 300, height: 50))
                y += 60 + (row.id == window.last?.id && presentation.spaceBelow > 0 ? presentation.spaceBelow + 10 : 0)
            }
            return window
        }
        var window = show(true)
        XCTAssertEqual(window.count, ThreadPresentation.windowSize)
        for _ in 0..<40 {
            registry.visible = 0...400
            _ = presentation.expand(all, registry: registry, trim: true)
            window = show()
        }
        XCTAssertGreaterThan(presentation.spaceBelow, 0)
        let newest = presentation.tail.map(\.id)
        XCTAssertEqual(newest, all.suffix(ThreadPresentation.tailKept).map(\.id))
        // At the newest message: the rows above it go, a step at a time; nothing new is laid out.
        var laidOut = Set(window.map(\.id) + newest)
        var steps = 0
        while presentation.shed() {
            steps += 1
            window = show(true)
            let now = Set(window.map(\.id) + presentation.tail.map(\.id))
            XCTAssertTrue(now.isSubset(of: laidOut), "nothing new laid out")
            XCTAssertEqual(laidOut.count - now.count, ThreadPresentation.shedStep)
            XCTAssertEqual(presentation.tail.map(\.id), newest)
            laidOut = now
        }
        XCTAssertGreaterThan(steps, 0)
        XCTAssertTrue(presentation.release())
        window = show(true)
        XCTAssertEqual(window.map(\.id), newest, "the newest rows, laid out already, and no others")
        XCTAssertEqual(presentation.spaceBelow, 0)
        XCTAssertTrue(presentation.tail.isEmpty)
        XCTAssertFalse(presentation.release(), "nothing more to let go of")
        XCTAssertFalse(presentation.shed())
        // New messages while following: the newest rows, as many as before.
        let more = all + rows(3, from: 601)
        XCTAssertEqual(presentation.window(more, following: true).last?.id, "603")
        XCTAssertEqual(presentation.window(more, following: true).count, ThreadPresentation.tailKept)

        // Up a little — nothing left out — and back: the rows above the newest `windowSize` go.
        let other = ThreadPresentation()
        let rows600 = other.prepared(for: Conversation(id: "c", name: "Alex", participants: ["a@example.test"], messages: messages)).rows
        _ = other.window(rows600, following: true)
        for _ in 0..<10 { _ = other.expand(rows600) }
        XCTAssertEqual(other.window(rows600, following: true).count, ThreadPresentation.windowSize + 10 * ThreadPresentation.step)
        while other.shed() { _ = other.window(rows600, following: true) }
        XCTAssertTrue(other.release())
        XCTAssertEqual(other.window(rows600, following: true).count, ThreadPresentation.windowSize)
    }
}
