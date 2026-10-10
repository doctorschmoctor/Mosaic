import XCTest
import CSQLite
import MosaicCore
@testable import Mosaic

/// Where a New Message goes (UX-14), through the real store with a synthetic Messages database
/// and a recording transport — nothing reaches Messages. The database has the same person twice
/// (an iMessage and an SMS chat) and someone with one chat; every number is fictional and written
/// internationally, so the results don't depend on the test Mac's region.
final class RecipientRoutingTests: XCTestCase {
    static let alexIMessage = "iMessage;-;+14155550123"
    static let alexSMS = "SMS;-;+14155550123"
    static let kit = "iMessage;-;kit@example.test"
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "MosaicRoutingTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeDatabase() throws -> String {
        let path = directory.appending(path: "chat.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
          is_delivered INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, error INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0,
          associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT, item_type INTEGER DEFAULT 0);
        INSERT INTO handle VALUES ('+14155550123'), ('+14155550123'), ('kit@example.test');
        INSERT INTO chat VALUES ('\(Self.alexIMessage)', '', '+14155550123', 'iMessage'),
                                ('\(Self.alexSMS)', '', '+14155550123', 'SMS'),
                                ('\(Self.kit)', '', 'kit@example.test', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1),(2,2),(3,3);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES
          ('G1', 'Over iMessage', 700000001000000000, 0, 1),
          ('G2', 'Over SMS', 700000002000000000, 0, 2),
          ('G3', 'Hello from Kit', 700000003000000000, 0, 3);
        INSERT INTO chat_message_join VALUES (1,1),(2,2),(3,3);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return path
    }
    @MainActor private func liveStore(_ transport: RecordingTransport) async throws -> WorkspaceStore {
        let path = try makeDatabase()
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, database: MessagesDatabase(path: path), transport: transport)
        for _ in 0..<200 where store.conversations.count < 3 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(Set(store.conversations.map(\.id)), [Self.alexIMessage, Self.alexSMS, Self.kit])
        XCTAssertTrue(store.canSend)
        return store
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The same person with an iMessage and an SMS chat: typing them picks neither. Sending says
    /// to choose and accepts nothing; once one is chosen, the message goes to exactly that chat.
    @MainActor func testAPersonWithTwoConversationsIsAskedNotGuessed() async throws {
        let transport = RecordingTransport()
        let store = try await liveStore(transport)
        let draftID = try XCTUnwrap(store.beginNewChat())
        store.addRecipient(Recipient(address: "+1 (415) 555-0123", name: "Alex"), to: draftID)
        XCTAssertEqual(store.conversations(with: store.composeDrafts[draftID]!.recipients).map(\.id), [Self.alexSMS, Self.alexIMessage],
                       "both, most recent first")
        XCTAssertNil(store.conversation(with: store.composeDrafts[draftID]!.recipients), "no single match is picked")
        XCTAssertEqual(store.composeRoute(draftID), .choose([Self.alexSMS, Self.alexIMessage]))
        XCTAssertFalse(store.composeRoute(draftID).canSend)

        store.drafts[draftID] = "Which one?"
        await store.send(draftID)
        XCTAssertTrue(transport.submissions.isEmpty, "nothing goes until the reader chooses")
        XCTAssertEqual(store.drafts[draftID], "Which one?", "the text stays in the composer")
        XCTAssertNotNil(store.sendErrors[draftID])

        let iMessage = try XCTUnwrap(store.conversations.first { $0.id == Self.alexIMessage })
        store.addressDraft(draftID, to: iMessage)
        XCTAssertEqual(store.composeRoute(draftID), .existing(Self.alexIMessage, chosen: true))
        await store.send(draftID)
        XCTAssertEqual(transport.submissions, [.text("Which one?", .chat(Self.alexIMessage))])
        XCTAssertTrue(store.openIDs.contains(Self.alexIMessage), "the tile became that conversation")
    }

    /// Choosing a conversation sends to that exact chat, even when the same people have another,
    /// more recent one; and a chosen chat that has gone sends nowhere else.
    @MainActor func testAChosenConversationIsTheExactChat() async throws {
        let transport = RecordingTransport()
        let store = try await liveStore(transport)
        let draftID = try XCTUnwrap(store.beginNewChat())
        let sms = try XCTUnwrap(store.conversations.first { $0.id == Self.alexSMS })
        store.addressDraft(draftID, to: sms)
        store.drafts[draftID] = "By text"
        await store.send(draftID)
        XCTAssertEqual(transport.submissions, [.text("By text", .chat(Self.alexSMS))])

        let other = try XCTUnwrap(store.beginNewChat())
        store.composeDrafts[other] = ComposeDraft(recipients: [Recipient(address: "kit@example.test")], boundConversationID: "iMessage;-;gone@example.test")
        XCTAssertEqual(store.composeRoute(other), .chosenGone)
        store.drafts[other] = "Hello?"
        await store.send(other)
        XCTAssertEqual(transport.submissions.count, 1, "never another chat with the same people")
        XCTAssertEqual(store.drafts[other], "Hello?")
    }

    /// One new person: the route says a new iMessage conversation with the handle Messages will be
    /// given — international numbers unchanged — and that handle is what is sent to.
    @MainActor func testANewPersonIsSentToTheHandleShown() async throws {
        let transport = RecordingTransport()
        let store = try await liveStore(transport)
        let draftID = try XCTUnwrap(store.beginNewChat())
        store.addRecipient(Recipient(address: "+44 7700 900123", name: "Robin"), to: draftID)
        XCTAssertEqual(store.composeRoute(draftID), .newPerson(Recipient(address: "+44 7700 900123", name: "Robin"), handle: "+447700900123"))
        store.drafts[draftID] = "Hi Robin"
        await store.send(draftID)
        XCTAssertEqual(transport.submissions, [.text("Hi Robin", .participant(handle: "+447700900123", service: "iMessage"))])
        // The tile is Robin's now: the To field no longer changes, and the next message goes to Robin.
        store.addRecipient(Recipient(address: "kit@example.test"), to: draftID)
        XCTAssertEqual(store.composeDrafts[draftID]?.recipients.map(\.address), ["+44 7700 900123"])
        if case .sentTo(_, let handle) = store.composeRoute(draftID) { XCTAssertEqual(handle, "+447700900123") } else { XCTFail("sent to Robin") }
        store.drafts[draftID] = "Again"
        await store.send(draftID)
        XCTAssertEqual(transport.submissions.last, .text("Again", .participant(handle: "+447700900123", service: "iMessage")))
    }

    /// Several new people: a new group can't be started from another app, which the route says
    /// before anything is sent; a send accepts nothing (and nothing else is opened).
    @MainActor func testANewGroupIsExplainedAndNothingIsAccepted() async throws {
        let transport = RecordingTransport()
        let store = try await liveStore(transport)
        let draftID = try XCTUnwrap(store.beginNewChat())
        store.addRecipient(Recipient(address: "+44 7700 900123"), to: draftID)
        store.addRecipient(Recipient(address: "robin@example.test"), to: draftID)
        XCTAssertEqual(store.composeRoute(draftID), .newGroup)
        store.drafts[draftID] = "Everyone"
        await store.send(draftID)
        XCTAssertTrue(transport.submissions.isEmpty)
        XCTAssertEqual(store.drafts[draftID], "Everyone")
        XCTAssertEqual(store.sendErrors[draftID], ComposeRoute.newGroupExplanation)
    }

    /// Where a message goes is settled when Return is pressed: changing the To field while its
    /// photo is still arriving does not change it.
    @MainActor func testEditingRecipientsWhilePhotosArriveKeepsTheTarget() async throws {
        let transport = RecordingTransport()
        let store = try await liveStore(transport)
        let draftID = try XCTUnwrap(store.beginNewChat())
        store.addRecipient(Recipient(address: "+44 7700 900123", name: "Robin"), to: draftID)
        let slot = try XCTUnwrap(store.beginImports(1, to: draftID).first)
        store.drafts[draftID] = "With a photo"
        let sending = Task { await store.send(draftID) }
        try await wait { store.sendNotes[draftID] != nil }
        XCTAssertNotNil(store.sendNotes[draftID], "waiting for the photo")
        // Meanwhile the To field changes to someone else entirely.
        store.removeRecipient(Recipient(address: "+44 7700 900123"), from: draftID)
        store.addRecipient(Recipient(address: "kit@example.test"), to: draftID)
        try FileManager.default.createDirectory(at: store.services.outgoing.pending, withIntermediateDirectories: true)
        let file = store.services.outgoing.pending.appending(path: "photo-\(UUID().uuidString).heic")
        try Data("fixture".utf8).write(to: file)
        store.completeImport(slot, url: file, in: draftID)
        await sending.value
        let targets = transport.submissions.map { submission -> SendTarget in
            switch submission { case .text(_, let target), .file(_, let target): return target }
        }
        XCTAssertEqual(targets.count, 2, "the photo, then the text")
        XCTAssertTrue(targets.allSatisfy { $0 == .participant(handle: "+447700900123", service: "iMessage") }, "\(targets)")
        XCTAssertEqual(store.composeDrafts[draftID]?.routedTo?.address, "+44 7700 900123")
        XCTAssertEqual(store.composeDrafts[draftID]?.recipients.map(\.address), ["+44 7700 900123"], "the To field shows who it went to")
    }

    /// Try Again after a refused send to a new person goes to that same person.
    @MainActor func testTryAgainGoesToTheSamePerson() async throws {
        let transport = RecordingTransport()
        transport.failures = [0: "Not now"]
        let store = try await liveStore(transport)
        let draftID = try XCTUnwrap(store.beginNewChat())
        store.addRecipient(Recipient(address: "+44 7700 900123"), to: draftID)
        store.drafts[draftID] = "First try"
        await store.send(draftID)
        let failed = try XCTUnwrap(store.composeDrafts[draftID]?.sent.first { $0.sendState?.isFailed == true })
        await store.retrySend(failed.presentationID, in: draftID)
        XCTAssertEqual(transport.submissions, [.text("First try", .participant(handle: "+447700900123", service: "iMessage")),
                                               .text("First try", .participant(handle: "+447700900123", service: "iMessage"))])
    }

    /// The suggestions tell two conversations with the same people apart by their service.
    @MainActor func testSuggestionsListEachConversationWithItsService() async throws {
        let store = try await liveStore(RecordingTransport())
        let draftID = try XCTUnwrap(store.beginNewChat())
        let chats = store.recipientSuggestions(for: "415", excluding: draftID).compactMap { suggestion -> String? in
            if case .conversation(let conversation) = suggestion { return conversation.id } else { return nil }
        }
        XCTAssertEqual(Set(chats), [Self.alexIMessage, Self.alexSMS])
        XCTAssertEqual(ComposeRouteNote.serviceName("SMS"), "SMS")
        XCTAssertEqual(ComposeRouteNote.serviceName("iMessage"), "iMessage")
    }
}
