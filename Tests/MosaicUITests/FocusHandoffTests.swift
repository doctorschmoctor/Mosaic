import XCTest
import AppKit
import SwiftUI
import MosaicCore
@testable import Mosaic

/// The workspace in a real window, opened the ways a person opens a conversation, with the
/// window's first responder checked afterwards — not the store's request. Each check waits for
/// the request to finish and then a little longer, so a late hand-over (or a stale one taking the
/// keyboard back) would show.
///
/// The test window is never key (the test runner is not an active app), so a synthesized click
/// cannot be delivered; a click is reproduced by its two effects instead: the press gives the
/// list's table the keyboard, as AppKit does for the view under a press, and cancels any pending
/// request, as the press monitor does; the release runs the row's action (`pressRow`). Return is a
/// real key event sent to the window, through the search field's editor or the list's keyboard.
final class FocusHandoffTests: XCTestCase {
    @MainActor private struct Host {
        let store: WorkspaceStore
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
    }

    @MainActor private func makeHost(layout: WorkspaceLayout) async throws -> Host {
        _ = NSApplication.shared
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        store.setLayout(layout)
        let hosting = NSHostingView(rootView: AnyView(WorkspaceView().environment(store).frame(width: 1320, height: 860)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        let host = Host(store: store, window: window, hosting: hosting)
        try await settle(host, seconds: 1.2)
        XCTAssertTrue(store.composerFocus.window === window, "the workspace told its focus hand-over which window it is in")
        return host
    }
    @MainActor private func close(_ host: Host) {
        host.hosting.rootView = AnyView(EmptyView())
        host.window.close()
    }
    /// Lets SwiftUI, AppKit and the run loop run for a while.
    @MainActor private func settle(_ host: Host, seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            host.hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    /// Waits for the pending request to finish (confirmed, cancelled or given up), then a little
    /// longer: a late hand-over or a stolen keyboard would show by then.
    @MainActor private func settleFocus(_ host: Host) async throws {
        let end = Date().addingTimeInterval(3)
        while host.store.composerFocus.pending != nil, Date() < end {
            host.hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try await settle(host, seconds: 0.35)
    }

    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let found = find(type, in: subview) { return found } }
        return nil
    }
    @MainActor private func describe(_ responder: NSResponder?) -> String { ComposerFocus.name(of: responder) }
    @MainActor private func isSearchField(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as? NSTextField)?.placeholderString == "Find a conversation"
    }

    /// A click on a conversation's row (see the class comment).
    @MainActor private func click(row id: String, in host: Host) throws {
        let table = try XCTUnwrap(find(NSTableView.self, in: host.hosting), "the conversation list is a table")
        host.store.composerFocus.readerPressed()
        host.window.makeFirstResponder(table)
        host.store.pressRow(id, clickCount: 1)
    }
    @MainActor private func press(_ keyCode: UInt16, _ characters: String, in host: Host) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: host.window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        host.window.sendEvent(event)
    }
    @MainActor private func typeText(_ text: String, in host: Host) {
        for character in text { press(0, String(character), in: host) }
    }

    /// The keyboard is in this conversation's live message field, which takes typing at its
    /// caret, and the request that asked for it was confirmed.
    @MainActor private func assertKeyboard(in id: String, _ host: Host, _ note: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        guard let editor = DraftTextView.editor(for: id), editor.window === host.window else {
            XCTFail("\(note): no message field for \(id) in the window", file: file, line: line); return
        }
        XCTAssertTrue(host.window.firstResponder === editor,
                      "\(note): the keyboard should be in \(id)'s field; it is in \(describe(host.window.firstResponder))", file: file, line: line)
        XCTAssertTrue(editor.isEditable, "\(note): the field takes typing", file: file, line: line)
        XCTAssertEqual(editor.selectedRange().length, 0, "\(note): a caret, not a selection", file: file, line: line)
        XCTAssertNil(host.store.composerFocus.pending, "\(note): nothing is left pending", file: file, line: line)
        XCTAssertEqual(host.store.composerFocus.lastCompleted?.conversationID, id, "\(note): the request was confirmed", file: file, line: line)
    }
    @MainActor private func closedConversation(_ store: WorkspaceStore, after skipping: Int = 0) throws -> String {
        let closed = store.filteredConversations.map(\.id).filter { !store.openIDs.contains($0) }
        return try XCTUnwrap(closed.dropFirst(skipping).first, "a conversation without a tile")
    }

    // MARK: Opening

    /// A click on a row puts the cursor in the conversation's field: into free space, in place of
    /// the tile used longest ago, and on a row whose tile is already open — in every layout.
    @MainActor private func checkClicks(layout: WorkspaceLayout) async throws {
        let host = try await makeHost(layout: layout)
        defer { close(host) }
        let store = host.store
        store.close(store.openIDs[3])
        try await settle(host, seconds: 0.3)

        let free = try closedConversation(store)
        try click(row: free, in: host)
        try await settleFocus(host)
        XCTAssertTrue(store.openIDs.contains(free))
        assertKeyboard(in: free, host, "[\(layout)] a closed row, free space")
        typeText("ok", in: host)
        XCTAssertEqual(store.drafts[free]?.hasSuffix("ok"), true, "[\(layout)] typing lands in the field")

        let replacing = try closedConversation(store)
        XCTAssertEqual(store.openIDs.count, Workspace.maximumTiles)
        try click(row: replacing, in: host)
        try await settleFocus(host)
        XCTAssertTrue(store.openIDs.contains(replacing))
        assertKeyboard(in: replacing, host, "[\(layout)] a closed row, replacing the tile used longest ago")

        let open = try XCTUnwrap(store.openIDs.first { $0 != replacing })
        try click(row: open, in: host)
        try await settleFocus(host)
        assertKeyboard(in: open, host, "[\(layout)] a row whose tile is open")
    }
    @MainActor func testAClickOnARowPutsTheCursorInItsFieldInGrid() async throws { try await checkClicks(layout: .grid) }
    @MainActor func testAClickOnARowPutsTheCursorInItsFieldInColumns() async throws { try await checkClicks(layout: .columns) }
    @MainActor func testAClickOnARowPutsTheCursorInItsFieldInFocus() async throws { try await checkClicks(layout: .focus) }

    /// Return in the search field opens the first match with the cursor in its field; Return on
    /// the list's row (⌘L, then the keyboard) does the same.
    @MainActor func testReturnInTheSearchFieldOrTheListPutsTheCursorInTheField() async throws {
        for layout in [WorkspaceLayout.grid, .columns, .focus] {
            let host = try await makeHost(layout: layout)
            defer { close(host) }
            let store = host.store

            NotificationCenter.default.post(name: .focusSearch, object: nil)
            try await settle(host, seconds: 0.3)
            XCTAssertTrue(isSearchField(host.window.firstResponder), "[\(layout)] ⌘F gives the search field the keyboard; it is in \(describe(host.window.firstResponder))")
            let closed = try closedConversation(store)
            store.search = try XCTUnwrap(store.conversations.first { $0.id == closed }?.name)
            try await settle(host, seconds: 0.2)
            // Return opens the first match (the closed conversation, or one whose name contains its name).
            let target = try XCTUnwrap(store.filteredConversations.first?.id)
            press(36, "\r", in: host)
            try await settleFocus(host)
            assertKeyboard(in: target, host, "[\(layout)] Return in the search field")
            store.search = ""

            NotificationCenter.default.post(name: .focusConversationList, object: nil)
            try await settle(host, seconds: 0.2)
            XCTAssertTrue(host.window.firstResponder is SidebarKeyFocus.CatcherView, "[\(layout)] ⌘L gives the list the keyboard")
            let row = try closedConversation(store)
            store.selectSidebarRow(row)
            press(36, "\r", in: host)
            try await settleFocus(host)
            assertKeyboard(in: row, host, "[\(layout)] Return on a row in the list")

            NotificationCenter.default.post(name: .focusConversationList, object: nil)
            try await settle(host, seconds: 0.2)
            let open = try XCTUnwrap(store.openIDs.first { $0 != row })
            store.selectSidebarRow(open)
            press(36, "\r", in: host)
            try await settleFocus(host)
            assertKeyboard(in: open, host, "[\(layout)] Return on a row whose tile is open")
        }
    }

    /// In Focus, choosing a chip shows that tile with the cursor in its field.
    @MainActor func testChoosingAFocusChipPutsTheCursorInThatTile() async throws {
        let host = try await makeHost(layout: .focus)
        defer { close(host) }
        let store = host.store
        let bar = try XCTUnwrap(find(FocusChipBar.ChipBarView.self, in: host.hosting))
        let target = try XCTUnwrap(store.openIDs.first { $0 != store.focused?.id })
        let index = try XCTUnwrap(bar.chips.firstIndex { $0.id == target })
        let point = bar.convert(NSPoint(x: bar.frames[index].midX, y: bar.frames[index].midY), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if kind == .leftMouseDown { bar.mouseDown(with: event) } else { bar.mouseUp(with: event) }
        }
        try await settleFocus(host)
        XCTAssertEqual(store.focused?.id, target)
        assertKeyboard(in: target, host, "a Focus chip")
    }

    // MARK: Requests that must give way

    /// Switching rows quickly ends with the cursor in the last one chosen, however little time
    /// passes between the clicks.
    @MainActor func testRapidSwitchingEndsInTheLastConversationChosen() async throws {
        let host = try await makeHost(layout: .grid)
        defer { close(host) }
        let store = host.store
        let a = store.openIDs[0], b = store.openIDs[1]
        try click(row: a, in: host)
        try click(row: b, in: host)
        try await settleFocus(host)
        assertKeyboard(in: b, host, "two clicks in the same turn")
        for (round, pause) in [0.0, 0.002, 0.01, 0.03, 0.0, 0.05].enumerated() {
            let first = round.isMultiple(of: 2) ? a : b, last = round.isMultiple(of: 2) ? b : a
            try click(row: first, in: host)
            if pause > 0 { try await settle(host, seconds: pause) }
            let closed = try closedConversation(store)
            try click(row: round == 3 ? closed : last, in: host)
            try await settleFocus(host)
            assertKeyboard(in: round == 3 ? closed : last, host, "round \(round), \(pause)s apart")
        }
    }

    /// A choice the reader makes right after asking — ⌘F, another message field, closing the
    /// tile — keeps the keyboard: the earlier request never takes it back.
    @MainActor func testAChoiceMadeRightAfterwardKeepsTheKeyboard() async throws {
        for layout in [WorkspaceLayout.grid, .columns] {
            let host = try await makeHost(layout: layout)
            defer { close(host) }
            let store = host.store

            try click(row: store.openIDs[0], in: host)
            NotificationCenter.default.post(name: .focusSearch, object: nil)
            try await settleFocus(host)
            XCTAssertTrue(isSearchField(host.window.firstResponder), "[\(layout)] ⌘F right after: the search field keeps the keyboard; it is in \(describe(host.window.firstResponder))")
            XCTAssertNil(store.composerFocus.pending)

            let other = try XCTUnwrap(DraftTextView.editor(for: store.openIDs[2]))
            try click(row: store.openIDs[1], in: host)
            // A press in another tile's field: the press cancels, the field takes the keyboard.
            store.composerFocus.readerPressed()
            host.window.makeFirstResponder(other)
            try await settleFocus(host)
            XCTAssertTrue(host.window.firstResponder === other, "[\(layout)] another field chosen right after keeps the keyboard; it is in \(describe(host.window.firstResponder))")

            NotificationCenter.default.post(name: .focusConversationList, object: nil)
            try await settle(host, seconds: 0.1)
            let closing = try closedConversation(store)
            try click(row: closing, in: host)
            store.close(closing)
            try await settleFocus(host)
            XCTAssertNil(store.composerFocus.pending, "[\(layout)] closing the tile drops its request")
            XCTAssertNil(DraftTextView.editor(for: closing)?.window)
            XCTAssertFalse(host.window.firstResponder is DraftTextView && (host.window.firstResponder as? DraftTextView)?.conversationID == closing)
        }
    }

    /// A field that already has the keyboard keeps its selection when asked again (a click in
    /// its own thread, the Photos card closing).
    @MainActor func testAFieldThatHasTheKeyboardKeepsItsSelection() async throws {
        let host = try await makeHost(layout: .grid)
        defer { close(host) }
        let store = host.store
        let id = store.openIDs[0]
        store.requestComposerFocus(id)
        try await settleFocus(host)
        typeText("hello there", in: host)
        let editor = try XCTUnwrap(DraftTextView.editor(for: id))
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let claims = store.composerFocus.claimCount
        store.requestComposerFocus(id)
        try await settleFocus(host)
        XCTAssertTrue(host.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0), "the caret stays where it was")
        XCTAssertEqual(store.composerFocus.claimCount, claims, "nothing was handed over")
    }

    /// ⌥⌘F opens the focused tile's find bar with the keyboard in it; Esc closes it and the
    /// keyboard goes back to the tile's message field.
    @MainActor func testTheFindBarTakesTheKeyboardAndGivesItBack() async throws {
        let host = try await makeHost(layout: .grid)
        defer { close(host) }
        let store = host.store
        let id = try XCTUnwrap(store.focused?.id)
        store.beginFind()
        try await settle(host, seconds: 0.4)
        let field = host.window.firstResponder as? NSTextView
        XCTAssertEqual((field?.delegate as? NSTextField)?.placeholderString, "Find in loaded messages",
                       "the find field has the keyboard; it is in \(describe(host.window.firstResponder))")
        XCTAssertEqual(store.activeFindTile, id)
        typeText("coffee", in: host)
        try await settle(host, seconds: 0.4)
        XCTAssertTrue(store.findStep(older: true), "⌘G steps through the open bar's matches")
        XCTAssertNil(store.drafts[id].flatMap { $0.contains("coffee") ? $0 : nil }, "typing went to the find field, not the draft")
        press(53, "\u{1b}", in: host)
        try await settleFocus(host)
        XCTAssertNil(store.activeFindTile, "Esc closed the bar")
        assertKeyboard(in: id, host, "Esc in the find bar")
    }

    /// Opening conversations again and again, by every route, never leaves the keyboard elsewhere.
    @MainActor func testRepeatedOpeningsNeverLoseTheKeyboard() async throws {
        let host = try await makeHost(layout: .grid)
        defer { close(host) }
        let store = host.store
        for round in 0..<12 {
            let target: String
            switch round % 4 {
            case 0:
                target = try closedConversation(store)
                try click(row: target, in: host)
            case 1:
                target = try XCTUnwrap(store.openIDs.first { $0 != store.focused?.id })
                try click(row: target, in: host)
            case 2:
                NotificationCenter.default.post(name: .focusConversationList, object: nil)
                try await settle(host, seconds: 0.05)
                target = try closedConversation(store)
                store.selectSidebarRow(target)
                press(36, "\r", in: host)
            default:
                target = try XCTUnwrap(store.openIDs.last { $0 != store.focused?.id })
                store.requestComposerFocus(target)
            }
            try await settleFocus(host)
            assertKeyboard(in: target, host, "round \(round)")
        }
    }
}
