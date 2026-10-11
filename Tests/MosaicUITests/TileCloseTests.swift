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
    /// Where a tile's message field is in the window: it moves with its tile.
    @MainActor private func field(_ id: String) -> NSRect? {
        DraftTextView.editor(for: id).map { $0.convert($0.bounds, to: nil) }
    }

    @MainActor func testTheTilesLeftFillAClosedTilesPlaceAtOnce() async throws {
        _ = NSApplication.shared
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        store.setLayout(.grid)
        XCTAssertEqual(store.openIDs.count, 4)
        store.close(store.openIDs[3])
        let ids = store.openIDs
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

        let start = Date()
        store.close(ids[0])
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
        print("Closing a tile: first layout \(Int(firstPass * 1000)) ms; tiles in their new places after \(settled.map { "\(Int($0 * 1000)) ms" } ?? "never")")
        let after = try XCTUnwrap(settled, "the two tiles left sit side by side in one row")
        XCTAssertLessThan(after, 1.0, "and get there at once")
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
