import XCTest
import MosaicCore
@testable import Mosaic

/// A conversation's details: what it shared, from the loaded messages, newest first.
final class DetailsTests: XCTestCase {
    func testSharedContentIsGatheredFromTheLoadedMessagesNewestFirst() {
        let photo = Attachment(id: "a1", path: "/tmp/one.jpg", name: "one.jpg", mimeType: "image/jpeg")
        let missing = Attachment(id: "a2", path: nil, name: "two.mov", mimeType: "video/quicktime")
        let sticker = Attachment(id: "a3", path: "/tmp/s.png", name: "s.png", mimeType: "image/png", isSticker: true)
        let pdf = Attachment(id: "a4", path: "/tmp/plan.pdf", name: "plan.pdf", mimeType: "application/pdf")
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let messages = [
            Message(id: "1", text: "see https://example.com/a", date: day, isFromMe: false, attachments: [photo]),
            Message(id: "2", text: "", date: day + 60, isFromMe: true, attachments: [missing, sticker]),
            Message(id: "3", text: "again https://example.com/a and https://example.org", date: day + 120, isFromMe: false, attachments: [pdf]),
            Message(id: "4", text: "", date: day + 180, isFromMe: false, attachments: [photo], dateRetracted: day + 200),
        ]
        let content = SharedContent(messages: messages)
        XCTAssertEqual(content.media.map(\.attachment.id), ["a2", "a1"], "newest first; no stickers; nothing from an unsent message")
        XCTAssertEqual(content.media.first?.messageID, "2")
        XCTAssertEqual(content.files.map(\.attachment.name), ["plan.pdf"])
        XCTAssertEqual(content.links.map(\.url.absoluteString), ["https://example.com/a", "https://example.org"], "each link once, from its newest message")
        XCTAssertEqual(content.links.first?.messageID, "3")
        XCTAssertEqual(content.localMedia.map(\.path), ["/tmp/one.jpg"], "a file not on this Mac is not previewed")
    }

    /// Opening a tile's details shows nothing new about its draft: the draft stays as it was.
    @MainActor func testDetailsAreForTheFocusedConversationAndLeaveItsDraft() throws {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
        let id = try XCTUnwrap(store.focused?.id)
        store.workspace.drafts[id] = "half a thought"
        var asked: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .showConversationDetails, object: nil, queue: nil) { note in
            if let target = note.object as? String { asked.append(target) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.showDetails()
        XCTAssertEqual(asked, [id])
        XCTAssertEqual(store.drafts[id], "half a thought")
        _ = store.beginNewChat()
        store.showDetails()
        XCTAssertEqual(asked, [id], "a New Message has no details yet")
    }
}
