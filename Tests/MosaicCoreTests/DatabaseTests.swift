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
    private func execute(_ sql: String, at path: String? = nil) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path ?? self.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    private let alex = "iMessage;-;alex@example.test"

    /// Change detection is `data_version` on the reader's own connection: an unchanged database is
    /// one pragma, and every kind of commit — an old row's text, a read receipt, a renamed chat —
    /// brings a load, including the ones the old aggregate fingerprint could not see.
    func testUnchangedDatabaseIsSkippedAndEveryCommitIsSeen() throws {
        let reader = MessagesReader(database: MessagesDatabase(path: path))
        let request = LoadRequest(openIDs: [alex])
        let first = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: nil))
        XCTAssertEqual(first.conversations.count, 2)
        XCTAssertNil(try reader.loadSync(request, unlessUnchangedFrom: first.token), "nothing changed, so the poll has nothing to load")
        XCTAssertEqual(try reader.currentToken(), first.token)
        execute("UPDATE message SET text = 'First, edited' WHERE ROWID = 1")
        let edited = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: first.token), "an old row's text changed")
        XCTAssertNotEqual(edited.token, first.token)
        XCTAssertEqual(edited.conversations.first { $0.databaseID == 1 }?.messages.first?.text, "First, edited")
        execute("UPDATE message SET is_read = 1, date_read = 700000005000000000 WHERE ROWID = 2")
        let read = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: edited.token), "a read receipt")
        XCTAssertTrue(read.conversations.first { $0.databaseID == 1 }?.messages.last?.isRead ?? false)
        execute("UPDATE chat SET display_name = 'Alex!' WHERE ROWID = 1")
        let renamed = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: read.token), "a renamed chat")
        XCTAssertEqual(renamed.conversations.first { $0.databaseID == 1 }?.name, "Alex!")
        XCTAssertNil(try reader.loadSync(request, unlessUnchangedFrom: renamed.token))
        XCTAssertEqual(MessagesDatabase(path: path).watchedPaths, [path, path + "-wal"])
    }

    /// A different request loads even when the database is unchanged, and each tile's history is
    /// as deep as that tile asked for — one tile asking for more never deepens the others.
    func testHistoryDepthIsPerConversationAndANewRequestAlwaysLoads() throws {
        execute("INSERT INTO message VALUES ('Third',NULL,700000003000000000,0,1,0,0,0,0,0,0,0); INSERT INTO chat_message_join VALUES (1,4);")
        let reader = MessagesReader(database: MessagesDatabase(path: path))
        let group = "iMessage;+;group"
        let shallow = LoadRequest(openIDs: [alex, group], historyLimits: [:], defaultHistoryLimit: 1)
        let first = try XCTUnwrap(try reader.loadSync(shallow, unlessUnchangedFrom: nil))
        XCTAssertEqual(first.conversations.first { $0.id == alex }?.messages.map(\.text), ["Third"])
        XCTAssertNil(try reader.loadSync(shallow, unlessUnchangedFrom: first.token))
        let deeper = LoadRequest(openIDs: [alex, group], historyLimits: [alex: 3], defaultHistoryLimit: 1)
        let second = try XCTUnwrap(try reader.loadSync(deeper, unlessUnchangedFrom: first.token), "more history was asked for")
        XCTAssertEqual(second.conversations.first { $0.id == alex }?.messages.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(second.conversations.first { $0.id == group }?.messages.count, 1, "the other tile keeps its own depth")
        XCTAssertEqual(second.token, first.token, "the database itself did not change")
    }

    /// When the file at the path is replaced (Messages rebuilt it, access was granted), the reader
    /// reopens: tokens from the old connection no longer count as seen.
    func testReaderReopensWhenTheDatabaseFileIsReplaced() throws {
        let reader = MessagesReader(database: MessagesDatabase(path: path))
        let request = LoadRequest(openIDs: [alex])
        let first = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: nil))
        XCTAssertEqual(first.conversations.first { $0.id == alex }?.messages.count, 2)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let schema = """
        CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
          is_delivered INTEGER, is_read INTEGER, error INTEGER, cache_has_attachments INTEGER, associated_message_type INTEGER, item_type INTEGER);
        INSERT INTO handle VALUES ('alex@example.test');
        INSERT INTO chat VALUES ('\(alex)', 'Rebuilt', 'alex@example.test', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1);
        INSERT INTO message VALUES ('Only one now',NULL,700000009000000000,0,1,0,0,0,0,0,0);
        INSERT INTO chat_message_join VALUES (1,1);
        """
        execute(schema)
        let second = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: first.token), "a new file is a change")
        XCTAssertNotEqual(second.token.connection, first.token.connection)
        XCTAssertEqual(second.conversations.first { $0.id == alex }?.name, "Rebuilt")
        XCTAssertEqual(second.conversations.first { $0.id == alex }?.messages.map(\.text), ["Only one now"])
        XCTAssertNil(try reader.loadSync(request, unlessUnchangedFrom: second.token))
    }

    /// Databases with Messages' newer columns: reactions are kept apart from the history page and
    /// attached to their targets; replies, edits and unsends are read; old databases without the
    /// columns (the fixture above) still load.
    func testReactionsRepliesEditsAndUnsendsAreReadFromNewerSchemas() throws {
        let modern = directory.appendingPathComponent("modern.db").path
        execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
          is_delivered INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, error INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0,
          associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT, item_type INTEGER DEFAULT 0,
          thread_originator_guid TEXT, thread_originator_part TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
        INSERT INTO handle VALUES ('alex@example.test');
        INSERT INTO chat VALUES ('\(alex)', '', 'alex@example.test', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('G1', 'Lunch?', 700000001000000000, 0, 1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id, associated_message_type, associated_message_guid) VALUES ('R1', 'Loved “Lunch?”', 700000002000000000, 1, 0, 2000, 'p:0/G1');
        INSERT INTO message (guid, text, date, is_from_me, handle_id, thread_originator_guid, thread_originator_part) VALUES ('G2', 'Yes, at one', 700000003000000000, 1, 0, 'G1', '0:0:0');
        INSERT INTO message (guid, text, date, is_from_me, handle_id, associated_message_type, associated_message_guid) VALUES ('R2', 'Removed a heart from “Lunch?”', 700000004000000000, 1, 0, 3000, 'p:0/G1');
        INSERT INTO message (guid, text, date, is_from_me, handle_id, associated_message_type, associated_message_guid) VALUES ('R3', '🔥', 700000005000000000, 0, 1, 2006, 'bp:G2');
        INSERT INTO message (guid, text, date, is_from_me, handle_id, date_edited) VALUES ('G3', 'Make it two', 700000006000000000, 0, 1, 700000007000000000);
        INSERT INTO message (guid, text, date, is_from_me, handle_id, date_retracted) VALUES ('G4', NULL, 700000008000000000, 1, 0, 700000009000000000);
        INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(1,5),(1,6),(1,7);
        """, at: modern)
        let reader = MessagesReader(database: MessagesDatabase(path: modern))
        let snapshot = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: [alex], defaultHistoryLimit: 4), unlessUnchangedFrom: nil))
        let chat = try XCTUnwrap(snapshot.conversations.first { $0.id == alex })
        XCTAssertEqual(chat.messages.map(\.guid), ["G1", "G2", "G3", "G4"], "four messages fill a page of four; the three reaction rows take no place in it")
        XCTAssertEqual(chat.messages.map(\.kind), [.message, .message, .message, .message])
        let reply = chat.messages[1]
        XCTAssertEqual(reply.replyToGUID, "G1")
        XCTAssertEqual(reply.replyToPart, 0)
        XCTAssertTrue(chat.messages[2].isEdited)
        XCTAssertFalse(chat.messages[2].isUnsent)
        XCTAssertTrue(chat.messages[3].isUnsent)
        XCTAssertEqual(chat.messages[3].text, "", "an unsent message carries no fallback text")
        XCTAssertEqual(chat.reactions.map(\.id), ["2", "4", "5"])
        XCTAssertEqual(chat.reactions[0].targetGUID, "G1"); XCTAssertEqual(chat.reactions[0].targetPart, 0)
        XCTAssertEqual(chat.reactions[0].kind, .love); XCTAssertFalse(chat.reactions[0].isRemoval); XCTAssertTrue(chat.reactions[0].isFromMe)
        XCTAssertEqual(chat.reactions[1].kind, .love); XCTAssertTrue(chat.reactions[1].isRemoval)
        XCTAssertEqual(chat.reactions[2].targetGUID, "G2"); XCTAssertNil(chat.reactions[2].targetPart)
        XCTAssertEqual(chat.reactions[2].kind, .emoji("🔥")); XCTAssertEqual(chat.reactions[2].actor, "alex@example.test")
        // Reaction references in every form Messages writes.
        XCTAssertEqual(ReactionEvent.target(from: "p:2/ABC")?.guid, "ABC"); XCTAssertEqual(ReactionEvent.target(from: "p:2/ABC")?.part, 2)
        XCTAssertEqual(ReactionEvent.target(from: "bp:ABC")?.guid, "ABC"); XCTAssertNil(ReactionEvent.target(from: "bp:ABC")?.part)
        XCTAssertEqual(ReactionEvent.target(from: "ABC")?.guid, "ABC")
        XCTAssertNil(ReactionEvent.target(from: "p:0/")); XCTAssertNil(ReactionEvent.target(from: ""))
        XCTAssertTrue(ReactionEvent.isReaction(type: 2005)); XCTAssertFalse(ReactionEvent.isReaction(type: 1000))
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
