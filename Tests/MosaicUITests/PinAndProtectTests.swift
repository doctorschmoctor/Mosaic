import XCTest
import MosaicCore
@testable import Mosaic

/// Pins order Mosaic's sidebar; protection keeps a tile from being replaced. They are separate:
/// a pinned conversation can be replaced, and a protected tile need not be pinned.
final class PinAndProtectTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    @MainActor func testPinnedConversationsComeFirstInPinOrderAndPersist() throws {
        let suite = defaults()
        suite.set(false, forKey: "Mosaic.live")
        let store = WorkspaceStore(defaults: suite)
        let ids = store.filteredConversations.map(\.id)
        XCTAssertEqual(store.pinnedRowCount, 0)
        store.togglePin(ids[5]); store.togglePin(ids[2])
        XCTAssertEqual(Array(store.filteredConversations.map(\.id).prefix(2)), [ids[5], ids[2]], "in the order pinned")
        XCTAssertEqual(store.pinnedRowCount, 2)
        XCTAssertEqual(store.filteredConversations.count, ids.count, "every conversation is still listed once")
        XCTAssertEqual(Array(store.filteredConversations.map(\.id).dropFirst(2)), ids.filter { $0 != ids[5] && $0 != ids[2] })
        // The keyboard moves through the list in the order shown.
        store.moveSidebarSelection(by: 1)
        XCTAssertEqual(store.sidebarSelection, ids[5])
        store.persistNow()
        let again = WorkspaceStore(defaults: suite)
        XCTAssertEqual(again.pinnedIDs, [ids[5], ids[2]], "pins are kept by exact conversation")
        again.togglePin(ids[5])
        XCTAssertEqual(again.pinnedIDs, [ids[2]])
        XCTAssertEqual(again.pinnedRowCount, 1)
        // Drafts lists drafts only, pinned or not.
        again.sidebarFilter = .drafts
        XCTAssertEqual(again.pinnedRowCount, 0)
    }

    @MainActor func testProtectedTilesAreNeverReplacedSilently() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let open = store.openIDs
        XCTAssertEqual(open.count, Workspace.maximumTiles)
        for id in open { store.focus(id) } // open[0] is now the one used longest ago
        store.toggleProtection(open[0])
        XCTAssertTrue(store.isProtected(open[0]))
        XCTAssertFalse(store.isPinned(open[0]), "protection is not a pin")
        let fifth = try XCTUnwrap(store.conversations.map(\.id).first { !open.contains($0) })
        store.open(fifth)
        XCTAssertTrue(store.openIDs.contains(open[0]), "the protected tile stays")
        XCTAssertFalse(store.openIDs.contains(open[1]), "the next one used longest ago makes room")

        // Every tile protected: nothing closes by itself; the reader is asked.
        for id in store.openIDs where !store.isProtected(id) { store.toggleProtection(id) }
        store.workspace.drafts[store.openIDs[2]] = "keep me"
        let before = store.openIDs
        let sixth = try XCTUnwrap(store.conversations.map(\.id).first { !store.openIDs.contains($0) })
        store.openAndType(sixth)
        XCTAssertEqual(store.openIDs, before, "nothing closed")
        let choice = try XCTUnwrap(store.replacementChoice)
        XCTAssertEqual(choice.incoming, sixth)
        XCTAssertTrue(choice.thenType)
        XCTAssertEqual(store.replacementCandidates.map(\.id), before)
        XCTAssertEqual(store.replacementCandidates.first { $0.id == before[2] }?.hasDraft, true, "the chooser says which tile has a draft")
        store.cancelReplacement()
        XCTAssertNil(store.replacementChoice)
        XCTAssertEqual(store.openIDs, before, "cancel keeps every tile")

        store.openAndType(sixth)
        store.chooseReplacement(before[2])
        XCTAssertEqual(store.openIDs[2], sixth, "the chosen tile makes room, in its place")
        XCTAssertEqual(store.drafts[before[2]], "keep me", "its draft is kept")
        XCTAssertEqual(store.focusTarget, sixth, "the cursor goes to the new tile")
        XCTAssertFalse(store.isProtected(before[2]), "protection ended with the tile")
        XCTAssertFalse(store.isProtected(sixth))

        // A new message asks too.
        store.toggleProtection(sixth)
        XCTAssertNil(store.beginNewChat())
        XCTAssertNil(store.replacementChoice?.incoming)
        store.chooseReplacement(before[3])
        XCTAssertTrue(store.openIDs.contains { $0.hasPrefix("new-") })
        XCTAssertFalse(store.openIDs.contains(before[3]))
    }

    @MainActor func testProtectionEndsWhenATileClosesAndSurvivesARelaunchWhileOpen() throws {
        let suite = defaults()
        suite.set(false, forKey: "Mosaic.live")
        let store = WorkspaceStore(defaults: suite)
        let a = store.openIDs[0], b = store.openIDs[1]
        store.toggleProtection(a); store.toggleProtection(b)
        store.close(b)
        XCTAssertEqual(store.protectedIDs, [a])
        store.open(b)
        XCTAssertFalse(store.isProtected(b), "a reopened tile starts unprotected")
        store.persistNow()
        let again = WorkspaceStore(defaults: suite)
        XCTAssertEqual(again.protectedIDs, [a])
    }

    func testOlderWorkspacesDecodeWithoutPinsOrProtection() throws {
        let json = #"{"openIDs":["a","b"],"focusedID":"a","layout":"grid","drafts":{},"seenMessageIDs":{},"hidden":{},"zoom":1}"#
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(workspace.pinnedIDs, [])
        XCTAssertEqual(workspace.protectedIDs, [])
        let protectedClosed = #"{"openIDs":["a"],"protectedIDs":["a","gone"],"pinnedIDs":["z"]}"#
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(protectedClosed.utf8))
        XCTAssertEqual(decoded.protectedIDs, ["a"], "protection only for open tiles")
        XCTAssertEqual(decoded.pinnedIDs, ["z"], "a pin is kept even for a conversation not open")
    }
}
