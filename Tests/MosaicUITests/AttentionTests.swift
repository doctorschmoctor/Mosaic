import XCTest
import MosaicCore
@testable import Mosaic

/// What needs attention: the Unread, Needs Reply and Drafts filters with their counts, Needs Reply
/// as the reader's own reminder (reading leaves it), Go to Next Unread, unread and draft marks on
/// Focus chips, and a thread counted as read only once the reader can see it.
final class AttentionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
    @MainActor private func id(_ name: String, in store: WorkspaceStore) throws -> String {
        try XCTUnwrap(store.conversations.first { $0.name == name }?.id, name)
    }

    @MainActor func testFiltersListWhatNeedsAttentionWithCounts() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let alex = try id("Alex Morgan", in: store), crew = try id("Weekend crew", in: store)
        let sam = try id("Sam Rivera", in: store), mom = try id("Mom", in: store)
        XCTAssertEqual(store.count(for: .unread), 3)
        store.sidebarFilter = .unread
        XCTAssertEqual(store.filteredConversations.map(\.id), [alex, crew, sam])
        store.markSeen(crew)
        XCTAssertEqual(store.count(for: .unread), 2, "reading one leaves the others' counts")
        XCTAssertEqual(store.filteredConversations.map(\.id), [alex, sam])

        XCTAssertEqual(store.count(for: .needsReply), 0)
        store.toggleNeedsReply(mom)
        XCTAssertTrue(store.needsReply(mom))
        store.sidebarFilter = .needsReply
        XCTAssertEqual(store.filteredConversations.map(\.id), [mom])
        store.markSeen(mom)
        store.open(mom); store.focus(mom)
        XCTAssertTrue(store.needsReply(mom), "reading or opening keeps the reminder")
        store.toggleNeedsReply(mom)
        XCTAssertFalse(store.needsReply(mom), "only clearing it does")
        XCTAssertEqual(store.count(for: .needsReply), 0)

        store.workspace.drafts[alex] = "Draft"
        store.updateDraftSummaries()
        XCTAssertEqual(store.count(for: .drafts), 1)
        XCTAssertEqual(store.count(for: .all), 0, "All carries no count")
        // A hidden conversation counts nowhere.
        store.toggleNeedsReply(sam)
        store.hide(sam)
        XCTAssertEqual(store.count(for: .unread), 1)
        XCTAssertEqual(store.count(for: .needsReply), 0)
    }

    @MainActor func testNeedsReplyIsKeptAcrossARelaunch() throws {
        let suite = defaults()
        suite.set(false, forKey: "Mosaic.live")
        let store = WorkspaceStore(defaults: suite)
        let jamie = try id("Jamie Chen", in: store)
        store.toggleNeedsReply(jamie)
        store.persistNow()
        XCTAssertEqual(WorkspaceStore(defaults: suite).needsReplyIDs, [jamie])
        let json = #"{"openIDs":["a"]}"#
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(json.utf8)).needsReplyIDs, [], "older workspaces decode")
    }

    @MainActor func testGoToNextUnreadWalksThroughWhatIsUnread() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let alex = try id("Alex Morgan", in: store), crew = try id("Weekend crew", in: store), sam = try id("Sam Rivera", in: store)
        store.focus(alex)
        XCTAssertTrue(store.goToNextUnread())
        XCTAssertEqual(store.focusTarget, crew, "the next unread after the focused conversation")
        XCTAssertTrue(store.goToNextUnread())
        XCTAssertTrue(store.openIDs.contains(sam), "a closed one opens")
        XCTAssertEqual(store.focusTarget, sam)
        XCTAssertTrue(store.goToNextUnread())
        XCTAssertEqual(store.focusTarget, alex, "it wraps around")
        for id in [alex, crew, sam] { store.markSeen(id) }
        XCTAssertFalse(store.goToNextUnread(), "nothing unread: nothing happens")
    }

    @MainActor func testAThreadCountsAsReadOnlyOnceTheReaderCanSeeIt() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let alex = try id("Alex Morgan", in: store), crew = try id("Weekend crew", in: store)
        func unread(_ id: String) -> Int { store.conversations.first { $0.id == id }?.unreadCount ?? -1 }

        store.setAppActive(false)
        store.tailSeen(crew)
        XCTAssertEqual(unread(crew), 2, "Mosaic in the background: not seen yet")
        store.setAppActive(true)
        XCTAssertEqual(unread(crew), 0, "coming back with the newest message in view reads it")

        store.setWindowVisible(false)
        store.tailSeen(alex)
        XCTAssertEqual(unread(alex), 1, "a minimized or covered window shows nothing")
        store.setWindowVisible(true)
        XCTAssertEqual(unread(alex), 0)

        // A tile scrolled out of the workspace's view (Columns) is not read until it is in view.
        let sam = try id("Sam Rivera", in: store)
        store.open(sam)
        store.setTileInView(sam, false)
        store.tailSeen(sam)
        XCTAssertEqual(unread(sam), 1)
        store.setTileInView(sam, true)
        XCTAssertEqual(unread(sam), 0)

        // Scrolled away again before the reader could see it: nothing is read.
        let mom = try id("Mom", in: store)
        if let index = store.conversations.firstIndex(where: { $0.id == mom }) { store.conversations[index].unreadCount = 2 }
        store.setAppActive(false)
        store.tailSeen(mom)
        store.tailLeft(mom)
        store.setAppActive(true)
        XCTAssertEqual(unread(mom), 2)

        // In Focus only the focused tile is on screen.
        store.setLayout(.focus)
        store.focus(alex)
        store.tailSeen(mom)
        XCTAssertEqual(unread(mom), 2, "behind the focused tile")
        store.focus(mom)
        XCTAssertEqual(unread(mom), 0, "shown: read")
    }

    @MainActor func testFocusChipsMarkUnreadAndDrafts() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let tiles = store.tiles
        let chips = FocusChip.chips(for: tiles, focusedID: tiles[0].id, unread: [tiles[1].id], drafts: [tiles[1].id, tiles[2].id])
        XCTAssertEqual(chips.map(\.hasUnread), [false, true, false, false])
        XCTAssertEqual(chips.map(\.hasDraft), [false, true, true, false])
        let bar = FocusChipBar.ChipBarView(frame: NSRect(x: 0, y: 0, width: 900, height: FocusChipBar.height))
        bar.chips = FocusChip.chips(for: tiles, focusedID: tiles[0].id)
        let plain = bar.frames[1].width
        bar.chips = chips
        XCTAssertEqual(bar.frames[1].width, plain + 2 * FocusChipBar.ChipBarView.markWidth, "room for both marks")
    }
}
