import XCTest
import CSQLite
@testable import MosaicCore

final class DatabaseTests: XCTestCase {
    var directory: URL!
    var path: String!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("chat.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
          is_delivered INTEGER, is_read INTEGER, error INTEGER, cache_has_attachments INTEGER, associated_message_type INTEGER, item_type INTEGER,
          date_read INTEGER DEFAULT 0);
        INSERT INTO handle VALUES ('alex@example.test'), ('jamie@example.test');
        INSERT INTO chat VALUES ('iMessage;-;alex@example.test', '', 'alex@example.test', 'iMessage'), ('iMessage;+;group', 'Friends', 'group', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1),(2,1),(2,2);
        INSERT INTO message VALUES ('First',NULL,700000000000000000,0,1,0,0,0,0,0,0,0),
          ('Second',NULL,700000001000000000,1,0,1,0,0,0,0,0,0),
          (NULL,NULL,700000002000000000,0,2,0,0,0,1,0,0,0);
        INSERT INTO chat_message_join VALUES (1,1),(1,2),(2,3);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testHistoriesAreIsolatedOrderedAndReadOnly() throws {
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try MessagesDatabase(path: path).load(openIDs: ["iMessage;-;alex@example.test", "iMessage;+;group"])
        let alex = try XCTUnwrap(result.first { $0.id == "iMessage;-;alex@example.test" })
        let group = try XCTUnwrap(result.first { $0.id == "iMessage;+;group" })
        XCTAssertEqual(alex.name, "alex@example.test")
        XCTAssertEqual(alex.messages.map(\.text), ["First", "Second"])
        XCTAssertFalse(alex.messages[0].isFromMe)
        XCTAssertTrue(alex.messages[1].isDelivered)
        XCTAssertEqual(group.participants.count, 2)
        XCTAssertEqual(group.messages.count, 1)
        XCTAssertEqual(group.messages[0].text, "Attachment · Open in Messages")
        XCTAssertEqual(group.messages[0].attachmentCount, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }
    func testPinnedChatRemainsAvailableOutsideRecentLimit() throws {
        let result = try MessagesDatabase(path: path).load(openIDs: ["iMessage;-;alex@example.test"], limit: 1, historyLimit: 1)
        XCTAssertEqual(result.count, 2)
        let alex = try XCTUnwrap(result.first { $0.id == "iMessage;-;alex@example.test" })
        XCTAssertEqual(alex.messages.map(\.text), ["Second"])
        XCTAssertTrue(result.first!.messages.isEmpty)
    }
    func testDeniedAccessHasActionableError() {
        XCTAssertThrowsError(try MessagesDatabase(path: directory.appendingPathComponent("missing.db").path).load(openIDs: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Full Disk Access"))
        }
    }
    func testAppleDatesInSecondsAndNanoseconds() {
        XCTAssertEqual(MessagesDatabase.appleDate(700000000), MessagesDatabase.appleDate(700000000000000000))
        _ = MessagesDatabase.appleDate(Int64.min) // malformed values must not trap
    }
    func testUnchangedDatabaseIsSkippedByItsFingerprint() throws {
        let database = MessagesDatabase(path: path)
        let first = try XCTUnwrap(try database.snapshot(openIDs: ["iMessage;-;alex@example.test"], unlessUnchangedFrom: nil))
        XCTAssertEqual(first.conversations.count, 2)
        XCTAssertNil(try database.snapshot(openIDs: ["iMessage;-;alex@example.test"], unlessUnchangedFrom: first.fingerprint),
                     "nothing changed, so the poll has nothing to load")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET is_read = 1, date_read = 700000005000000000 WHERE ROWID = 2", nil, nil, nil), SQLITE_OK)
        let second = try XCTUnwrap(try database.snapshot(openIDs: ["iMessage;-;alex@example.test"], unlessUnchangedFrom: first.fingerprint),
                                   "a read receipt changes the fingerprint")
        XCTAssertNotEqual(second.fingerprint, first.fingerprint)
        XCTAssertTrue(second.conversations.first { $0.databaseID == 1 }?.messages.last?.isRead ?? false)
        XCTAssertEqual(database.watchedPaths, [path, path + "-wal"])
    }
    func testWALContentIsVisibleWithoutCopyingDatabase() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES ('In the WAL',NULL,700000003000000000,0,1,0,0,0,0,0,0,0); INSERT INTO chat_message_join VALUES (1,4);", nil, nil, nil), SQLITE_OK)
        let result = try MessagesDatabase(path: path).load(openIDs: ["iMessage;-;alex@example.test"])
        XCTAssertEqual(result.first { $0.databaseID == 1 }?.messages.last?.text, "In the WAL")
    }
}
