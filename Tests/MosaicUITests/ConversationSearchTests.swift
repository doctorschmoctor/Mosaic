import XCTest
import AppKit
import CSQLite
import MosaicCore
@testable import Mosaic

/// Find in Conversation over the loaded messages, then the search of older history: its parts,
/// a superseded search that never shows its results, and the window around an older result that
/// never counts as reading the newest messages.
final class ConversationSearchTests: XCTestCase {
    static let alex = "iMessage;-;alex@example.test"
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "MosaicFindTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// 300 fictional messages with Alex: the newest 100 load with the tile; "lighthouse" appears
    /// only in rows 10 and 150, and "rare" only in row 5.
    private func makeDatabase() throws -> String {
        let path = directory.appending(path: "chat.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
          is_delivered INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, error INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0,
          associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT, item_type INTEGER DEFAULT 0);
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, transfer_name TEXT, is_sticker INTEGER DEFAULT 0,
          hide_attachment INTEGER DEFAULT 0, total_bytes INTEGER DEFAULT 0);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO attachment VALUES ('OLD', '~/Library/Messages/Attachments/z/old.pdf', 'application/pdf', 'com.adobe.pdf', 'old.pdf', 0, 0, 100);
        INSERT INTO message_attachment_join VALUES (8, 1);
        INSERT INTO handle VALUES ('alex@example.test');
        INSERT INTO chat VALUES ('\(Self.alex)', '', 'alex@example.test', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1);
        BEGIN;
        """
        for n in 1...300 {
            let text = n == 10 || n == 150 ? "the lighthouse at dusk" : n == 5 ? "a rare word" : n == 290 ? "near the lighthouse"
                : n == 7 ? "old link https://example.com/old" : n == 295 ? "new link https://example.com/new" : "note \(n)"
            sql += "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('G\(n)', '\(text)', \(690_000_000_000_000_000 + Int64(n) * 1_000_000_000), \(n % 2), 1);"
            sql += "INSERT INTO chat_message_join VALUES (1, \(n));"
        }
        XCTAssertEqual(sqlite3_exec(db, sql + "COMMIT;", nil, nil, nil), SQLITE_OK)
        return path
    }
    @MainActor private func liveStore() async throws -> WorkspaceStore {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, database: MessagesDatabase(path: try makeDatabase()),
                                   transport: RecordingTransport())
        for _ in 0..<300 where store.conversations.first?.messages.count != 100 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.openIDs, [Self.alex])
        XCTAssertEqual(store.conversations.first?.messages.count, 100, "the newest 100 are loaded")
        return store
    }
    @MainActor private func waitForSearch(_ store: WorkspaceStore) async throws {
        for _ in 0..<300 where store.historySearches[Self.alex]?.isSearching == true { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testFindMatchesLoadedMessagesIgnoringCaseAndAccentsNeverUnsentOnes() {
        let messages = [Message(id: "1", text: "Café later?", date: Date(), isFromMe: false),
                        Message(id: "2", text: "renamed the café", date: Date(), isFromMe: false, kind: .activity),
                        Message(id: "3", text: "CAFE it is", date: Date(), isFromMe: true),
                        Message(id: "4", text: "", date: Date(), isFromMe: true, dateRetracted: Date()),
                        Message(id: "5", text: "tea", date: Date(), isFromMe: false)]
        XCTAssertEqual(FindInConversation.matches("cafe", in: messages), ["1", "3"], "oldest first; not an activity line")
        XCTAssertEqual(FindInConversation.matches("  ", in: messages), [])
        XCTAssertEqual(FindInConversation.matches("50%", in: [Message(id: "6", text: "50% off", date: Date(), isFromMe: false)]), ["6"])
        let marked = MessageText.highlighted("Café, then more café: cafe.example.com", "cafe")
        XCTAssertEqual(marked.runs.filter { $0.backgroundColor != nil }.count, 3, "every occurrence is marked")
        XCTAssertTrue(marked.runs.contains { $0.link != nil }, "links stay links")
    }

    @MainActor func testOlderHistoryIsSearchedPartByPartFromTheOldestLoadedMessage() async throws {
        let store = try await liveStore()
        XCTAssertEqual(FindInConversation.matches("lighthouse", in: store.conversations[0].messages).count, 1, "only row 290 is loaded")
        store.searchOlderHistory(Self.alex, query: "lighthouse")
        try await waitForSearch(store)
        var search = try XCTUnwrap(store.historySearches[Self.alex])
        XCTAssertEqual(search.matches.map(\.id), ["150", "10"], "older than what is loaded, newest first")
        XCTAssertNil(search.next, "200 older messages fit in one part")
        XCTAssertEqual(search.scanned, 200)

        // A search that is superseded never shows its results.
        store.searchOlderHistory(Self.alex, query: "rare")
        store.searchOlderHistory(Self.alex, query: "dusk")
        try await waitForSearch(store)
        search = try XCTUnwrap(store.historySearches[Self.alex])
        XCTAssertEqual(search.query, "dusk")
        XCTAssertEqual(search.matches.map(\.id), ["150", "10"])
        store.searchOlderHistory(Self.alex, query: "rare")
        store.cancelOlderSearch(Self.alex)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.historySearches[Self.alex], "a cancelled search leaves nothing")
    }

    @MainActor func testTheWindowAroundAnOlderResultIsNeverTakenAsRead() async throws {
        let store = try await liveStore()
        let boundary = store.seenBoundary(Self.alex)
        store.tailSeen(Self.alex)
        await store.showInContext(Self.alex, messageID: "150")
        let window = try XCTUnwrap(store.contextWindows[Self.alex])
        XCTAssertTrue(window.page.messages.contains { $0.id == "150" })
        XCTAssertFalse(window.reachesLatest)
        XCTAssertEqual(store.conversations.first?.messages.count, 100, "the tile's own history is untouched")
        // The window's own thread reports nothing; the tile's newest messages are not in view.
        store.seeingMayHaveChanged()
        XCTAssertEqual(store.seenBoundary(Self.alex), boundary)
        store.leaveContext(Self.alex)
        XCTAssertNil(store.contextWindows[Self.alex])
        // A result among the loaded messages needs no window.
        await store.showInContext(Self.alex, messageID: "290")
        XCTAssertNil(store.contextWindows[Self.alex])
        // Closing the tile lets the search and the window go.
        store.searchOlderHistory(Self.alex, query: "lighthouse")
        store.close(Self.alex)
        XCTAssertNil(store.historySearches[Self.alex])
    }

    /// The older history is searched part after part by itself, back to the first message, with
    /// nothing to press.
    @MainActor func testTheOlderHistoryIsSearchedToTheStartByItself() async throws {
        let store = try await liveStore()
        store.historyPageSize = 50
        store.searchOlderHistory(Self.alex, query: "lighthouse")
        try await waitForSearch(store)
        let search = try XCTUnwrap(store.historySearches[Self.alex])
        XCTAssertEqual(search.matches.map(\.id), ["150", "10"], "found across four parts")
        XCTAssertNil(search.next, "back to the first message")
        XCTAssertEqual(search.scanned, 200)
        XCTAssertFalse(search.isSearching)
    }

    /// A search pauses at its bounds (very many matches, or a very long history) until asked to go on.
    @MainActor func testASearchPausesAtItsBoundsUntilAskedToGoOn() async throws {
        let store = try await liveStore()
        store.historyPageSize = 50
        store.historyMatchLimit = 1
        store.searchOlderHistory(Self.alex, query: "lighthouse")
        try await waitForSearch(store)
        var search = try XCTUnwrap(store.historySearches[Self.alex])
        XCTAssertEqual(search.matches.map(\.id), ["150"])
        XCTAssertNotNil(search.next, "paused, not finished")
        store.continueOlderSearch(Self.alex)
        try await waitForSearch(store)
        search = try XCTUnwrap(store.historySearches[Self.alex])
        XCTAssertEqual(search.matches.map(\.id), ["150", "10"])
    }

    /// The details gather files and links from the whole history, not only the loaded messages,
    /// each once.
    @MainActor func testDetailsReachTheWholeHistory() async throws {
        let store = try await liveStore()
        let loaded = try XCTUnwrap(store.conversations.first).messages
        XCTAssertEqual(SharedContent(messages: loaded).links.map(\.url.absoluteString), ["https://example.com/new"], "only the loaded one")
        let history = try XCTUnwrap(await store.sharedHistory(Self.alex))
        let content = SharedContent(messages: loaded, history: history)
        XCTAssertEqual(content.links.map(\.url.absoluteString), ["https://example.com/new", "https://example.com/old"], "newest first, each once")
        XCTAssertEqual(content.files.map(\.attachment.name), ["old.pdf"])
        XCTAssertEqual(content.files.first?.messageID, "8")
        let again = try XCTUnwrap(await store.sharedHistory(Self.alex))
        XCTAssertEqual(again, history, "read once per session")
    }

    /// Typing in the find bar never redraws the thread: the loaded matches are worked out once
    /// per query, and only the matching bubbles are given the words.
    @MainActor func testFindWorkIsDoneOncePerQuery() throws {
        let messages = (1...300).map { Message(id: "\($0)", text: $0 % 50 == 0 ? "lighthouse \($0)" : "note \($0)", date: Date(), isFromMe: false) }
        let index = FindIndex()
        XCTAssertEqual(index.matches("lighthouse", in: messages), ["50", "100", "150", "200", "250", "300"])
        XCTAssertEqual(index.matches("lighthouse", in: messages), ["50", "100", "150", "200", "250", "300"], "the same answer, from the last time")
        XCTAssertEqual(index.matches("light", in: messages).count, 6)
        XCTAssertEqual(index.rowIDs(of: messages).count, 300)

        let presentation = ThreadPresentation()
        _ = presentation.prepared(for: Conversation(id: "c", name: "Alex", participants: ["alex@example.test"], messages: messages))
        XCTAssertEqual(presentation.findMatches("lighthouse"), ["50", "100", "150", "200", "250", "300"])
        XCTAssertEqual(presentation.findMatches(""), [])

        // Bubbles compare by what they show, not by their closures.
        let message = messages[49]
        let a = MessageBubble(message: message, group: false, senderName: nil, live: true, service: "iMessage", findQuery: "lighthouse")
        var b = MessageBubble(message: message, group: false, senderName: nil, live: true, service: "iMessage", findQuery: "lighthouse",
                              actorName: { _ in "Other" })
        XCTAssertTrue(a == b)
        b.findQuery = "light"
        XCTAssertFalse(a == b, "new words redraw a matching bubble")
        b.findQuery = "lighthouse"; b.nameContext = 1
        XCTAssertFalse(a == b, "so do changed names")
    }
}

