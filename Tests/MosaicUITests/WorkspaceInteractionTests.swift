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
}
