import XCTest
import AppKit
import MosaicCore
@testable import Mosaic

final class ZoomAndMotionTests: XCTestCase {
    /// One shared zoom: clamped to the offered steps, one action path, restored on relaunch, and
    /// compatible with workspaces saved before it existed.
    @MainActor func testSharedZoomClampsPersistsAndRestores() throws {
        let suite = "MosaicTest-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = WorkspaceStore(defaults: defaults, forceDemo: true)
        XCTAssertEqual(store.zoom, 1)
        XCTAssertTrue(store.canZoomIn); XCTAssertTrue(store.canZoomOut)
        store.zoomIn(); store.zoomIn()
        XCTAssertEqual(store.zoom, 1.2, accuracy: 0.001)
        XCTAssertEqual(store.zoomLabel, "120%")
        for _ in 0..<20 { store.zoomIn() }
        XCTAssertEqual(store.zoom, Workspace.zoomRange.upperBound, accuracy: 0.001, "zooming in stops at the top")
        XCTAssertFalse(store.canZoomIn)
        for _ in 0..<20 { store.zoomOut() }
        XCTAssertEqual(store.zoom, Workspace.zoomRange.lowerBound, accuracy: 0.001)
        XCTAssertFalse(store.canZoomOut)
        store.resetZoom()
        XCTAssertEqual(store.zoom, 1)
        store.setZoom(1.4321)
        XCTAssertEqual(store.zoom, 1.4, accuracy: 0.001, "values land on the steps")
        // Relaunch: the same defaults bring the same zoom back.
        store.persistNow()
        let second = WorkspaceStore(defaults: defaults, forceDemo: true)
        XCTAssertEqual(second.zoom, 1.4, accuracy: 0.001)
        // A workspace saved before zoom existed decodes at 100%.
        let old = try JSONDecoder().decode(Workspace.self, from: Data(#"{"openIDs":["a"],"layout":"grid"}"#.utf8))
        XCTAssertEqual(old.zoom, 1)
        XCTAssertEqual(Workspace.clampZoom(0.01), Workspace.zoomRange.lowerBound)
        XCTAssertEqual(Workspace.clampZoom(9), Workspace.zoomRange.upperBound)
    }

    /// The zoom keys, by the character pressed: = and + in (⌘= is the unshifted plus key), - and
    /// _ out, 0 reset; anything else is not a zoom key.
    func testZoomKeyClassification() {
        XCTAssertEqual(KeyboardRouter.zoomAction(for: "="), .zoomIn)
        XCTAssertEqual(KeyboardRouter.zoomAction(for: "+"), .zoomIn)
        XCTAssertEqual(KeyboardRouter.zoomAction(for: "-"), .zoomOut)
        XCTAssertEqual(KeyboardRouter.zoomAction(for: "_"), .zoomOut)
        XCTAssertEqual(KeyboardRouter.zoomAction(for: "0"), .reset)
        XCTAssertNil(KeyboardRouter.zoomAction(for: "f"))
        XCTAssertNil(KeyboardRouter.zoomAction(for: "o"))
    }

    /// The composer's font and margins follow the zoom, in place: the same editor keeps its text
    /// and selection, and the height bounds scale with the font.
    @MainActor func testComposerMetricsFollowZoomInPlace() {
        XCTAssertGreaterThan(ComposerEditor.minimumHeight(zoom: 1.6), ComposerEditor.minimumHeight(zoom: 1))
        XCTAssertGreaterThan(ComposerEditor.minimumHeight(zoom: 1), ComposerEditor.minimumHeight(zoom: 0.8))
        XCTAssertGreaterThan(ComposerEditor.maximumHeight(zoom: 1), ComposerEditor.minimumHeight(zoom: 1) * 4)
        XCTAssertEqual(ComposerEditor.minimumHeight, ComposerEditor.minimumHeight(zoom: 1))
        XCTAssertEqual(ComposerEditor.font(zoom: 1.5).pointSize, 18)
        let editor = DraftTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        editor.font = ComposerEditor.font(zoom: 1)
        editor.string = "Hello there"
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        editor.font = ComposerEditor.font(zoom: 1.4)
        XCTAssertEqual(editor.string, "Hello there")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 5), "a font change keeps the selection")
    }

    /// Only rows appended at the tail animate: never the initial load, a prepend, a removal, a
    /// replacement, or a burst too large to animate.
    func testOnlyAppendedTailRowsAnimateOnce() {
        typealias List = MessageList
        XCTAssertEqual(List.freshTailIDs(old: [], new: ["a", "b", "c"]), [], "the initial load is silent")
        XCTAssertEqual(List.freshTailIDs(old: ["a", "b"], new: ["a", "b", "c"]), ["c"])
        XCTAssertEqual(List.freshTailIDs(old: ["a", "b"], new: ["a", "b", "c", "d"]), ["c", "d"])
        XCTAssertEqual(List.freshTailIDs(old: ["b", "c"], new: ["a", "b", "c"]), [], "older history above is silent")
        XCTAssertEqual(List.freshTailIDs(old: ["a", "b", "c"], new: ["a", "b"]), [], "a removal is silent")
        XCTAssertEqual(List.freshTailIDs(old: ["a", "b"], new: ["a", "x", "c"]), [], "a replacement mid-thread is silent")
        XCTAssertEqual(List.freshTailIDs(old: ["a"], new: ["a"] + (0..<9).map(String.init)), [], "a burst past the limit is silent")
        XCTAssertEqual(List.freshTailIDs(old: ["a", "b"], new: ["a", "b"]), [], "a receipt or confirmation changes no identities")
    }

    /// The animation preference is persisted and off means no fresh rows at all.
    @MainActor func testAnimateMessagesPreferencePersists() {
        let suite = "MosaicTest-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = WorkspaceStore(defaults: defaults, forceDemo: true)
        XCTAssertTrue(store.animateMessages, "on by default")
        store.animateMessages = false
        XCTAssertFalse(WorkspaceStore(defaults: defaults, forceDemo: true).animateMessages)
    }
}
