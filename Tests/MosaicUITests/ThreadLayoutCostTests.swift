import XCTest
import AppKit
import SwiftUI
import MosaicCore
@testable import Mosaic

/// What resizing a long thread costs, and which part of a bubble that cost comes from: a thread
/// of 600 fictional messages is laid out at one width and then another, with each part switched
/// off in turn. Prints the timings; asserts only that every variant lays out.
final class ThreadLayoutCostTests: XCTestCase {
    @MainActor private func resizeCost(_ label: String) throws -> Double {
        _ = NSApplication.shared
        let name = "MosaicTest-\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let messages = (1...600).map {
            Message(id: "\($0)", text: "Message \($0): a few words that wrap across the bubble when the tile is narrow, see https://example.com/\($0 % 7)",
                    date: day + Double($0) * 60, isFromMe: $0 % 3 == 0)
        }
        let conversation = Conversation(id: "c", name: "Alex", participants: ["alex@example.test"], messages: messages)
        let list = MessageList(conversation: conversation, isLive: false, canLoadMore: false, senderNames: [:], onLoadMore: {})
        let hosting = NSHostingView(rootView: AnyView(list.environment(store)))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        hosting.layoutSubtreeIfNeeded()
        var total = 0.0
        for width in [860.0, 420.0, 860.0, 420.0] {
            let start = Date()
            hosting.setFrameSize(NSSize(width: width, height: 700))
            hosting.layoutSubtreeIfNeeded()
            total += Date().timeIntervalSince(start)
        }
        let average = total / 4 * 1000
        print("Thread resize, 600 messages, \(label): \(Int(average)) ms per resize")
        return average
    }

    @MainActor func testWhatResizingALongThreadCosts() throws {
        defer { ThreadRenderingProbe.reset() }
        ThreadRenderingProbe.reset()
        let full = try resizeCost("everything")
        ThreadRenderingProbe.accessibilityActions = false
        _ = try resizeCost("no accessibility actions")
        ThreadRenderingProbe.reset(); ThreadRenderingProbe.accessibilityLabels = false
        _ = try resizeCost("no accessibility labels")
        ThreadRenderingProbe.reset(); ThreadRenderingProbe.contextMenus = false
        _ = try resizeCost("no context menus")
        ThreadRenderingProbe.reset(); ThreadRenderingProbe.rowGeometry = false
        _ = try resizeCost("no row geometry")
        ThreadRenderingProbe.accessibilityActions = false; ThreadRenderingProbe.accessibilityLabels = false; ThreadRenderingProbe.contextMenus = false
        _ = try resizeCost("text only")
        XCTAssertGreaterThan(full, 0)
    }
}
