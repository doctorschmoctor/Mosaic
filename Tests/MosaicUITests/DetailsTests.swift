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

    /// The shared content is worked out once per change of the messages or the whole history —
    /// not each time the details are drawn — and its lists say when there is something new.
    @MainActor func testSharedContentIsWorkedOutOncePerChange() {
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var messages: [Message] = []
        for index in 1...300 {
            let text = index % 3 == 0 ? "see https://example.com/\(index)" : "note \(index)"
            var attachments: [Attachment] = []
            if index % 2 == 0 { attachments.append(Attachment(id: "p\(index)", path: "/tmp/p\(index).jpg", name: "p\(index).jpg", mimeType: "image/jpeg")) }
            let date = day + Double(index) * 60
            messages.append(Message(id: "\(index)", text: text, date: date, isFromMe: index % 2 == 0, attachments: attachments))
        }
        let cache = SharedContentCache()
        let first = cache.content(for: messages, history: nil)
        XCTAssertEqual(first.media.count, 150)
        XCTAssertEqual(first.links.count, 100)
        XCTAssertEqual(first.localMedia.count, 150)
        let version = cache.version
        for _ in 0..<5 { _ = cache.content(for: messages, history: nil) }
        XCTAssertEqual(cache.version, version, "the same messages: nothing worked out again")
        XCTAssertEqual(cache.content(for: Array(messages), history: nil), first, "an equal copy of them neither")
        XCTAssertEqual(cache.version, version)
        messages.append(Message(id: "301", text: "https://example.org", date: day + 400 * 60, isFromMe: false))
        XCTAssertEqual(cache.content(for: messages, history: nil).links.first?.url.absoluteString, "https://example.org")
        XCTAssertEqual(cache.version, version + 1, "a new message: worked out again, once")
        let history = SharedHistory(linksComplete: false)
        _ = cache.content(for: messages, history: history)
        XCTAssertEqual(cache.version, version + 2, "the whole history read: once more")
        _ = cache.content(for: messages, history: history)
        XCTAssertEqual(cache.version, version + 2)
        // The lists draw again only for a new version.
        let grid = SharedMediaGrid(content: first, version: 1, onShowMessage: { _ in })
        XCTAssertTrue(grid == SharedMediaGrid(content: first, version: 1, onShowMessage: { _ in }), "new closures alone: not drawn again")
        XCTAssertFalse(grid == SharedMediaGrid(content: first, version: 2, onShowMessage: { _ in }))
    }

    /// The app a file opens in is asked once for each kind of file.
    @MainActor func testDefaultAppsAreAskedOncePerKindOfFile() {
        let first = AttachmentActions.defaultAppName(for: "/tmp/one.jpg")
        XCTAssertEqual(AttachmentActions.defaultAppName(for: "/somewhere/else/two.JPG"), first, "the same kind of file")
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
