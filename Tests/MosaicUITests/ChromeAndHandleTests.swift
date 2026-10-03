import XCTest
import AppKit
import MosaicCore
@testable import Mosaic

/// AppKit pieces that make the title-bar strip, tile headers and focus chips work without SwiftUI
/// controls (and without the nested hosting view whose constraint loop crashed the app).
final class ChromeAndHandleTests: XCTestCase {
    @MainActor private func makeWindow(_ view: NSView, size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }
    /// A left mouse down + up pair at a point given in the (flipped) view's own coordinates.
    @MainActor private func click(_ view: NSView, at point: NSPoint, in window: NSWindow, drag: NSPoint? = nil) {
        let base = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, base))
        if let drag {
            let dragged = view.convert(drag, to: nil)
            view.mouseDragged(with: event(.leftMouseDragged, dragged))
            view.mouseUp(with: event(.leftMouseUp, dragged))
        } else {
            view.mouseUp(with: event(.leftMouseUp, base))
        }
    }

    @MainActor func testWindowChromeUsesAnEmptyAppKitToolbarForTheTallTitleBar() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        WindowChrome.apply(to: window)
        XCTAssertEqual(window.toolbar?.identifier, WindowChrome.toolbarIdentifier)
        XCTAssertEqual(window.toolbar?.items.count, 0, "no SwiftUI toolbar items, so no nested hosting view in the title bar")
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.isMovable, "AppKit's title-bar dragging is off; WindowDragRegion moves the window")
        XCTAssertFalse(window.isMovableByWindowBackground)
        let toolbar = window.toolbar
        WindowChrome.apply(to: window)
        XCTAssertTrue(window.toolbar === toolbar, "applying twice keeps the same toolbar")
        XCTAssertNoThrow(WindowChrome.apply(to: nil))
    }

    @MainActor func testWindowDragRegionTakesOnlyTitleBarStripPressesWhenLimited() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let region = WindowDragRegion.DragView(frame: content.bounds)
        region.limitedToTitleBar = true
        content.addSubview(region)
        XCTAssertFalse(region.mouseDownCanMoveWindow)
        // Points are in the superview's (unflipped) coordinates: y = 390 is 10 points from the top.
        XCTAssertTrue(region.hitTest(NSPoint(x: 300, y: 390)) === region, "the strip moves the window")
        XCTAssertTrue(region.hitTest(NSPoint(x: 300, y: 400 - WorkspaceView.titleBarHeight + 1)) === region)
        XCTAssertNil(region.hitTest(NSPoint(x: 300, y: 400 - WorkspaceView.titleBarHeight - 1)), "below the strip, content gets the press")
        XCTAssertNil(region.hitTest(NSPoint(x: 300, y: 100)))
        XCTAssertNil(region.hitTest(NSPoint(x: 700, y: 390)), "outside its own bounds")
        region.limitedToTitleBar = false
        XCTAssertTrue(region.hitTest(NSPoint(x: 300, y: 100)) === region, "an unlimited region (the sidebar strip) takes every press in its frame")
        // Double-click actions never trap, whatever System Settings says.
        for action in ["None", "Minimize", "Maximize", "Fill", nil] {
            WindowDragRegion.DragView.performTitleBarDoubleClick(on: window, action: action)
        }
    }

    @MainActor func testWindowDragRegionMovesANonMovableWindowByThePointersTravel() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isMovable = false
        let region = WindowDragRegion.DragView(frame: NSRect(x: 0, y: 0, width: 600, height: 52))
        window.contentView?.addSubview(region)
        region.beginManualDrag(from: NSPoint(x: 500, y: 500))
        region.moveWindow(to: NSPoint(x: 520, y: 480))
        XCTAssertEqual(window.frame.origin, NSPoint(x: 120, y: 80))
        region.moveWindow(to: NSPoint(x: 400, y: 600))
        XCTAssertEqual(window.frame.origin, NSPoint(x: 0, y: 200))
        XCTAssertEqual(window.frame.size, NSSize(width: 600, height: 400))
    }

    @MainActor func testHeaderHandleTrackingEndsOnRelease() {
        let handle = TileHeaderHandle.HandleView()
        let window = makeWindow(handle, size: NSSize(width: 320, height: 54))
        XCTAssertFalse(handle.isTracking)
        click(handle, at: CGPoint(x: 60, y: 27), in: window, drag: CGPoint(x: 120, y: 27))
        XCTAssertFalse(handle.isTracking, "a release ends the press whether or not it dragged")
        click(handle, at: CGPoint(x: 60, y: 27), in: window)
        XCTAssertFalse(handle.isTracking)
    }

    private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

    @MainActor func testScrollPinnerKeepsTheDistanceFromTheBottomThroughSizeChanges() {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document
        let pinner = ScrollPinner()
        pinner.attach(to: scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 800, accuracy: 0.5, "a fresh list shows its newest message")
        XCTAssertTrue(pinner.isNearBottom)
        // A new message: the content grows and the list stays on the end.
        document.setFrameSize(NSSize(width: 300, height: 1200))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1000, accuracy: 0.5)
        // The tile grows (layout switch): still on the end, no interim position.
        scroll.setFrameSize(NSSize(width: 300, height: 400))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 800, accuracy: 0.5)
        // The tile shrinks again.
        scroll.setFrameSize(NSSize(width: 300, height: 200))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1000, accuracy: 0.5)
        // The reader scrolls up 300 points.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(pinner.distanceFromBottom, 300, accuracy: 0.5)
        XCTAssertFalse(pinner.isNearBottom)
        // Older messages load above: the same rows stay in view.
        document.setFrameSize(NSSize(width: 300, height: 1600))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1100, accuracy: 0.5)
        // A resize while scrolled up also keeps the distance.
        scroll.setFrameSize(NSSize(width: 300, height: 300))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1000, accuracy: 0.5)
        pinner.scrollToBottom()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1300, accuracy: 0.5)
        XCTAssertTrue(pinner.isNearBottom)
        // Shorter content than the viewport sits at the top without going negative.
        document.setFrameSize(NSSize(width: 300, height: 100))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    @MainActor func testMessageRowsPrecomputeDaySeparatorsAndStatusOnce() {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let messages = [Message(id: "1", text: "a", date: base, isFromMe: false),
                        Message(id: "2", text: "b", date: base.addingTimeInterval(60), isFromMe: true),
                        Message(id: "3", text: "c", date: base.addingTimeInterval(86_400 * 2), isFromMe: true),
                        Message(id: "4", text: "d https://example.com", date: base.addingTimeInterval(86_400 * 2 + 5), isFromMe: false)]
        let rows = MessageRow.rows(for: Conversation(id: "c", name: "C", participants: ["x"], messages: messages))
        XCTAssertEqual(rows.map { $0.dayLabel != nil }, [true, false, true, false])
        XCTAssertEqual(rows.map(\.showsStatus), [false, false, true, false], "only the latest sent message shows Delivered/Read")
        XCTAssertEqual(MessageText.time(base), MessageText.time(base.addingTimeInterval(20)), "cached per minute")
        XCTAssertEqual(MessageText.day(base), MessageText.day(base.addingTimeInterval(3600)))
        let attributed = MessageText.attributed("d https://example.com")
        XCTAssertEqual(attributed.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
    }

    @MainActor func testTileHeaderHandleTellsCloseClicksFromFocusClicksAndDrags() {
        let handle = TileHeaderHandle.HandleView()
        let window = makeWindow(handle, size: NSSize(width: 320, height: 54))
        var closes = 0, clicks = 0, drags: [CGSize] = [], ended = 0
        handle.onClose = { closes += 1 }
        handle.onClick = { clicks += 1 }
        handle.onDragChanged = { drags.append($0) }
        handle.onDragEnded = { ended += 1 }
        let closeRect = handle.closeRect
        XCTAssertEqual(closeRect, CGRect(x: 320 - 10 - 22, y: 16, width: 22, height: 22))
        XCTAssertEqual(closeRect, TileHeaderHandle.closeRect(in: handle.bounds))
        XCTAssertFalse(handle.mouseDownCanMoveWindow, "presses on the title-bar strip must reach the header, not move the window")

        click(handle, at: CGPoint(x: closeRect.midX, y: closeRect.midY), in: window)
        XCTAssertEqual(closes, 1); XCTAssertEqual(clicks, 0)

        click(handle, at: CGPoint(x: 60, y: 27), in: window)
        XCTAssertEqual(closes, 1); XCTAssertEqual(clicks, 1)

        // A press that starts on × but ends elsewhere is neither a close nor a focus click.
        click(handle, at: CGPoint(x: closeRect.midX, y: closeRect.midY), in: window, drag: CGPoint(x: 40, y: 27))
        XCTAssertEqual(closes, 1); XCTAssertEqual(clicks, 1); XCTAssertTrue(drags.isEmpty)

        // Dragging the header moves the tile: canvas coordinates grow downward.
        click(handle, at: CGPoint(x: 60, y: 27), in: window, drag: CGPoint(x: 100, y: 57))
        XCTAssertEqual(drags.count, 1)
        XCTAssertEqual(drags.first?.width ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(drags.first?.height ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(ended, 1); XCTAssertEqual(clicks, 1)

        handle.draggable = false
        click(handle, at: CGPoint(x: 60, y: 27), in: window, drag: CGPoint(x: 100, y: 57))
        XCTAssertEqual(drags.count, 1, "a lone tile cannot be dragged")
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(handle.accessibilityChildren()?.count, 1, "the close target is exposed to VoiceOver")
    }

    @MainActor func testFocusChipBarSelectsTheChipUnderThePointer() {
        let chats = [Conversation(id: "a", name: "Alex Morgan", participants: ["alex@example.test"]),
                     Conversation(id: "b", name: "Weekend crew", participants: ["x@example.test", "y@example.test"]),
                     Conversation(id: "c", name: "Jamie Chen", participants: ["jamie@example.test"])]
        let chips = FocusChip.chips(for: chats, focusedID: "b")
        XCTAssertEqual(chips.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(chips.map(\.isSelected), [false, true, false])
        XCTAssertEqual(chips[0].initials, "AM")
        XCTAssertTrue(chips[1].isGroup)

        let bar = FocusChipBar.ChipBarView()
        bar.chips = chips
        let window = makeWindow(bar, size: NSSize(width: 700, height: FocusChipBar.height))
        XCTAssertEqual(bar.frames.count, 3)
        XCTAssertFalse(bar.mouseDownCanMoveWindow)
        XCTAssertGreaterThan(bar.contentWidth, 0)
        for (index, frame) in bar.frames.enumerated() {
            XCTAssertEqual(frame.height, FocusChipBar.height)
            if index > 0 { XCTAssertEqual(frame.minX, bar.frames[index - 1].maxX + FocusChipBar.ChipBarView.spacing, accuracy: 0.01) }
        }
        var selected: [String] = []
        bar.onSelect = { selected.append($0) }
        click(bar, at: CGPoint(x: bar.frames[2].midX, y: 18), in: window)
        XCTAssertEqual(selected, ["c"])
        click(bar, at: CGPoint(x: bar.frames[0].midX, y: 18), in: window)
        XCTAssertEqual(selected, ["c", "a"])
        // Releasing over a different chip than the one pressed selects nothing.
        click(bar, at: CGPoint(x: bar.frames[0].midX, y: 18), in: window, drag: CGPoint(x: bar.frames[1].midX, y: 18))
        XCTAssertEqual(selected, ["c", "a"])
        click(bar, at: CGPoint(x: bar.frames[2].maxX + 100, y: 18), in: window)
        XCTAssertEqual(selected, ["c", "a"], "empty space does nothing")
        XCTAssertEqual(bar.accessibilityChildren()?.count, 3)
        // Drawing must not throw or need a live window appearance.
        bar.chips = FocusChip.chips(for: chats, focusedID: "c")
        XCTAssertEqual(bar.frames.count, 3)
    }

    @MainActor func testSelectingAChipFocusesThatTileInTheStore() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        store.setLayout(.focus)
        let ids = store.workspace.openIDs
        XCTAssertEqual(ids.count, 4)
        let chips = FocusChip.chips(for: store.tiles, focusedID: store.focused?.id)
        XCTAssertEqual(chips.filter(\.isSelected).map(\.id), [ids[0]])
        store.focus(ids[2])
        XCTAssertEqual(store.focused?.id, ids[2])
        XCTAssertEqual(FocusChip.chips(for: store.tiles, focusedID: store.focused?.id).filter(\.isSelected).map(\.id), [ids[2]])
        store.close(ids[2])
        XCTAssertEqual(store.focused?.id, ids[0], "closing the focused tile falls back to the first open tile")
        XCTAssertEqual(FocusChip.chips(for: store.tiles, focusedID: store.focused?.id).count, 3)
    }
}
