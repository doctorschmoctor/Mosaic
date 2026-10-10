import XCTest
import AppKit
import SwiftUI
import MosaicCore
@testable import Mosaic

/// The keyboard and VoiceOver paths of UX-12: moving and sizing the focused tile without a
/// pointer, Focus chips that fit a narrow window, input-method composition keeping its keys,
/// the sidebar filters from the menu, and pressable accessibility elements that report enabled.
/// Fixture data only; nothing is sent.
final class KeyboardAccessTests: XCTestCase {
    @MainActor private func makeStore() -> WorkspaceStore {
        _ = NSApplication.shared
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
    }
    @MainActor private func settle(_ hosting: NSView, seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Moving and sizing tiles

    /// Move Tile Left / Right trades the focused tile's place with its neighbour's; the focus
    /// stays on it, and it stops at either end and in Focus.
    @MainActor func testMovingTheFocusedTileTradesPlaces() throws {
        let store = makeStore()
        store.tileMotionEnabled = { false }
        let order = store.openIDs
        XCTAssertGreaterThanOrEqual(order.count, 3)
        store.focus(order[1])
        XCTAssertTrue(store.canArrangeTiles)
        XCTAssertTrue(store.moveFocusedTile(by: 1))
        XCTAssertEqual(store.openIDs[2], order[1])
        XCTAssertEqual(store.openIDs[1], order[2])
        XCTAssertEqual(store.focused?.id, order[1], "the moved tile keeps the focus")
        XCTAssertTrue(store.moveFocusedTile(by: -1))
        XCTAssertTrue(store.moveFocusedTile(by: -1))
        XCTAssertEqual(store.openIDs.first, order[1])
        XCTAssertFalse(store.moveFocusedTile(by: -1), "already first")
        store.setLayout(.focus)
        XCTAssertFalse(store.canArrangeTiles)
        XCTAssertFalse(store.moveFocusedTile(by: 1), "Focus shows one tile")
    }

    /// Make Tile Wider / Taller changes the focused tile in the real workspace view (its plan is
    /// what the tiles are laid out with); Equal Tile Sizes takes it back.
    @MainActor func testSizingTheFocusedTileFromTheKeyboard() async throws {
        let store = makeStore()
        store.setLayout(.grid)
        let hosting = NSHostingView(rootView: AnyView(WorkspaceView().environment(store).frame(width: 1320, height: 860)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { hosting.rootView = AnyView(EmptyView()); window.close() }
        try await settle(hosting, seconds: 0.8)
        let first = try XCTUnwrap(store.openIDs.first)
        store.focus(first)
        func frame() throws -> CGRect { try XCTUnwrap(store.tilePlanner?(store.displayOrder).frames[first]) }
        let start = try frame()

        store.resizeFocusedTile(.wider)
        try await settle(hosting, seconds: 0.2)
        XCTAssertEqual(try frame().width, start.width + TileLayout.keyboardStep, accuracy: 0.5)
        store.resizeFocusedTile(.taller)
        try await settle(hosting, seconds: 0.2)
        XCTAssertEqual(try frame().height, start.height + TileLayout.keyboardStep, accuracy: 0.5)
        store.equalizeTiles()
        try await settle(hosting, seconds: 0.2)
        XCTAssertEqual(try frame(), start, "equal sizes again")
    }

    // MARK: Focus chips

    /// Names keep their full width while the row fits; otherwise the long ones are cut to one
    /// shared width (short ones stay whole), and when even short names would not fit, none show.
    func testChipNamesShareTheRoomFairly() {
        typealias Bar = FocusChipBar.ChipBarView
        XCTAssertEqual(Bar.fittedNameWidths([40, 200, 200], room: 1000), [40, 200, 200])
        XCTAssertEqual(Bar.fittedNameWidths([40, 200, 200], room: nil), [40, 200, 200])
        XCTAssertEqual(Bar.fittedNameWidths([40, 200, 200], room: 300), [40, 130, 130])
        XCTAssertEqual(Bar.fittedNameWidths([40, 200, 200], room: 60), [0, 0, 0])
    }

    /// Four chips with long names in the narrowest workspace stay inside the row, keep every
    /// chip pressable, and keep the names for VoiceOver and the tooltip.
    @MainActor func testChipsFitTheNarrowestWorkspace() throws {
        _ = NSApplication.shared
        let names = ["Alexandra Montgomery-Whitfield", "The Weekend Planning Committee Group", "Bartholomew Fitzgerald", "Jo"]
        let chips = names.enumerated().map { index, name in
            FocusChip(id: "c\(index)", name: name, initials: String(name.prefix(1)), isSelected: index == 0, hasUnread: index == 1, hasDraft: index == 2)
        }
        let bar = FocusChipBar.ChipBarView(frame: NSRect(x: 0, y: 0, width: 600, height: FocusChipBar.height))
        bar.chips = chips
        XCTAssertGreaterThan(bar.contentWidth, 600, "in full they would not fit")
        XCTAssertLessThanOrEqual(try XCTUnwrap(bar.frames.last).maxX, 600.5)
        XCTAssertEqual(bar.nameWidths.last ?? 0, ("Jo" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width.rounded(.up),
                       accuracy: 0.5, "a short name stays whole")
        let labels = (bar.accessibilityChildren() as? [NSAccessibilityElement])?.compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertEqual(labels.count, 4)
        XCTAssertTrue(labels[0].contains(names[0]), "VoiceOver reads the whole name")
        XCTAssertEqual(bar.view(bar, stringForToolTip: 0, point: NSPoint(x: bar.frames[0].midX, y: 10), userData: nil), names[0])

        // Narrower still: pictures only, and still one press target per chip.
        bar.setFrameSize(NSSize(width: 230, height: FocusChipBar.height))
        XCTAssertEqual(bar.nameWidths, [0, 0, 0, 0])
        XCTAssertLessThanOrEqual(try XCTUnwrap(bar.frames.last).maxX, 230.5)
        XCTAssertEqual(bar.frames.count, 4)
        // Wide again: names in full.
        bar.setFrameSize(NSSize(width: 1400, height: FocusChipBar.height))
        XCTAssertEqual(try XCTUnwrap(bar.frames.last).maxX, bar.contentWidth, accuracy: 0.5)
    }

    // MARK: Keys

    /// While an input method is composing (marked text), the window's shortcuts leave every key
    /// to the composition — ⌘F included — in any text field.
    @MainActor func testComposingWithAnInputMethodKeepsTheKeys() throws {
        let store = makeStore()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = text
        window.orderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))
        let router = KeyboardRouter()
        router.attach(window: window, store: store)
        func key(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let find = key("f", code: 3, .command)
        XCTAssertTrue(router.handle(find), "⌘F finds a conversation")
        text.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertFalse(router.handle(find), "the composition keeps ⌘F")
        XCTAssertFalse(router.handle(key("\t", code: 48, [])), "and Tab")
        XCTAssertFalse(router.handle(key("\u{1b}", code: 53, [])), "and Esc")
    }

    /// The sidebar's filters from the menu (⌃⌘1–4) do what the pills do: show the filter and
    /// start the keyboard's row over.
    @MainActor func testSidebarFilterFromTheMenu() throws {
        let store = makeStore()
        store.sidebarSelection = store.conversations.first?.id
        store.setSidebarFilter(.unread)
        XCTAssertEqual(store.sidebarFilter, .unread)
        XCTAssertNil(store.sidebarSelection)
        store.setSidebarFilter(.all)
        XCTAssertEqual(store.sidebarFilter, .all)
    }

    // MARK: VoiceOver

    /// An AppKit-drawn button (a Focus chip, a tile's close) is reported enabled while it can be
    /// pressed, so VoiceOver does not read it as dimmed.
    @MainActor func testPressableElementsReportEnabled() {
        let element = PressableAccessibilityElement()
        XCTAssertFalse(element.isAccessibilityEnabled())
        var pressed = 0
        element.onPress = { pressed += 1 }
        XCTAssertTrue(element.isAccessibilityEnabled())
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
    }
}
