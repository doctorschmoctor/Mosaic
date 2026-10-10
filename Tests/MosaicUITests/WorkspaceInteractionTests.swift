import XCTest
import AppKit
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

    /// Request routing only: opening a conversation from the list asks for the keyboard in its
    /// tile's message field, whether it opens into free space, takes the place of the tile used
    /// longest ago, or is already open. A request is not cursor placement — `FocusHandoffTests`
    /// checks the window's first responder in a real window.
    @MainActor func testOpeningFromTheListRoutesAComposerFocusRequest() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let all = store.conversations.map(\.id)
        let open = store.workspace.openIDs
        store.close(open[3])
        let free = all.first { !store.workspace.openIDs.contains($0) }!
        store.openAndType(free)
        XCTAssertTrue(store.workspace.openIDs.contains(free))
        XCTAssertEqual(store.focusTarget, free, "into free space")
        let replacing = all.first { !store.workspace.openIDs.contains($0) }!
        store.openAndType(replacing)
        XCTAssertEqual(store.workspace.openIDs.count, Workspace.maximumTiles)
        XCTAssertEqual(store.focusTarget, replacing, "in place of the tile used longest ago")
        let token = store.focusToken
        store.openAndType(open[1])
        XCTAssertEqual(store.focusTarget, open[1], "an open tile is found")
        XCTAssertGreaterThan(store.focusToken, token)
        XCTAssertEqual(store.composerFocus.pending, ComposerFocus.Request(conversationID: open[1], token: store.focusToken),
                       "the newest request is the one pending")
        store.close(open[1])
        XCTAssertNil(store.composerFocus.pending, "closing the tile cancels its request")
    }

    /// The list stays at the top when a message moves a conversation there: it was at the top
    /// when the row that was first starts at the visible area's top edge (the list held on to it)
    /// or the list shows its first row; scrolled further down, it stays put.
    @MainActor func testConversationListStaysAtTheTopForANewArrival() {
        final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 30 }
        }
        let rows = Rows()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 1200))
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.rowHeight = 38
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = rows
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = table
        table.reloadData()
        table.tile()
        let pin = ListTopPin()
        pin.attach(scroll)
        let order = (0..<30).map { "c\($0)" }
        // The new arrival is c0; c1 was first. The list held on to c1 at the top edge.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 1).minY))
        XCTAssertTrue(pin.wasAtTop(oldFirst: "c1", in: order))
        scroll.contentView.scroll(to: .zero)
        XCTAssertTrue(pin.wasAtTop(oldFirst: "c1", in: order), "already at the top")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 8).minY))
        XCTAssertFalse(pin.wasAtTop(oldFirst: "c1", in: order), "scrolled down on purpose: it stays")
        XCTAssertTrue(ListTopPin.firstChanged(from: "c1", to: "c0"))
        XCTAssertFalse(ListTopPin.firstChanged(from: "c0", to: "c0"))
        XCTAssertFalse(ListTopPin.firstChanged(from: nil, to: "c0"))
    }

    /// A held tile lifts and follows the pointer; crossing into another tile's place moves that
    /// tile, which springs from where it was; the release commits the order and the held tile
    /// springs from where it was dropped into its place, then comes back down.
    @MainActor func testHeldTileLiftsFollowsThePointerAndTilesSpringIntoPlace() async throws {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let ids = store.workspace.openIDs
        let viewport = CGSize(width: 1000, height: 820)
        store.tilePlanner = { TileLayout.plan(order: $0, viewport: viewport, layout: .grid) }
        store.tileMotionEnabled = { true }
        let plan = TileLayout.plan(order: ids, viewport: viewport, layout: .grid)
        let a = try XCTUnwrap(plan.frames[ids[0]]), b = try XCTUnwrap(plan.frames[ids[1]])

        store.dragTile(ids[0], translation: CGSize(width: 10, height: 5), plan: plan)
        XCTAssertEqual(store.heldTile?.id, ids[0])
        XCTAssertEqual(store.heldTile?.size, a.size)
        XCTAssertEqual(store.liftedTile, ids[0])
        XCTAssertEqual(store.dragMotion.origin, CGPoint(x: a.minX + 10, y: a.minY + 5))
        XCTAssertTrue(store.tileSprings.isEmpty, "no reorder, nothing springs")
        XCTAssertEqual(store.displayOrder, ids)

        store.dragTile(ids[0], translation: CGSize(width: b.midX - a.midX + 7, height: 4), plan: plan)
        XCTAssertEqual(store.displayOrder, [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertEqual(store.tileSprings[ids[1]], CGSize(width: b.minX - a.minX, height: b.minY - a.minY), "starts where it was")
        XCTAssertNil(store.tileSprings[ids[0]], "the held tile follows the pointer, not a spring")
        XCTAssertEqual(store.workspace.openIDs, ids, "nothing is committed before the release")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.tileSprings.isEmpty, "the offsets spring to zero")

        let dropped = store.dragMotion.origin
        store.finishTileDrag()
        XCTAssertEqual(store.workspace.openIDs, [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertNil(store.heldTile)
        XCTAssertNil(store.tileDrag)
        let landing = try XCTUnwrap(store.tilePlanner?(store.workspace.openIDs).frames[ids[0]])
        XCTAssertEqual(store.tileSprings[ids[0]], CGSize(width: dropped.x - landing.minX, height: dropped.y - landing.minY))
        XCTAssertEqual(store.settlingTile, ids[0])
        XCTAssertEqual(store.liftedTile, ids[0], "still lifted until it lands")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.tileSprings.isEmpty)
        XCTAssertNil(store.liftedTile)
    }

    /// With Reduce Motion, tiles move in one step: no springs, and nothing stays lifted.
    @MainActor func testTileDragWithoutMotionMovesInOneStep() throws {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let ids = store.workspace.openIDs
        let viewport = CGSize(width: 1000, height: 820)
        store.tilePlanner = { TileLayout.plan(order: $0, viewport: viewport, layout: .grid) }
        store.tileMotionEnabled = { false }
        let plan = TileLayout.plan(order: ids, viewport: viewport, layout: .grid)
        let a = try XCTUnwrap(plan.frames[ids[0]]), b = try XCTUnwrap(plan.frames[ids[1]])
        store.dragTile(ids[0], translation: CGSize(width: b.midX - a.midX, height: 0), plan: plan)
        XCTAssertEqual(store.displayOrder, [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertTrue(store.tileSprings.isEmpty)
        store.finishTileDrag()
        XCTAssertTrue(store.tileSprings.isEmpty)
        XCTAssertNil(store.liftedTile)
        XCTAssertNil(store.settlingTile)
        // A drag that ends because its tile closed leaves nothing lifted either.
        store.tileMotionEnabled = { true }
        store.dragTile(ids[2], translation: CGSize(width: 5, height: 5), plan: TileLayout.plan(order: store.workspace.openIDs, viewport: viewport, layout: .grid))
        XCTAssertEqual(store.liftedTile, ids[2])
        store.close(ids[2])
        XCTAssertNil(store.heldTile)
        XCTAssertNil(store.liftedTile)
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

    @MainActor func testHidingAConversationClosesItsTileAndHidesItUntilNewActivity() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let id = store.workspace.openIDs[1]
        store.hide(id)
        XCTAssertFalse(store.workspace.openIDs.contains(id), "the tile closes")
        XCTAssertFalse(store.filteredConversations.contains { $0.id == id }, "the sidebar no longer lists it")
        XCTAssertTrue(store.conversations.contains { $0.id == id }, "but it is still a conversation on this Mac")
        XCTAssertNotNil(store.hidden[id])
        XCTAssertEqual(store.workspace.hidden, store.hidden)
    }

    @MainActor func testNewMessageTileAddressesPeopleAndBecomesTheConversationWhenSent() async throws {
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
        // A full workspace still starts a new message: the tile used longest ago makes room.
        for id in store.conversations.map(\.id) where !store.workspace.openIDs.contains(id) && store.workspace.openIDs.count < Workspace.maximumTiles { store.open(id) }
        XCTAssertEqual(store.workspace.openIDs.count, Workspace.maximumTiles)
        let victim = try XCTUnwrap(store.tileToReplace())
        let position = try XCTUnwrap(store.workspace.openIDs.firstIndex(of: victim))
        let newDraft = try XCTUnwrap(store.beginNewChat())
        XCTAssertNil(store.alert)
        XCTAssertEqual(store.workspace.openIDs.count, Workspace.maximumTiles)
        XCTAssertEqual(store.workspace.openIDs[position], newDraft, "the new message takes the replaced tile's place")
        XCTAssertFalse(store.workspace.openIDs.contains(victim))
    }

    /// Opening a fifth conversation replaces the tile used longest ago — opened, focused, typed in
    /// or sent from — in that tile's place, so the layout keeps its shape; an unsent New Message
    /// is never the one replaced while anything else is open.
    @MainActor func testOpeningAFifthConversationReplacesTheLeastRecentlyUsedTile() async throws {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let all = store.conversations.map(\.id)
        let open = store.workspace.openIDs
        XCTAssertEqual(open.count, Workspace.maximumTiles)
        // Fresh from launch, nothing has been used: the first tile on screen goes.
        store.open(all[4])
        XCTAssertEqual(store.workspace.openIDs, [all[4], open[1], open[2], open[3]])
        XCTAssertEqual(store.workspace.focusedID, all[4])
        XCTAssertNil(store.alert)
        // Using tiles changes the order: touch everything but the third, and the third goes next.
        store.focus(open[1])
        store.draft(open[3]).wrappedValue = "typing here"
        store.focus(all[4])
        store.open(all[5])
        XCTAssertEqual(store.workspace.openIDs, [all[4], open[1], all[5], open[3]])
        XCTAssertEqual(store.workspace.drafts[open[3]], "typing here", "drafts of other tiles are untouched")
        // Sending counts as use, so the tile sent from stays; a replaced tile keeps its draft for later.
        store.draft(open[1]).wrappedValue = "kept for later"
        store.workspace.drafts[all[4]] = "sent now"
        await store.send(all[4])
        store.focus(all[5]); store.focus(open[3])
        store.open(all[6])
        XCTAssertEqual(store.workspace.openIDs, [all[4], all[6], all[5], open[3]])
        XCTAssertEqual(store.workspace.drafts[open[1]], "kept for later")
        store.open(open[1])
        XCTAssertEqual(store.workspace.drafts[open[1]], "kept for later", "reopening brings the draft back")
        // An unsent New Message is not replaced while a conversation can be.
        let draftID = try XCTUnwrap(store.beginNewChat())
        XCTAssertTrue(store.workspace.openIDs.contains(draftID))
        for _ in 0..<3 { if let next = all.first(where: { !store.workspace.openIDs.contains($0) }) { store.open(next) } }
        XCTAssertTrue(store.workspace.openIDs.contains(draftID), "the New Message tile survives three replacements")
        XCTAssertEqual(store.workspace.openIDs.count, Workspace.maximumTiles)
    }

    /// A fresh install asks nothing on launch: no settings sheet, no alert, no demo workspace; it
    /// is live with an empty workspace, and the reason Messages cannot be read goes to the empty
    /// workspace rather than an alert. Once conversations are on screen, losing the connection is
    /// announced once, in an alert.
    @MainActor func testFreshInstallLaunchesQuietlyAndAnnouncesConnectionLossOnce() async throws {
        let defaults = UserDefaults(suiteName: "MosaicTest-\(UUID())")!
        let database = MessagesDatabase(path: NSTemporaryDirectory() + "mosaic-missing-\(UUID()).db")
        let store = WorkspaceStore(defaults: defaults, database: database)
        XCTAssertTrue(store.isLive, "a fresh install is live, not the demo")
        XCTAssertFalse(store.showSetup, "no settings sheet on launch")
        XCTAssertNil(store.alert)
        XCTAssertTrue(store.workspace.openIDs.isEmpty)
        XCTAssertTrue(store.conversations.isEmpty)
        for _ in 0..<200 where store.connectionError == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotNil(store.connectionError)
        XCTAssertNil(store.alert, "with nothing on screen, the empty workspace carries the message")
        // Conversations on screen, then the connection fails: one alert, not one per failed poll.
        store.conversations = [Conversation(id: "a", name: "Alex Morgan", participants: ["alex@example.test"])]
        store.connectionError = nil
        for _ in 0..<200 where store.alert == nil { await store.refresh(); try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotNil(store.alert)
        XCTAssertNotNil(store.connectionError)
        store.alert = nil
        await store.refresh()
        await store.refresh()
        XCTAssertNil(store.alert, "the same trouble is not announced again")
        store.setMode(live: false)
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
        // Return on a closed row with every tile taken: it takes the place of the tile used longest ago.
        let closed = rows.first { !open.contains($0) }!
        store.focus(open[0]); store.focus(open[1]); store.focus(open[3])
        store.sidebarSelection = closed
        store.activateSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, [open[0], open[1], closed, open[3]])
        XCTAssertEqual(store.workspace.focusedID, closed)
        XCTAssertEqual(store.focusTarget, closed, "the keyboard goes on into the new tile's composer")
        XCTAssertNil(store.alert)
        // Delete on an open row closes its tile; on a closed row it does nothing.
        store.sidebarSelection = open[1]
        store.untileSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, [open[0], closed, open[3]])
        store.sidebarSelection = open[2]
        store.untileSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, [open[0], closed, open[3]])
        // Return opens a closed row into the free space, and Return on an open row focuses it.
        store.activateSidebarSelection()
        XCTAssertEqual(store.workspace.openIDs, [open[0], closed, open[3], open[2]])
        XCTAssertEqual(store.workspace.focusedID, open[2])
        store.sidebarSelection = open[0]
        let token = store.focusToken
        store.activateSidebarSelection()
        XCTAssertEqual(store.workspace.focusedID, open[0])
        XCTAssertEqual(store.focusTarget, open[0], "an open row's tile takes the keyboard too")
        XCTAssertGreaterThan(store.focusToken, token)
        XCTAssertEqual(store.workspace.openIDs.count, Workspace.maximumTiles)
        // The one highlight is the keyboard's row; a swipe hides it until the swipe is closed.
        XCTAssertEqual(store.highlightedSidebarRow, open[0])
        store.setSidebarSwiping(true)
        XCTAssertNil(store.highlightedSidebarRow, "no highlight sits against a row's swipe action")
        XCTAssertEqual(store.sidebarSelection, open[0], "the keyboard's row itself is kept")
        store.setSidebarSwiping(false)
        XCTAssertEqual(store.highlightedSidebarRow, open[0], "the swipe closed: the highlight is back")
        store.sidebarSelection = nil
        XCTAssertNil(store.highlightedSidebarRow)
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
        XCTAssertFalse(scroller.isSwiping, "a swipe too short to open the action snaps back")
        // A long swipe opens the action, which outlives the gesture; a swipe back closes it.
        scroller.track(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0)
        scroller.track(phase: .changed, momentumPhase: [], deltaX: -50, deltaY: 2)
        scroller.track(phase: .changed, momentumPhase: [], deltaX: -30, deltaY: -1)
        scroller.track(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0)
        XCTAssertTrue(scroller.isSwiping, "the opened action outlives the gesture")
        scroller.track(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0)
        scroller.track(phase: .changed, momentumPhase: [], deltaX: 25, deltaY: 0)
        XCTAssertTrue(scroller.isSwiping, "still sideways while the swipe back is under way")
        scroller.track(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0)
        XCTAssertFalse(scroller.isSwiping, "a swipe back to the right closes the action")
        // An opened action also ends with a vertical scroll, and a mouse wheel is never a swipe.
        scroller.track(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0)
        scroller.track(phase: .changed, momentumPhase: [], deltaX: -80, deltaY: 0)
        scroller.track(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0)
        XCTAssertTrue(scroller.isSwiping)
        scroller.track(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0)
        scroller.track(phase: .changed, momentumPhase: [], deltaX: 1, deltaY: -30)
        XCTAssertFalse(scroller.isSwiping, "a vertical scroll ends swipe mode")
        XCTAssertFalse(scroller.isSuppressed)
        scroller.track(phase: [], momentumPhase: [], deltaX: 0, deltaY: -3)
        XCTAssertFalse(scroller.isSwiping, "a mouse wheel is never a swipe")
        XCTAssertEqual(reports, [true, false, true, false, true, false])
    }
}
