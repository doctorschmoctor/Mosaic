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
        var state = Workspace(openIDs: (0..<Workspace.maximumTiles).map(String.init))
        XCTAssertEqual(Workspace.maximumTiles, 4)
        XCTAssertFalse(state.open("overflow"))
        XCTAssertTrue(state.open("3"))
        XCTAssertEqual(state.openIDs.count, 4)
        XCTAssertEqual(state.focusedID, "3")
        state.close("1")
        XCTAssertTrue(state.open("overflow"))
    }
    func testOlderSavedWorkspacesDecodeWithoutTheHiddenList() throws {
        let data = Data(#"{"openIDs":["a"],"focusedID":"a","layout":"columns","drafts":{"a":"hi"},"seenMessageIDs":{}}"#.utf8)
        let state = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(state.openIDs, ["a"]); XCTAssertEqual(state.layout, .columns); XCTAssertEqual(state.drafts["a"], "hi")
        XCTAssertTrue(state.hidden.isEmpty)
        var hidden = state
        hidden.hidden["b"] = "123"
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(hidden)), hidden)
    }
    func testRecipientKeysMatchFormattingsOfTheSameHandle() {
        XCTAssertEqual(Recipient.key(for: "(917) 831-0374"), Recipient.key(for: "+19178310374"))
        XCTAssertEqual(Recipient.key(for: "tel:+1 917-831-0374"), "9178310374")
        XCTAssertEqual(Recipient.key(for: "Alex@Example.test"), "alex@example.test")
        XCTAssertEqual(Recipient.handle(for: "(917) 831-0374"), "+19178310374")
        XCTAssertEqual(Recipient.handle(for: "+44 20 7946 0123"), "+442079460123")
        XCTAssertEqual(Recipient.display("+19178310374"), "+1 (917) 831-0374")
        XCTAssertEqual(Recipient.display("alex@example.test"), "alex@example.test")
        XCTAssertEqual(Recipient(address: "9178310374").name, "(917) 831-0374")
        XCTAssertEqual(Conversation(id: "c", name: "x", participants: ["+19178310374", "a@b.c"]).participantKeys, ["9178310374", "a@b.c"])
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
