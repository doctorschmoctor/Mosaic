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
}
