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
}
