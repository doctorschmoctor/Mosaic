import XCTest
import MosaicCore
@testable import Mosaic

/// What needs attention: the Unread and Drafts filters with their counts, Go to Next Unread, unread and draft marks on
/// Focus chips, and a thread counted as read only once the reader is in its tile (or opens it).
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
        let sam = try id("Sam Rivera", in: store)
        XCTAssertEqual(store.count(for: .unread), 3)
        store.sidebarFilter = .unread
        XCTAssertEqual(store.filteredConversations.map(\.id), [alex, crew, sam])
        store.markSeen(crew)
        XCTAssertEqual(store.count(for: .unread), 2, "reading one leaves the others' counts")
        XCTAssertEqual(store.filteredConversations.map(\.id), [alex, sam])

        store.workspace.drafts[alex] = "Draft"
        store.updateDraftSummaries()
        XCTAssertEqual(store.count(for: .drafts), 1)
        XCTAssertEqual(store.count(for: .all), 0, "All carries no count")
        // A hidden conversation counts nowhere.
        store.hide(sam)
        XCTAssertEqual(store.count(for: .unread), 1)
    }

    /// Workspaces saved by the version that had Needs Reply flags still open.
    func testWorkspacesWithTheOldNeedsReplyFlagsStillDecode() throws {
        let json = #"{"openIDs":["a"],"needsReplyIDs":["a"]}"#
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(json.utf8)).openIDs, ["a"])
        XCTAssertEqual(SidebarFilter.allCases, [.all, .unread, .drafts])
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

    /// A conversation is read only by the reader being in its tile — its message field has the
    /// keyboard (a click or Tab into it) — while they can see its newest message. An open tile
    /// they are not in counts what arrives as unread, however visible it is.
    @MainActor func testAThreadCountsAsReadOnlyOnceTheReaderIsInItsTile() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let alex = try id("Alex Morgan", in: store), crew = try id("Weekend crew", in: store)
        func unread(_ id: String) -> Int { store.conversations.first { $0.id == id }?.unreadCount ?? -1 }
        func arrive(_ id: String) {
            if let index = store.conversations.firstIndex(where: { $0.id == id }) { store.conversations[index].unreadCount += 1 }
            store.tailSeen(id)
        }
        XCTAssertTrue(store.openIDs.contains(crew) && store.openIDs.contains(alex))

        store.tailSeen(crew)
        XCTAssertEqual(unread(crew), 2, "open, on screen and at its newest message, but the reader is not in it")
        XCTAssertTrue(store.unreadConversations.contains { $0.id == crew }, "so it is in the Unread list")
        store.composerTookKeyboard(crew)
        XCTAssertEqual(unread(crew), 0, "clicked or tabbed into: read")
        XCTAssertEqual(store.focusedID, crew)
        arrive(crew)
        XCTAssertEqual(unread(crew), 0, "what arrives while the reader is in the tile is read")

        // The reader moves to another tile: what arrives here waits for them to come back.
        store.composerLostKeyboard(crew); store.composerTookKeyboard(alex)
        XCTAssertEqual(unread(alex), 0)
        arrive(crew)
        XCTAssertEqual(unread(crew), 1, "the reader is in another tile")
        store.composerLostKeyboard(alex)
        arrive(alex)
        XCTAssertEqual(unread(alex), 1, "the keyboard is in neither (the list, the search field)")
        store.composerTookKeyboard(crew)
        XCTAssertEqual(unread(crew), 0)

        // In the tile, but not able to see it: read once they can.
        store.setAppActive(false)
        arrive(crew)
        XCTAssertEqual(unread(crew), 1, "Mosaic in the background")
        store.setAppActive(true)
        XCTAssertEqual(unread(crew), 0, "back, at the newest message: read")
        store.setWindowVisible(false)
        arrive(crew)
        XCTAssertEqual(unread(crew), 1, "a minimized or covered window")
        store.setWindowVisible(true)
        XCTAssertEqual(unread(crew), 0)
        store.setWindowKey(false)
        arrive(crew)
        XCTAssertEqual(unread(crew), 1, "another window has the keyboard")
        store.setWindowKey(true)
        XCTAssertEqual(unread(crew), 0)

        // Scrolled up in history: what arrives below is read once the reader is back at the newest.
        store.tailLeft(crew)
        if let index = store.conversations.firstIndex(where: { $0.id == crew }) { store.conversations[index].unreadCount = 1 }
        store.seeingMayHaveChanged()
        XCTAssertEqual(unread(crew), 1)
        store.tailSeen(crew)
        XCTAssertEqual(unread(crew), 0)

        // A tile scrolled out of the workspace's view (Columns) is read once it is in view.
        store.setTileInView(crew, false)
        arrive(crew)
        XCTAssertEqual(unread(crew), 1)
        store.setTileInView(crew, true)
        XCTAssertEqual(unread(crew), 0)

        // In Focus only the focused tile is on screen.
        store.setLayout(.focus)
        store.focus(alex)
        arrive(crew)
        XCTAssertEqual(unread(crew), 1, "behind the focused tile")
        store.focus(crew)
        XCTAssertEqual(unread(crew), 0, "shown, with the reader in it: read")
    }

    /// Opening a conversation from the list reads it at once — every one of a quick run of
    /// openings, before its field has the keyboard — and closing a tile reads nothing.
    @MainActor func testOpeningReadsAndClosingDoesNot() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let alex = try id("Alex Morgan", in: store), crew = try id("Weekend crew", in: store), sam = try id("Sam Rivera", in: store)
        func unread(_ id: String) -> Int { store.conversations.first { $0.id == id }?.unreadCount ?? -1 }
        XCTAssertEqual([unread(alex), unread(crew), unread(sam)], [1, 2, 1])
        XCTAssertFalse(store.openIDs.contains(sam))
        // Room for the tiles opened below, so none is replaced.
        store.close(try id("Jamie Chen", in: store))

        // Closed with × or ⇧⌘W while the reader is elsewhere: still unread, still listed.
        store.tailSeen(crew)
        store.close(crew)
        XCTAssertEqual(unread(crew), 2)
        XCTAssertTrue(store.unreadConversations.contains { $0.id == crew })

        // Clicked open one after another, each taking the keyboard from the one before before its
        // field had it: every one is read.
        store.pressRow(sam)
        store.pressRow(crew)
        XCTAssertTrue(store.openIDs.contains(sam) && store.openIDs.contains(crew))
        XCTAssertEqual([unread(sam), unread(crew)], [0, 0])
        XCTAssertFalse(store.unreadConversations.contains { [sam, crew].contains($0.id) })

        // An open tile clicked in the list is read when it shows its newest messages…
        store.tailSeen(alex)
        store.pressRow(alex)
        XCTAssertEqual(unread(alex), 0)
        // …and not while it is scrolled up in history.
        if let index = store.conversations.firstIndex(where: { $0.id == alex }) { store.conversations[index].unreadCount = 1 }
        store.tailLeft(alex)
        store.pressRow(alex)
        XCTAssertEqual(unread(alex), 1)

        // A double click on an open tile's row closes it: its first click read it, the close puts
        // that back.
        store.tailSeen(alex)
        let boundary = store.seenMessageIDs[alex]
        store.pressRow(alex, clickCount: 1)
        XCTAssertEqual(unread(alex), 0)
        store.pressRow(alex, clickCount: 2)
        XCTAssertFalse(store.openIDs.contains(alex))
        XCTAssertEqual(unread(alex), 1, "closing reads nothing")
        XCTAssertEqual(store.seenMessageIDs[alex], boundary)
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
