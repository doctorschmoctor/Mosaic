import XCTest
import CSQLite
@testable import MosaicCore

/// What a conversation shared over its whole history: its files (not stickers, hidden files,
/// link-preview payloads or anything from an unsent message) and the web links in its words,
/// newest first, each link once, from that conversation only. Fictional rows only.
final class SharedHistoryTests: XCTestCase {
    static let alex = "iMessage;-;alex@example.test"
    var directory: URL!
    var path: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicShared-\(UUID())")
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
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, transfer_name TEXT, is_sticker INTEGER DEFAULT 0,
          hide_attachment INTEGER DEFAULT 0, total_bytes INTEGER DEFAULT 0);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle VALUES ('alex@example.test');
        INSERT INTO chat VALUES ('\(Self.alex)', '', 'alex@example.test', 'iMessage'), ('iMessage;-;other@example.test', '', 'other', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1);
        BEGIN;
        """
        // Rows 1–30 in Alex's chat, one second apart.
        let texts: [Int: String] = [2: "first look https://example.com/a", 12: "see www.example.org/plan", 20: "again https://example.com/a",
                                    25: "plain words", 28: "https://example.net/new"]
        for n in 1...30 {
            sql += "INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('G\(n)', '\(texts[n] ?? "message \(n)")', \(700_000_000_000_000_000 + Int64(n) * 1_000_000_000), \(n % 2), 1);"
            sql += "INSERT INTO chat_message_join VALUES (1, \(n));"
        }
        sql += """
        INSERT INTO message (guid, text, date, is_from_me, handle_id, date_retracted) VALUES ('U', 'https://example.com/unsent', 700000031000000000, 1, 0, 700000032000000000);
        INSERT INTO chat_message_join VALUES (1, 31);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('O', 'https://example.com/elsewhere', 700000033000000000, 0, 1);
        INSERT INTO chat_message_join VALUES (2, 32);
        INSERT INTO attachment VALUES ('A1', '~/Library/Messages/Attachments/a/one.jpg', 'image/jpeg', 'public.jpeg', 'one.jpg', 0, 0, 1000),
          ('A2', '~/Library/Messages/Attachments/b/plan.pdf', 'application/pdf', 'com.adobe.pdf', 'plan.pdf', 0, 0, 2000),
          ('A3', '~/Library/Messages/Attachments/c/sticker.png', 'image/png', 'public.png', 'sticker.png', 1, 0, 10),
          ('A4', '~/Library/Messages/Attachments/d/hidden.png', 'image/png', 'public.png', 'hidden.png', 0, 1, 10),
          ('A5', '~/Library/Messages/Attachments/e/x.pluginPayloadAttachment', NULL, NULL, 'x', 0, 0, 10),
          ('A6', '~/Library/Messages/Attachments/f/gone.mov', 'video/quicktime', 'com.apple.quicktime-movie', 'gone.mov', 0, 0, 10),
          ('A7', '~/Library/Messages/Attachments/g/elsewhere.jpg', 'image/jpeg', 'public.jpeg', 'elsewhere.jpg', 0, 0, 10);
        INSERT INTO message_attachment_join VALUES (3,1),(9,2),(10,3),(11,4),(15,5),(31,6),(32,7);
        COMMIT;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var reader: MessagesReader { MessagesReader(database: MessagesDatabase(path: path), background: true) }

    func testFilesAndLinksFromTheWholeHistory() throws {
        let shared = try XCTUnwrap(try reader.sharedHistorySync(forChat: Self.alex))
        XCTAssertEqual(shared.files.map(\.attachment.name), ["plan.pdf", "one.jpg"],
                       "newest first; no sticker, hidden file, link payload, unsent message's file or another chat's")
        XCTAssertEqual(shared.files.map(\.messageID), ["9", "3"])
        XCTAssertNil(shared.files.first?.attachment.path, "a file not on this Mac has no path")
        XCTAssertEqual(shared.links.map { ($0.url.host ?? "") + $0.url.path }, ["example.net/new", "example.com/a", "www.example.org/plan"],
                       "each link once, from its newest message; not an unsent message's or another chat's")
        XCTAssertEqual(shared.links[1].messageID, "20")
        XCTAssertTrue(shared.filesComplete)
        XCTAssertTrue(shared.linksComplete)
        XCTAssertNil(try reader.sharedHistorySync(forChat: "iMessage;-;nobody"))
    }

    func testLimitsSayTheOldestWereLeftOut() throws {
        let shared = try XCTUnwrap(try reader.sharedHistorySync(forChat: Self.alex, fileLimit: 1, linkLimit: 1))
        XCTAssertEqual(shared.files.map(\.attachment.name), ["plan.pdf"])
        XCTAssertFalse(shared.filesComplete)
        XCTAssertEqual(shared.links.map(\.url.absoluteString), ["https://example.net/new"])
        XCTAssertFalse(shared.linksComplete)
    }

    func testReadingNeverWritesToTheDatabase() throws {
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try reader.sharedHistorySync(forChat: Self.alex)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }
}
