import XCTest
@testable import MosaicCore

final class MessageReconcilerTests: XCTestCase {
    func testDatabaseConfirmationKeepsTheAnimatedBubbleIdentity() throws {
        let pending = Message(id: "pending-a", text: "Hello", date: Date(), isFromMe: true)
        let confirmed = Message(id: "42", text: pending.text, date: pending.date, isFromMe: true, isDelivered: true)
        let result = MessageReconciler.merge(loaded: [confirmed], previous: [pending], pending: [pending])
        XCTAssertTrue(result.pending.isEmpty)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].id, "42")
        XCTAssertEqual(result.messages[0].presentationID, pending.id)
        let next = MessageReconciler.merge(loaded: [confirmed], previous: result.messages, pending: [])
        XCTAssertEqual(next.messages[0].presentationID, pending.id)
    }
    func testRepeatedTextCannotConfirmTwoSendsOrMatchAnExistingBubble() {
        let date = Date()
        let old = Message(id: "old", text: "Okay", date: date, isFromMe: true)
        let first = Message(id: "pending-first", text: "Okay", date: date, isFromMe: true)
        let second = Message(id: "pending-second", text: "Okay", date: date, isFromMe: true)
        let new = Message(id: "new", text: "Okay", date: date, isFromMe: true)
        let result = MessageReconciler.merge(loaded: [old, new], previous: [old, first, second], pending: [first, second])
        XCTAssertEqual(result.pending.map(\.id), [second.id])
        XCTAssertEqual(result.messages.map(\.presentationID), [old.id, first.id, second.id])
    }
}
