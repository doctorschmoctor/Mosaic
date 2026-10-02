import XCTest
@testable import MosaicCore

final class WorkspaceTests: XCTestCase {
    func testClosingAndReopeningKeepsIndependentDrafts() throws {
        var state = Workspace(openIDs: ["alex", "jamie"])
        state.drafts["alex"] = "See you at 10"
        state.drafts["jamie"] = "Sending the mockups"
        state.close("alex")
        XCTAssertEqual(state.focusedID, "jamie")
        XCTAssertTrue(state.open("alex"))
        XCTAssertEqual(state.drafts["alex"], "See you at 10")
        XCTAssertEqual(state.drafts["jamie"], "Sending the mockups")
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }
    func testCapacityAndDuplicateOpening() {
        var state = Workspace(openIDs: (0..<8).map(String.init))
        XCTAssertFalse(state.open("overflow"))
        XCTAssertTrue(state.open("3"))
        XCTAssertEqual(state.openIDs.count, 8)
        XCTAssertEqual(state.focusedID, "3")
        state.close("1")
        XCTAssertTrue(state.open("overflow"))
    }
    func testReorderingAndReconciliationKeepOrderAndDrafts() {
        var state = Workspace(openIDs: ["c", "a", "b", "c"])
        XCTAssertEqual(state.openIDs, ["c", "a", "b"])
        state.drafts["b"] = "unsent"
        state.reorder("b", before: "c")
        XCTAssertEqual(state.openIDs, ["b", "c", "a"])
        state.focusedID = "c"
        state.reconcile(availableIDs: ["a", "b"])
        XCTAssertEqual(state.openIDs, ["b", "a"])
        XCTAssertEqual(state.focusedID, "b")
        XCTAssertEqual(state.drafts["b"], "unsent")
        state.reorder("unknown", before: "a")
        XCTAssertEqual(state.openIDs, ["b", "a"])
    }
}
