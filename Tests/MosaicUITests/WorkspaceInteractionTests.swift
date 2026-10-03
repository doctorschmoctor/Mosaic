import XCTest
import MosaicCore
@testable import Mosaic

final class WorkspaceInteractionTests: XCTestCase {
    @MainActor func testContactsUpdateImmediatelyDuringAnActiveMessagesRefresh() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        store.conversations = [Conversation(id: "a", name: "4155550123", participants: ["+14155550123"]),
                               Conversation(id: "b", name: "+14155550123", participants: [])]
        store.isRefreshing = true
        store.applyContactNames(ContactNames(entries: [.init(id: "contact", name: "Alex Morgan", addresses: ["(415) 555-0123"])], region: "US"))
        XCTAssertEqual(store.conversations[0].name, "Alex Morgan")
        XCTAssertEqual(store.conversations[1].name, "Alex Morgan")
        store.search = "Alex"
        XCTAssertEqual(store.filteredConversations.map(\.id), ["a", "b"])
        XCTAssertEqual(store.contactStatus, "Loaded 1 contacts · Matched 2 of 2 conversations.")
    }
    @MainActor func testLiveDragOnlyCommitsOnReleaseAndPreservesDrafts() throws {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let ids = store.workspace.openIDs
        let plan = TileLayout.plan(order: ids, viewport: CGSize(width: 1000, height: 820), layout: .grid)
        let a = try XCTUnwrap(plan.frames[ids[0]]), last = try XCTUnwrap(plan.frames[ids[3]])
        store.workspace.drafts[ids[0]] = "Keep this draft"
        store.dragTile(ids[0], translation: CGSize(width: last.midX - a.midX, height: last.midY - a.midY), plan: plan)
        XCTAssertEqual(store.workspace.openIDs, ids)
        XCTAssertEqual(store.tileDrag?.order, [ids[1], ids[2], ids[3], ids[0]])
        store.finishTileDrag()
        XCTAssertEqual(store.workspace.openIDs, [ids[1], ids[2], ids[3], ids[0]])
        XCTAssertNil(store.tileDrag)
        XCTAssertEqual(store.workspace.drafts[ids[0]], "Keep this draft")
    }

    /// Opening and closing many conversations quickly, in every layout, must keep the workspace
    /// consistent: no duplicate tiles, never more than the maximum, focus always on an open tile.
    @MainActor func testRapidOpenCloseAndLayoutChurnKeepsTheWorkspaceConsistent() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let all = store.conversations.map(\.id)
        var generator = SystemRandomNumberGenerator()
        store.workspace.drafts[all[0]] = "draft survives churn"
        for step in 0..<600 {
            let id = all[Int.random(in: 0..<all.count, using: &generator)]
            switch step % 7 {
            case 0, 1, 2: store.open(id)
            case 3: store.close(id)
            case 4: store.focus(id)
            case 5: store.setLayout(WorkspaceLayout.allCases[step % WorkspaceLayout.allCases.count])
            default: store.requestComposerFocus(id)
            }
            let open = store.workspace.openIDs
            XCTAssertEqual(Set(open).count, open.count, "duplicate tile after step \(step)")
            XCTAssertLessThanOrEqual(open.count, Workspace.maximumTiles)
            XCTAssertEqual(store.tiles.map(\.id), open)
            if let focused = store.workspace.focusedID { XCTAssertTrue(open.contains(focused), "focus left the open tiles at step \(step)") }
            else { XCTAssertTrue(open.isEmpty) }
            if let target = store.focusTarget { XCTAssertTrue(open.contains(target)) }
            XCTAssertEqual(store.focused?.id, store.workspace.focusedID ?? open.first)
            // Every layout has a frame for every tile it shows.
            let order = store.workspace.layout == .focus ? store.focused.map { [$0.id] } ?? [] : store.displayOrder
            let plan = TileLayout.plan(order: order, viewport: CGSize(width: 1100, height: 700), layout: store.workspace.layout)
            XCTAssertEqual(Set(plan.frames.keys), Set(order))
        }
        XCTAssertEqual(store.workspace.drafts[all[0]], "draft survives churn")
    }

    @MainActor func testDeletingAConversationClosesItsTileAndHidesItUntilNewActivity() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let id = store.workspace.openIDs[1]
        store.hide(id)
        XCTAssertFalse(store.workspace.openIDs.contains(id), "the tile closes")
        XCTAssertFalse(store.filteredConversations.contains { $0.id == id }, "the sidebar no longer lists it")
        XCTAssertTrue(store.conversations.contains { $0.id == id }, "but it is still a conversation on this Mac")
        XCTAssertNotNil(store.hidden[id])
        XCTAssertEqual(store.workspace.hidden, store.hidden)
    }

    @MainActor func testNewMessageTileAddressesPeopleAndBecomesTheConversationWhenSent() async {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        store.close(store.workspace.openIDs[0])
        let draftID = store.beginNewChat()!
        XCTAssertTrue(store.workspace.openIDs.contains(draftID))
        XCTAssertEqual(store.workspace.focusedID, draftID)
        XCTAssertEqual(store.tiles.first { $0.id == draftID }?.isComposeDraft, true)
        // Suggestions: typing part of a name offers the conversations with that name.
        let existing = store.conversations.first { $0.name == "Sam Rivera" }!
        let suggestions = store.recipientSuggestions(for: "sam", excluding: draftID)
        XCTAssertTrue(suggestions.contains(.conversation(existing)))
        // Addressing the draft to an existing person then sending goes to that conversation.
        store.addRecipient(Recipient(address: existing.participants[0], name: existing.name), to: draftID)
        XCTAssertEqual(store.conversation(with: store.composeDrafts[draftID]!.recipients)?.id, existing.id)
        store.workspace.drafts[draftID] = "Hey Sam"
        await store.send(draftID)
        XCTAssertFalse(store.workspace.openIDs.contains(draftID), "the new-message tile became the conversation")
        XCTAssertTrue(store.workspace.openIDs.contains(existing.id))
        XCTAssertEqual(store.workspace.focusedID, existing.id)
        XCTAssertEqual(store.conversations.first { $0.id == existing.id }?.messages.last?.text, "Hey Sam")
        XCTAssertNil(store.composeDrafts[draftID])
        // A full workspace cannot start a new message.
        for id in store.conversations.map(\.id) where !store.workspace.openIDs.contains(id) && store.workspace.openIDs.count < Workspace.maximumTiles { store.open(id) }
        XCTAssertNil(store.beginNewChat())
        XCTAssertNotNil(store.alert, "a full workspace explains itself in an alert")
    }

    @MainActor func testKeyboardTraversalSkipsNothingAndWrapsAround() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let ids = store.workspace.openIDs
        XCTAssertTrue(store.moveFocus(forward: true, from: nil))
        XCTAssertEqual(store.focusTarget, ids[1], "one press moves away from the highlighted first tile")
        XCTAssertTrue(store.moveFocus(forward: true, from: ids[3]))
        XCTAssertEqual(store.focusTarget, ids[0])
        XCTAssertTrue(store.moveFocus(forward: false, from: ids[0]))
        XCTAssertEqual(store.focusTarget, ids[3])
        for id in ids { store.close(id) }
        XCTAssertFalse(store.moveFocus(forward: true, from: nil))
    }

    /// The conversation list on the keyboard (⌘L, or ↓ from search): entering lands on the focused
    /// tile's row, the arrow keys move and stop at the ends, Return opens or focuses, Delete closes
    /// the row's tile, and a full workspace says so.
    @MainActor func testSidebarKeyboardMovesOpensAndUntilesRows() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let rows = store.filteredConversations.map(\.id)
        let open = store.workspace.openIDs
        XCTAssertEqual(open.count, Workspace.maximumTiles)
        XCTAssertGreaterThan(rows.count, open.count)
        store.focus(open[2])
        store.selectSidebarRow(nil)
        XCTAssertEqual(store.sidebarSelection, open[2], "entering the list lands on the focused tile's row")
        store.sidebarSelection = nil
        store.moveSidebarSelection(by: 1)
        XCTAssertEqual(store.sidebarSelection, rows[0], "↓ with no row starts at the top")
        store.moveSidebarSelection(by: -1)
        XCTAssertEqual(store.sidebarSelection, rows[0], "the first row stops ↑")
        store.sidebarSelection = nil
        store.moveSidebarSelection(by: -1)
        XCTAssertEqual(store.sidebarSelection, rows.last, "↑ with no row starts at the bottom")
        store.moveSidebarSelection(by: 1)
        XCTAssertEqual(store.sidebarSelection, rows.last, "the last row stops ↓")
        // Return on a closed row with every tile taken: an alert, nothing opens.
        let closed = rows.first { !open.contains($0) }!
        store.sidebarSelection = closed
        store.activateSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, open)
        XCTAssertNotNil(store.alert)
        store.alert = nil
        // Delete on an open row closes its tile; on a closed row it does nothing.
        store.sidebarSelection = open[1]
        store.untileSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, [open[0], open[2], open[3]])
        store.sidebarSelection = closed
        store.untileSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, [open[0], open[2], open[3]])
        // Return now opens the closed row, and Return on an open row focuses it.
        store.activateSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, [open[0], open[2], open[3], closed])
        XCTAssertEqual(store.workspace.focusedID, closed)
        XCTAssertNil(store.alert)
        store.sidebarSelection = open[0]
        store.activateSidebarSelection()
        XCTAssertEqual(store.workspace.focusedID, open[0])
        XCTAssertEqual(store.workspace.openIDs.count, Workspace.maximumTiles)
        // A search narrows the rows the keyboard moves through; Return in search opens the first match.
        store.sidebarSelection = nil
        store.search = "Riley"
        let matches = store.filteredConversations.map(\.id)
        XCTAssertFalse(matches.isEmpty)
        store.moveSidebarSelection(by: 1)
        XCTAssertEqual(store.sidebarSelection, matches[0])
        store.sidebarSelection = nil
        store.close(open[0])
        store.activateSidebarSelection()
        XCTAssertTrue(store.workspace.openIDs.contains(matches[0]), "Return in search opens the first match")
    }

    /// The invisible view that holds the keyboard for the list: taking the keyboard marks a row,
    /// the keys move, open and close, and giving the keyboard up clears the mark.
    @MainActor func testSidebarKeyFocusViewHandlesTheKeysAndClearsOnResign() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let rows = store.filteredConversations.map(\.id)
        XCTAssertTrue(store.workspace.openIDs.contains(rows[0]), "the demo workspace opens the first rows")
        let keyboard = SidebarKeyboard()
        let view = SidebarKeyFocus.CatcherView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.store = store
        keyboard.view = view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        XCTAssertFalse(keyboard.hasKeyboard)
        XCTAssertNil(view.hitTest(NSPoint(x: 0.5, y: 0.5)), "invisible to the mouse")
        XCTAssertTrue(keyboard.focusList(.first))
        XCTAssertTrue(keyboard.hasKeyboard)
        XCTAssertEqual(store.sidebarSelection, rows[0])
        func press(_ keyCode: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
            view.keyDown(with: event)
        }
        press(125); XCTAssertEqual(store.sidebarSelection, rows[1], "↓")
        press(126); XCTAssertEqual(store.sidebarSelection, rows[0], "↑")
        press(119); XCTAssertEqual(store.sidebarSelection, rows.last, "End")
        press(115); XCTAssertEqual(store.sidebarSelection, rows[0], "Home")
        press(51); XCTAssertFalse(store.workspace.openIDs.contains(rows[0]), "Delete closes the row's tile")
        XCTAssertEqual(store.sidebarSelection, rows[0], "the row stays marked")
        press(36); XCTAssertTrue(store.workspace.openIDs.contains(rows[0]), "Return opens it again")
        XCTAssertTrue(keyboard.hasKeyboard, "opening a tile from the list keeps the keyboard in the list")
        XCTAssertTrue(keyboard.focusList(.current), "focusing the list again, while it has the keyboard, is a no-op that succeeds")
        XCTAssertEqual(store.sidebarSelection, rows[0])
        window.makeFirstResponder(nil)
        XCTAssertFalse(keyboard.hasKeyboard)
        XCTAssertNil(store.sidebarSelection, "giving up the keyboard clears the mark")
        XCTAssertTrue(keyboard.focusList(.last))
        XCTAssertEqual(store.sidebarSelection, rows.last)
    }

    /// The sidebar's scroller tells a sideways swipe (a row's Delete action) from a scroll: the
    /// knob hides and swipe mode starts, and the direction a gesture settles on holds for the rest
    /// of that gesture.
    @MainActor func testThinScrollerTellsSidewaysSwipesFromScrolls() {
        let scroller = ThinScroller()
        var reports: [Bool] = []
        scroller.onSwipeModeChange = { reports.append($0) }
        scroller.track(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0)
        XCTAssertFalse(scroller.isSwiping, "nothing is known at the start of a gesture")
        scroller.track(phase: .changed, momentumPhase: [], deltaX: -12, deltaY: 1)
        XCTAssertTrue(scroller.isSwiping)
        XCTAssertTrue(scroller.isSuppressed)
        scroller.track(phase: .changed, momentumPhase: [], deltaX: -2, deltaY: 5)
        XCTAssertTrue(scroller.isSwiping, "a finger that wanders keeps the gesture's direction")
        scroller.track(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0)
        XCTAssertTrue(scroller.isSwiping, "the revealed action outlives the gesture")
        scroller.track(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0)
        scroller.track(phase: .changed, momentumPhase: [], deltaX: 1, deltaY: -30)
        XCTAssertFalse(scroller.isSwiping, "a vertical scroll ends swipe mode")
        XCTAssertFalse(scroller.isSuppressed)
        scroller.track(phase: [], momentumPhase: [], deltaX: 0, deltaY: -3)
        XCTAssertFalse(scroller.isSwiping, "a mouse wheel is never a swipe")
        XCTAssertEqual(reports, [true, false])
    }
}
