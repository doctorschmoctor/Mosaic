import XCTest
import CSQLite
import MosaicCore
@testable import Mosaic

/// Sends through the real pipeline with a fake transport and a synthetic database: the bubble
/// stands in the thread before Messages is asked anything, submissions go out in order, a refusal
/// is kept for the reader to act on, and nothing is ever resent on its own.
final class SendPipelineTests: XCTestCase {
    static let alex = "iMessage;-;alex@example.test"
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "MosaicSendTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A tiny Messages-shaped database with one conversation and two messages.
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
        INSERT INTO handle VALUES ('alex@example.test');
        INSERT INTO chat VALUES ('\(Self.alex)', '', 'alex@example.test', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('G1', 'Hello', 700000001000000000, 0, 1), ('G2', 'Hi!', 700000002000000000, 1, 0);
        INSERT INTO chat_message_join VALUES (1,1),(1,2);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return path
    }
    /// Inserts an outgoing message as Messages would after taking one of ours.
    private func record(_ text: String, date: Int64, at path: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO message (guid, text, date, is_from_me, handle_id, is_delivered) VALUES ('\(UUID().uuidString)', '\(text)', \(date), 1, 0, 1); INSERT INTO chat_message_join VALUES (1, last_insert_rowid());"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    @MainActor private func liveStore(transport: RecordingTransport) async throws -> (WorkspaceStore, String) {
        let path = try makeDatabase()
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, database: MessagesDatabase(path: path), transport: transport)
        XCTAssertTrue(store.isLive)
        for _ in 0..<200 where store.conversations.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(store.conversations.map(\.id), [Self.alex])
        XCTAssertTrue(store.canSend, "a loaded database means Messages is connected")
        return (store, path)
    }

    @MainActor func testBubbleShowsBeforeTheTransportRunsAndTypingIsNeverCleared() async throws {
        let transport = RecordingTransport()
        transport.holds = true
        let (store, _) = try await liveStore(transport: transport)
        store.open(Self.alex)
        store.workspace.drafts[Self.alex] = "On my way"
        let sending = Task { await store.send(Self.alex) }
        try await Task.sleep(for: .milliseconds(80))
        let thread = store.conversations[0].messages
        XCTAssertEqual(thread.last?.text, "On my way")
        XCTAssertEqual(thread.last?.sendState, .sending, "the bubble is in the thread while Messages is still being asked")
        XCTAssertEqual(store.workspace.drafts[Self.alex], "", "Return took the text; the composer is free")
        store.workspace.drafts[Self.alex] = "and then"
        XCTAssertEqual(transport.submissions, [.text("On my way", .chat(Self.alex))])
        transport.release()
        await sending.value
        XCTAssertEqual(store.conversations[0].messages.last?.sendState, .submitted)
        XCTAssertFalse(store.conversations[0].messages.last?.isDelivered ?? true, "handing over is not delivery")
        XCTAssertEqual(store.workspace.drafts[Self.alex], "and then", "what was typed meanwhile stays")
        transport.holds = false
        await store.send(Self.alex)
        XCTAssertEqual(transport.submissions.count, 2)
    }

    @MainActor func testSubmissionsGoOutInOrderFilesFirst() async throws {
        let transport = RecordingTransport()
        let (store, _) = try await liveStore(transport: transport)
        store.open(Self.alex)
        let picture = directory.appending(path: "photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        store.attach([picture], to: Self.alex)
        store.workspace.drafts[Self.alex] = "Look"
        await store.send(Self.alex)
        XCTAssertEqual(transport.submissions, [.file(picture, .chat(Self.alex)), .text("Look", .chat(Self.alex))])
        let local = store.conversations[0].messages.filter(\.isLocal)
        XCTAssertEqual(local.map(\.sendState), [.submitted, .submitted])
        XCTAssertEqual(local[0].attachments.first?.name, "photo.png")
        XCTAssertEqual(local[0].attachments.first?.byteCount, 4, "the file's size travels with the bubble, for matching the row later")
    }

    @MainActor func testARefusedMessageIsKeptForRetryEditOrRemovalAndNeverResentByItself() async throws {
        let transport = RecordingTransport()
        transport.failures[0] = "Allow Mosaic to control Messages."
        let (store, path) = try await liveStore(transport: transport)
        store.open(Self.alex)
        store.workspace.drafts[Self.alex] = "First try"
        await store.send(Self.alex)
        let failed = try XCTUnwrap(store.conversations[0].messages.last)
        XCTAssertEqual(failed.sendState, .failed("Allow Mosaic to control Messages."))
        XCTAssertEqual(store.sendErrors[Self.alex], "Allow Mosaic to control Messages.")
        // Refreshes keep the refused bubble, and a row with the same text does not claim it.
        record("First try", date: Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000), at: path)
        store.historyLimits[Self.alex] = 200
        await store.refresh()
        let afterRefresh = store.conversations[0].messages
        XCTAssertEqual(afterRefresh.filter { $0.text == "First try" }.count, 2, "the database's row and the refused bubble are different things")
        XCTAssertEqual(afterRefresh.last?.sendState, .failed("Allow Mosaic to control Messages."))
        XCTAssertEqual(transport.submissions.count, 1, "nothing is resent on its own")
        // Try Again sends it as it was.
        await store.retrySend(failed.presentationID, in: Self.alex)
        XCTAssertEqual(transport.submissions.count, 2)
        XCTAssertEqual(store.conversations[0].messages.last?.sendState, .submitted)
        XCTAssertNil(store.sendErrors[Self.alex])
        // A second refusal, taken back into the composer.
        transport.failures[2] = "Messages is busy."
        store.workspace.drafts[Self.alex] = "Second try"
        await store.send(Self.alex)
        let second = try XCTUnwrap(store.conversations[0].messages.last)
        XCTAssertEqual(second.sendState, .failed("Messages is busy."))
        store.reclaimFailedSend(second.presentationID, in: Self.alex)
        XCTAssertEqual(store.workspace.drafts[Self.alex], "Second try")
        XCTAssertFalse(store.conversations[0].messages.contains { $0.presentationID == second.presentationID })
        XCTAssertNil(store.sendErrors[Self.alex])
        // And one removed outright.
        transport.failures[3] = "No."
        store.workspace.drafts[Self.alex] = "Third"
        await store.send(Self.alex)
        let third = try XCTUnwrap(store.conversations[0].messages.last)
        store.discardFailedSend(third.presentationID, in: Self.alex)
        XCTAssertFalse(store.conversations[0].messages.contains { $0.presentationID == third.presentationID })
    }

    @MainActor func testTheDatabaseRowTakesTheBubblesPlace() async throws {
        let transport = RecordingTransport()
        let (store, path) = try await liveStore(transport: transport)
        store.open(Self.alex)
        store.workspace.drafts[Self.alex] = "See you at 5"
        await store.send(Self.alex)
        let bubble = try XCTUnwrap(store.conversations[0].messages.last)
        XCTAssertEqual(bubble.sendState, .submitted)
        record("See you at 5", date: Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000), at: path)
        await store.refresh()
        let confirmed = try XCTUnwrap(store.conversations[0].messages.last)
        XCTAssertNil(confirmed.sendState, "the row is the database's")
        XCTAssertTrue(confirmed.isDelivered)
        XCTAssertEqual(confirmed.presentationID, bubble.presentationID, "the bubble keeps its identity")
        XCTAssertEqual(store.conversations[0].messages.filter { $0.text == "See you at 5" }.count, 1)
    }

    @MainActor func testDemoModeNeverTouchesTheLiveTransport() async throws {
        let transport = RecordingTransport()
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true, transport: transport)
        let id = store.workspace.openIDs[0]
        store.workspace.drafts[id] = "Demo"
        await store.send(id)
        XCTAssertEqual(store.conversations[0].messages.last?.text, "Demo")
        XCTAssertTrue(transport.submissions.isEmpty)
        XCTAssertEqual(store.transport.capabilities, .messagesAppleScript)
        XCTAssertFalse(store.transport.capabilities.nativeReply, "Messages' dictionary has no reply or Tapback command")
    }
}
