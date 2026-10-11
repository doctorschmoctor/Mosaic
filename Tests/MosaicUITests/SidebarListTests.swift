import XCTest
import AppKit
import SwiftUI
import MosaicCore
@testable import Mosaic

/// The sidebar's lists in a real window: the full list stays alive under the Unread and Drafts
/// lists, so going back to All shows it as it was, without rebuilding hundreds of rows.
/// Fictional conversations only.
final class SidebarListTests: XCTestCase {
    @MainActor private func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }
    @MainActor private func settle(_ view: NSView, seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testGoingBackToAllShowsTheListThatWasKeptAlive() async throws {
        _ = NSApplication.shared
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        store.conversations += (1...300).map {
            Conversation(id: "extra-\($0)", name: "Person \($0)", participants: ["person\($0)@example.test"], preview: "Hello there",
                         lastActivity: Date(timeIntervalSinceReferenceDate: 600_000_000 - Double($0)))
        }
        let hosting = NSHostingView(rootView: AnyView(WorkspaceView().environment(store).frame(width: 1320, height: 860)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        try await settle(hosting, seconds: 0.8)

        let before = tables(in: hosting)
        XCTAssertEqual(before.count, 1, "one list while All is shown")
        let all = try XCTUnwrap(before.first)
        let rows = all.numberOfRows
        XCTAssertGreaterThan(rows, 300)

        store.setSidebarFilter(.unread)
        try await settle(hosting, seconds: 0.3)
        let filtered = tables(in: hosting)
        XCTAssertEqual(filtered.count, 2, "the Unread list over the full one")
        XCTAssertTrue(filtered.contains { $0 === all }, "the full list is still there")
        XCTAssertEqual(all.numberOfRows, rows, "and still has every row")

        let start = Date()
        store.setSidebarFilter(.all)
        hosting.layoutSubtreeIfNeeded()
        print("Switching back to All took \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        try await settle(hosting, seconds: 0.3)
        let after = tables(in: hosting)
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after.first === all, "the same list, not a rebuilt one")
        XCTAssertEqual(all.numberOfRows, rows)
    }
}
