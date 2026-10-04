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

    private func photo(_ name: String, bytes: Int?, path: String? = "/tmp/x") -> Attachment {
        Attachment(id: UUID().uuidString, path: path, name: name, mimeType: "image/jpeg", byteCount: bytes)
    }
    private func local(_ attachment: Attachment, date: Date) -> Message {
        var message = Message(id: "pending-\(UUID().uuidString)", text: "", date: date, isFromMe: true, attachments: [attachment])
        message.sendState = .submitted
        return message
    }

    /// File sends have no text to match on. Rows are claimed by the files' evidence — count,
    /// kind, name and size — so two photos sent close together each keep their own bubble even
    /// when Messages records them in the other order.
    func testFilesAreMatchedByTheirEvidenceNotTheirOrder() {
        let date = Date()
        let a = local(photo("IMG_0001.jpg", bytes: 100), date: date)
        let b = local(photo("IMG_0002.jpg", bytes: 200), date: date)
        let rowB = Message(id: "11", text: "", date: date.addingTimeInterval(1), isFromMe: true, attachments: [photo("IMG_0002.jpg", bytes: 200, path: nil)])
        let rowA = Message(id: "12", text: "", date: date.addingTimeInterval(2), isFromMe: true, attachments: [photo("IMG_0001.jpg", bytes: 100, path: nil)])
        let result = MessageReconciler.merge(loaded: [rowB, rowA], previous: [a, b], pending: [a, b])
        XCTAssertTrue(result.pending.isEmpty)
        XCTAssertEqual(result.messages.map(\.presentationID), [b.id, a.id])
    }

    /// Files that cannot be told apart (the same picture twice) pair up in the order sent; a text
    /// never claims a row that carries a file; and a photo whose row is not there yet waits.
    func testIdenticalFilesPairInOrderAndTextNeverClaimsAFileRow() {
        let date = Date()
        let first = local(photo("same.jpg", bytes: 50), date: date)
        let second = local(photo("same.jpg", bytes: 50), date: date.addingTimeInterval(0.5))
        let text = Message(id: "pending-text", text: "Here", date: date.addingTimeInterval(1), isFromMe: true)
        let row1 = Message(id: "21", text: "", date: date.addingTimeInterval(2), isFromMe: true, attachments: [photo("same.jpg", bytes: 50, path: nil)])
        let row2 = Message(id: "22", text: "", date: date.addingTimeInterval(3), isFromMe: true, attachments: [photo("same.jpg", bytes: 50, path: nil)])
        let textRowWithFile = Message(id: "23", text: "Here", date: date.addingTimeInterval(4), isFromMe: true, attachmentCount: 1)
        let result = MessageReconciler.merge(loaded: [row1, row2, textRowWithFile], previous: [first, second, text], pending: [first, second, text])
        XCTAssertEqual(result.messages.prefix(2).map(\.presentationID), [first.id, second.id])
        XCTAssertEqual(result.pending.map(\.id), [text.id], "a row with a file is not the plain text's row")
        // A file not downloaded on this Mac has no local record: the count and the empty text decide.
        let undownloaded = Message(id: "24", text: "", date: date.addingTimeInterval(5), isFromMe: true, attachmentCount: 1)
        let waiting = local(photo("later.heic", bytes: 900), date: date.addingTimeInterval(4))
        let second_ = MessageReconciler.merge(loaded: [undownloaded], previous: [waiting], pending: [waiting])
        XCTAssertEqual(second_.messages.first?.presentationID, waiting.id)
        // Two different files and one row that fits only one of them: the other keeps waiting.
        let c = local(photo("c.png", bytes: 1), date: date), d = local(photo("d.png", bytes: 2), date: date)
        let rowD = Message(id: "25", text: "", date: date, isFromMe: true, attachments: [photo("d.png", bytes: 2, path: nil)])
        let third = MessageReconciler.merge(loaded: [rowD], previous: [c, d], pending: [c, d])
        XCTAssertEqual(third.pending.map(\.id), [c.id])
        XCTAssertEqual(third.messages.first?.presentationID, d.id)
    }

    /// A message Messages refused stays in the thread until the reader acts on it, and never claims a row.
    func testRefusedMessagesStayAndClaimNothing() {
        let date = Date()
        var refused = Message(id: "pending-r", text: "Hey", date: date, isFromMe: true)
        refused.sendState = .failed("No")
        let row = Message(id: "31", text: "Hey", date: date, isFromMe: true)
        let result = MessageReconciler.merge(loaded: [row], previous: [refused], pending: [])
        XCTAssertEqual(result.messages.map(\.id), ["31", "pending-r"])
        XCTAssertEqual(result.messages[0].presentationID, "31")
        XCTAssertEqual(result.messages[1].sendState, .failed("No"))
    }
}
