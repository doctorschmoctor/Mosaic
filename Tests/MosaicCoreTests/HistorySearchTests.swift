import XCTest
import CSQLite
@testable import MosaicCore

/// Searching a conversation's older history and reading the messages around a result: bounded,
/// read-only, by the exact conversation, with words matched literally.
final class HistorySearchTests: XCTestCase {
    static let alex = "iMessage;-;alex@example.test"
    var directory: URL!
    var path: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicSearch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("chat.db").path
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
          associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT, item_type INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
        INSERT INTO handle VALUES ('alex@example.test');
        INSERT INTO chat VALUES ('\(Self.alex)', '', 'alex@example.test', 'iMessage'), ('iMessage;-;other@example.test', '', 'other', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1);
        BEGIN;
        """
        // Rows 1–40 in Alex's chat, one second apart: "message n", with a few special ones.
        let special: [Int: String] = [3: "Café at 50% off", 5: "use a_b here", 7: "the plan for Café Luna", 9: "5000 off", 20: "ab here", 30: "Plan B"]
        for n in 1...40 {
            let text = special[n] ?? "message \(n)"
            sql += "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('G\(n)', '\(text)', \(700_000_000_000_000_000 + Int64(n) * 1_000_000_000), \(n % 2), 1);"
            sql += "INSERT INTO chat_message_join VALUES (1, \(n));"
        }
        // Row 41: a reaction mentioning café; row 42: unsent; row 43: activity; row 44: café in another chat.
        sql += """
        INSERT INTO message (guid, text, date, is_from_me, handle_id, associated_message_type, associated_message_guid) VALUES ('R', 'Loved “Café”', 700000041000000000, 0, 1, 2000, 'p:0/G3');
        INSERT INTO chat_message_join VALUES (1, 41);
        INSERT INTO message (guid, text, date, is_from_me, handle_id, date_retracted) VALUES ('U', 'café secret', 700000042000000000, 1, 0, 700000043000000000);
        INSERT INTO chat_message_join VALUES (1, 42);
        INSERT INTO message (guid, text, date, is_from_me, handle_id, item_type) VALUES ('A', 'café renamed', 700000043000000000, 0, 1, 2);
        INSERT INTO chat_message_join VALUES (1, 43);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('O', 'café elsewhere', 700000044000000000, 0, 1);
        INSERT INTO chat_message_join VALUES (2, 44);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('N', 'newest', 700000045000000000, 1, 0);
        INSERT INTO chat_message_join VALUES (1, 45);
        COMMIT;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var reader: MessagesReader { MessagesReader(database: MessagesDatabase(path: path)) }
    private func cursor(_ row: Int64) -> HistorySearchCursor {
        HistorySearchCursor(rowID: row, date: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(row)))
    }

    func testOlderMessagesAreSearchedLiterallyAndOnlyInTheirConversation() throws {
        let reader = self.reader
        let start = cursor(45)
        let cafe = try XCTUnwrap(try reader.searchHistorySync(forChat: Self.alex, matching: "cafe", before: start))
        XCTAssertEqual(cafe.matches.map(\.id), ["7", "3"], "accents and case ignored; newest first; not a reaction, an unsent message, an activity line or another chat")
        XCTAssertNil(cafe.next, "the first message was reached")
        XCTAssertEqual(try reader.searchHistorySync(forChat: Self.alex, matching: "50%", before: start)?.matches.map(\.id), ["3"], "% is a character, not a wildcard")
        XCTAssertEqual(try reader.searchHistorySync(forChat: Self.alex, matching: "a_b", before: start)?.matches.map(\.id), ["5"], "so is _")
        XCTAssertEqual(try reader.searchHistorySync(forChat: Self.alex, matching: "plan", before: cursor(30))?.matches.map(\.id), ["7"],
                       "only messages older than the cursor")
        XCTAssertEqual(try reader.searchHistorySync(forChat: Self.alex, matching: "   ", before: start)?.matches, [])
        XCTAssertNil(try reader.searchHistorySync(forChat: "iMessage;-;nobody", matching: "cafe", before: start))
    }

    func testASearchGoesPartByPart() throws {
        let reader = self.reader
        let first = try XCTUnwrap(try reader.searchHistorySync(forChat: Self.alex, matching: "message", before: cursor(45), scanLimit: 10))
        XCTAssertEqual(first.scanned, 10, "a part reads no more than asked")
        XCTAssertEqual(first.matches.first?.id, "40")
        let next = try XCTUnwrap(first.next)
        let second = try XCTUnwrap(try reader.searchHistorySync(forChat: Self.alex, matching: "message", before: next, scanLimit: 10))
        XCTAssertTrue(Set(second.matches.map(\.id)).isDisjoint(with: first.matches.map(\.id)), "parts never repeat a message")
        XCTAssertLessThan(Int(second.matches.first?.id ?? "0") ?? 0, Int(first.matches.last?.id ?? "0") ?? 0)
        let capped = try XCTUnwrap(try reader.searchHistorySync(forChat: Self.alex, matching: "message", before: cursor(45), maxMatches: 3))
        XCTAssertEqual(capped.matches.count, 3)
        XCTAssertEqual(capped.next?.rowID, Int64(capped.matches.last?.id ?? ""), "the next part starts after the last match")
    }

    func testTheMessagesAroundAResult() throws {
        let reader = self.reader
        let context = try XCTUnwrap(try reader.contextSync(forChat: Self.alex, around: 20, before: 3, after: 2))
        XCTAssertEqual(context.page.messages.map(\.id), ["17", "18", "19", "20", "21", "22"])
        XCTAssertEqual(context.anchorID, "20")
        XCTAssertFalse(context.reachesLatest)
        XCTAssertFalse(context.reachesStart)
        let start = try XCTUnwrap(try reader.contextSync(forChat: Self.alex, around: 2, before: 5, after: 1))
        XCTAssertEqual(start.page.messages.map(\.id), ["1", "2", "3"])
        XCTAssertTrue(start.reachesStart)
        let latest = try XCTUnwrap(try reader.contextSync(forChat: Self.alex, around: 40, before: 1, after: 10))
        XCTAssertTrue(latest.reachesLatest, "the window runs to the newest message")
        XCTAssertEqual(latest.page.messages.last?.id, "45")
        XCTAssertNil(try reader.contextSync(forChat: Self.alex, around: 44), "a message of another conversation is never shown")
    }

    func testReadingNeverWritesToTheDatabase() throws {
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let reader = self.reader
        _ = try reader.searchHistorySync(forChat: Self.alex, matching: "cafe", before: cursor(45))
        _ = try reader.contextSync(forChat: Self.alex, around: 20)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }
}
