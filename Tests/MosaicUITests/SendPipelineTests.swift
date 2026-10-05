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
    /// Inserts an incoming message from Alex.
    private func receive(_ text: String, at path: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let date = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        let sql = "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('\(UUID().uuidString)', '\(text)', \(date), 0, 1); INSERT INTO chat_message_join VALUES (1, last_insert_rowid());"
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
        // Until Messages is being asked (on a slow machine this takes more than a moment).
        for _ in 0..<400 where transport.submissions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
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

    /// A message that arrives in an open tile you are not in puts a dot beside its name until you
    /// go to that tile; one in the tile you are in, or one you sent, does not.
    @MainActor func testATileYouAreNotInShowsADotForANewMessage() async throws {
        let transport = RecordingTransport()
        let (store, path) = try await liveStore(transport: transport)
        store.open(Self.alex)
        await store.refresh()
        receive("in the tile you are in", at: path)
        await store.refresh()
        XCTAssertTrue(store.tilesWithNews.isEmpty, "you are in this tile")
        // Somewhere else now: a New Message tile has the keyboard.
        let elsewhere = try XCTUnwrap(store.beginNewChat())
        XCTAssertEqual(store.workspace.focusedID, elsewhere)
        record("from me", date: Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000), at: path)
        await store.refresh()
        XCTAssertTrue(store.tilesWithNews.isEmpty, "a message you sent is not news")
        receive("hey", at: path)
        await store.refresh()
        XCTAssertEqual(store.tilesWithNews, [Self.alex])
        store.requestComposerFocus(Self.alex)
        XCTAssertTrue(store.tilesWithNews.isEmpty, "going to the tile clears its dot")
        // Closing a tile with a dot lets it go.
        store.requestComposerFocus(elsewhere)
        receive("again", at: path)
        await store.refresh()
        XCTAssertEqual(store.tilesWithNews, [Self.alex])
        store.close(Self.alex)
        XCTAssertTrue(store.tilesWithNews.isEmpty)
    }

    /// Older messages from Alex, above the fixture's two: pairs of them share a moment.
    private func insertEarlier(_ count: Int, at path: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = "BEGIN;"
        for n in 0..<count {
            let date = 690_000_000_000_000_000 + Int64(n / 2) * 1_000_000_000
            sql += "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('E\(n)', 'old\(n)', \(date), 0, 1); INSERT INTO chat_message_join VALUES (1, last_insert_rowid());"
        }
        XCTAssertEqual(sqlite3_exec(db, sql + "COMMIT;", nil, nil, nil), SQLITE_OK)
    }

    /// Scrolling back reads only the 100 messages before the oldest one shown — by a cursor, one
    /// step at a time, asking again while a step loads does nothing — and puts them above the
    /// others without repeats or gaps, equal times included. Later loads read only the newest
    /// page: the earlier messages stay above it and new ones arrive below.
    @MainActor func testEarlierMessagesLoadByCursorOneStepAtATime() async throws {
        let (store, path) = try await liveStore(transport: RecordingTransport())
        store.open(Self.alex)
        insertEarlier(248, at: path)
        await store.refresh()
        func texts() -> [String] { store.conversations.first { $0.id == Self.alex }?.messages.map(\.text) ?? [] }
        XCTAssertEqual(texts(), (150..<248).map { "old\($0)" } + ["Hello", "Hi!"], "a load reads the newest 100")
        store.loadMore(Self.alex)
        store.loadMore(Self.alex)
        XCTAssertEqual(store.historyLimits[Self.alex], 200)
        XCTAssertTrue(store.loadingMore.contains(Self.alex))
        for _ in 0..<200 where store.loadingMore.contains(Self.alex) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loadingMore.contains(Self.alex))
        XCTAssertEqual(texts(), (50..<248).map { "old\($0)" } + ["Hello", "Hi!"], "the 100 before the oldest shown, once each")
        // A new message: the load reads the newest page; the earlier ones stay above it, within the depth asked for.
        receive("Fresh", at: path)
        await store.refresh()
        XCTAssertEqual(texts(), (51..<248).map { "old\($0)" } + ["Hello", "Hi!", "Fresh"])
        // The next step reaches the first message.
        store.loadMore(Self.alex)
        XCTAssertEqual(store.historyLimits[Self.alex], 300)
        for _ in 0..<200 where store.loadingMore.contains(Self.alex) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(texts(), (0..<248).map { "old\($0)" } + ["Hello", "Hi!", "Fresh"])
        let ids = store.conversations.first { $0.id == Self.alex }?.messages.map(\.id) ?? []
        XCTAssertEqual(Set(ids).count, ids.count)
        // Closing the tile lets the earlier messages go; it opens on its newest page again.
        store.close(Self.alex)
        XCTAssertNil(store.historyLimits[Self.alex])
    }

    /// Earlier messages are kept only where they meet the newest page; when more than a page
    /// arrives at once they would leave a gap, and the tile starts over from the newest page.
    @MainActor func testEarlierMessagesNeverLeaveAGap() {
        func message(_ row: Int) -> Message {
            Message(id: String(row), text: "m\(row)", date: Date(timeIntervalSinceReferenceDate: TimeInterval(row)), isFromMe: false)
        }
        let shown = Conversation(id: "c", name: "C", participants: [], messages: (1...6).map(message))
        let slid = Conversation(id: "c", name: "C", participants: [], messages: (4...8).map(message))
        XCTAssertEqual(WorkspaceStore.keepingEarlier(of: shown, in: slid, depth: 7)?.messages.map(\.id), ["2", "3", "4", "5", "6", "7", "8"])
        let jumped = Conversation(id: "c", name: "C", participants: [], messages: (10...12).map(message))
        XCTAssertNil(WorkspaceStore.keepingEarlier(of: shown, in: jumped, depth: 7))
    }

    /// More one-to-one conversations, each with one message.
    private func addConversations(_ names: [String], at path: String) -> [String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = "BEGIN;"
        for (n, name) in names.enumerated() {
            let row = n + 2
            sql += """
            INSERT INTO handle VALUES ('\(name)@example.test');
            INSERT INTO chat VALUES ('iMessage;-;\(name)@example.test', '', '\(name)@example.test', 'iMessage');
            INSERT INTO chat_handle_join VALUES (\(row), \(row));
            INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('\(name)-1', 'Hi from \(name)', \(700000003000000000 + Int64(n) * 1_000_000_000), 0, \(row));
            INSERT INTO chat_message_join VALUES (\(row), last_insert_rowid());
            """
        }
        XCTAssertEqual(sqlite3_exec(db, sql + "COMMIT;", nil, nil, nil), SQLITE_OK)
        return names.map { "iMessage;-;\($0)@example.test" }
    }

    /// Sweeping the pointer down the list fetches nothing; resting on a row fetches it after a
    /// short pause. Reads ahead go one at a time, and a conversation that opens while its read
    /// ahead is still waiting is read at once, not twice.
    @MainActor func testReadsAheadWaitForThePointerToRestAndNeverCrowdAnOpeningTile() async throws {
        let (store, path) = try await liveStore(transport: RecordingTransport())
        let others = addConversations(["bea", "cal", "dev", "eli", "fay"], at: path)
        await store.refresh()
        XCTAssertEqual(Set(store.conversations.map(\.id)), Set(others + [Self.alex]))
        for _ in 0..<200 where store.isFetchingAhead { try await Task.sleep(for: .milliseconds(10)) }
        let start = store.prefetchReadCount
        // A sweep: each row is under the pointer for a moment only.
        for id in others {
            store.pointerEntered(id)
            try await Task.sleep(for: .milliseconds(10))
            store.pointerExited(id)
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.prefetchReadCount, start, "a sweep fetches nothing")
        XCTAssertFalse(others.contains { store.hasCachedHistory($0) })
        // Resting on a row fetches it once the pause is over.
        store.pointerEntered(others[0])
        XCTAssertEqual(store.prefetchReadCount, start)
        for _ in 0..<200 where !store.hasCachedHistory(others[0]) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.hasCachedHistory(others[0]))
        XCTAssertEqual(store.prefetchReadCount, start + 1)
        store.pointerExited(others[0])
        // Three wanted at once: one reads, the others wait their turn.
        store.prefetch(others[1]); store.prefetch(others[2]); store.prefetch(others[3])
        XCTAssertEqual(store.prefetchReadCount, start + 2, "one read ahead at a time")
        XCTAssertTrue(store.isWaitingToFetchAhead(others[2]))
        XCTAssertTrue(store.isWaitingToFetchAhead(others[3]))
        // One of the waiting ones opens: it is read now, and not read ahead as well.
        store.open(others[2])
        XCTAssertFalse(store.isWaitingToFetchAhead(others[2]))
        for _ in 0..<300 where store.isFetchingAhead || store.conversations.first(where: { $0.id == others[2] })?.messages.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.conversations.first { $0.id == others[2] }?.messages.map(\.text), ["Hi from dev"])
        XCTAssertTrue(store.hasCachedHistory(others[1]))
        XCTAssertTrue(store.hasCachedHistory(others[3]))
        XCTAssertEqual(store.prefetchReadCount, start + 3, "the opened conversation was not read ahead too")
    }

    /// Unread counts are Mosaic's own, from a seen boundary: every incoming message after it
    /// counts, sent ones never do, and reading the newest message clears the count.
    @MainActor func testUnreadCountsFollowIncomingMessagesAndTheSeenBoundary() async throws {
        let transport = RecordingTransport()
        let (store, path) = try await liveStore(transport: transport)
        XCTAssertEqual(store.seenBoundary(Self.alex), 2, "a conversation first seen starts with its newest row as seen")
        XCTAssertEqual(store.conversations[0].unreadCount, 0)
        receive("ok", at: path)
        await store.refresh()
        XCTAssertEqual(store.conversations[0].unreadCount, 1)
        receive("ok", at: path); receive("ok", at: path)
        await store.refresh()
        XCTAssertEqual(store.conversations[0].unreadCount, 3, "the same text three times is three messages")
        record("from me", date: Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000), at: path)
        await store.refresh()
        XCTAssertEqual(store.conversations[0].unreadCount, 3, "a sent message is not unread")
        // Opening or focusing a tile does not read it; the thread reports its newest message in view.
        store.open(Self.alex)
        store.focus(Self.alex)
        XCTAssertEqual(store.conversations[0].unreadCount, 3)
        store.markSeen(Self.alex)
        XCTAssertEqual(store.conversations[0].unreadCount, 0)
        XCTAssertEqual(store.seenBoundary(Self.alex), 6)
        await store.refresh()
        XCTAssertEqual(store.conversations[0].unreadCount, 0)
        // Closing the tile lets its history go back to the standard depth.
        store.historyLimits[Self.alex] = 300
        store.close(Self.alex)
        XCTAssertNil(store.historyLimits[Self.alex])
    }

    /// A tile opens on its messages at once: the most recent conversations are fetched ahead after
    /// the first load, a closed tile's history stays cached in memory, and a cached history is
    /// brought up to date by the load that follows.
    @MainActor func testTilesOpenOnCachedHistoryAtOnce() async throws {
        let transport = RecordingTransport()
        let (store, path) = try await liveStore(transport: transport)
        for _ in 0..<200 where !store.hasCachedHistory(Self.alex) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.hasCachedHistory(Self.alex), "recent conversations are fetched ahead")
        // A fresh workspace opens its first conversation by itself; close it to start from a closed tile.
        store.close(Self.alex)
        await store.refresh()
        XCTAssertTrue(store.conversations[0].messages.isEmpty, "a closed conversation holds no history itself")
        store.open(Self.alex)
        XCTAssertEqual(store.conversations[0].messages.map(\.text), ["Hello", "Hi!"], "the tile opens on its messages, before any load")
        // New messages since the cache was filled arrive with the load that follows.
        receive("Fresh", at: path)
        await store.refresh()
        XCTAssertEqual(store.conversations[0].messages.last?.text, "Fresh")
        // Closed and reopened: the cache has the latest history it showed.
        store.close(Self.alex)
        await store.refresh()
        XCTAssertTrue(store.conversations[0].messages.isEmpty)
        store.open(Self.alex)
        XCTAssertEqual(store.conversations[0].messages.last?.text, "Fresh")
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
