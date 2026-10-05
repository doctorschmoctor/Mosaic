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

    /// A group's photo is the file of its latest photo change; a later change without a file
    /// (the photo was removed) leaves it without one. One-to-one chats have none.
    func testGroupPhotoComesFromTheLatestPhotoChange() throws {
        let photo = directory.appendingPathComponent("group-photo.jpeg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: photo)
        execute("""
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, transfer_name TEXT,
          is_sticker INTEGER DEFAULT 0, hide_attachment INTEGER DEFAULT 0, total_bytes INTEGER DEFAULT 0);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO message VALUES (NULL,NULL,700000003000000000,1,0,0,0,0,1,0,3,0);
        INSERT INTO chat_message_join VALUES (2, 4);
        INSERT INTO attachment (guid, filename, mime_type) VALUES ('P1', '\(photo.path)', 'image/jpeg');
        INSERT INTO message_attachment_join VALUES (4, 1);
        """)
        let reader = MessagesReader(database: MessagesDatabase(path: path))
        let first = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: []), unlessUnchangedFrom: nil))
        XCTAssertEqual(first.conversations.first { $0.id == "iMessage;+;group" }?.photoPath, photo.path)
        XCTAssertNil(first.conversations.first { $0.id == alex }?.photoPath)
        execute("INSERT INTO message VALUES (NULL,NULL,700000004000000000,1,0,0,0,0,0,0,3,0); INSERT INTO chat_message_join VALUES (2, 5);")
        let removed = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: []), unlessUnchangedFrom: first.token))
        XCTAssertNil(removed.conversations.first { $0.id == "iMessage;+;group" }?.photoPath, "the photo was removed")
    }

    /// A load reads members only for the chats it lists or has open, attachments only for its
    /// pages' own messages (by ID), and compiles its fixed statements once per connection: a later
    /// load prepares only the variable-length lookups, and an unchanged poll prepares nothing.
    func testLoadsReadOnlyTheirOwnRowsAndReuseStatements() throws {
        execute("""
        CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, transfer_name TEXT,
          is_sticker INTEGER DEFAULT 0, hide_attachment INTEGER DEFAULT 0, total_bytes INTEGER DEFAULT 0);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO attachment (guid, filename, mime_type, transfer_name)
          VALUES ('A1', '/nonexistent/one.pdf', 'application/pdf', 'one.pdf'), ('A2', '/nonexistent/two.pdf', 'application/pdf', 'two.pdf');
        INSERT INTO message_attachment_join VALUES (3, 1), (2, 2);
        """)
        let reader = MessagesReader(database: MessagesDatabase(path: path))
        // Only the most recent chat (the group, two members) is listed; nothing is open.
        _ = try reader.loadSync(LoadRequest(openIDs: [], limit: 1), unlessUnchangedFrom: nil)
        XCTAssertEqual(reader.lastMemberRowCount, 2)

        let request = LoadRequest(openIDs: [alex, "iMessage;+;group"])
        let first = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: nil))
        XCTAssertEqual(reader.lastMemberRowCount, 3)
        let group = try XCTUnwrap(first.conversations.first { $0.id == "iMessage;+;group" })
        XCTAssertEqual(group.messages.first?.attachments.map(\.name), ["one.pdf"])
        let alexThread = try XCTUnwrap(first.conversations.first { $0.id == alex })
        XCTAssertEqual(alexThread.messages.flatMap(\.attachments).map(\.name), ["two.pdf"], "each file belongs to its own message")

        let afterFirst = reader.preparedStatementCount
        XCTAssertNil(try reader.loadSync(request, unlessUnchangedFrom: first.token))
        XCTAssertEqual(reader.preparedStatementCount, afterFirst, "an unchanged poll reuses its statement")
        execute("UPDATE message SET is_read = 1 WHERE ROWID = 2")
        let second = try XCTUnwrap(try reader.loadSync(request, unlessUnchangedFrom: first.token))
        XCTAssertTrue(second.conversations.first { $0.id == alex }?.messages.last?.isRead ?? false)
        // Members (one list) and attachments (one list per open chat) are the only new statements.
        XCTAssertEqual(reader.preparedStatementCount - afterFirst, 3)
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

    /// A newer-schema database for the reply, unsend and unread cases below.
    private func makeModern(_ rows: String) -> String {
        let modern = directory.appendingPathComponent("modern-\(UUID().uuidString).db").path
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
        INSERT INTO handle VALUES ('alex@example.test'), ('jamie@example.test');
        INSERT INTO chat VALUES ('\(alex)', '', 'alex@example.test', 'iMessage'), ('iMessage;-;jamie@example.test', '', 'jamie@example.test', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1),(2,2);
        \(rows)
        """, at: modern)
        return modern
    }

    /// A reply whose original is above the loaded page brings the original's text along (and only
    /// from its own chat); an unsent message keeps its place but loses its words everywhere.
    func testRepliesBringTheirOriginalAndUnsentMessagesShowNothing() throws {
        let modern = makeModern("""
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('OLD', 'Way back when', 700000001000000000, 0, 1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('J1', 'Jamie elsewhere', 700000001500000000, 0, 2);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('M1', 'Filler', 700000002000000000, 1, 0);
        INSERT INTO message (guid, text, date, is_from_me, handle_id, thread_originator_guid) VALUES ('R1', 'About that', 700000003000000000, 1, 0, 'OLD');
        INSERT INTO message (guid, text, date, is_from_me, handle_id, thread_originator_guid) VALUES ('R2', 'And that', 700000004000000000, 1, 0, 'J1');
        INSERT INTO message (guid, text, date, is_from_me, handle_id, date_retracted) VALUES ('U1', 'secret words', 700000005000000000, 0, 1, 700000006000000000);
        INSERT INTO chat_message_join VALUES (1,1),(2,2),(1,3),(1,4),(1,5),(1,6);
        """)
        let reader = MessagesReader(database: MessagesDatabase(path: modern))
        let snapshot = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: [alex], defaultHistoryLimit: 4), unlessUnchangedFrom: nil))
        let chat = try XCTUnwrap(snapshot.conversations.first { $0.id == alex })
        XCTAssertEqual(chat.messages.map(\.guid), ["M1", "R1", "R2", "U1"])
        XCTAssertEqual(chat.referencedMessages["OLD"]?.text, "Way back when", "the original above the page comes along")
        XCTAssertNil(chat.referencedMessages["J1"], "a GUID from another chat is never shown here")
        let unsent = try XCTUnwrap(chat.messages.last)
        XCTAssertTrue(unsent.isUnsent)
        XCTAssertEqual(unsent.text, "", "an unsent message's words are not kept")
        XCTAssertEqual(chat.preview, "Unsent message", "nor shown in the sidebar")
        XCTAssertEqual(chat.lastMessageID, 6)
    }

    /// Unread counts come from the seen boundary: every incoming message after it counts — the
    /// same text five times is five — and sent messages, reactions and activity do not.
    func testUnreadCountsFromTheSeenBoundary() throws {
        let modern = makeModern("""
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('A', 'Seen', 700000001000000000, 0, 1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('B', 'ok', 700000002000000000, 0, 1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('C', 'ok', 700000003000000000, 0, 1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('D', 'ok', 700000004000000000, 0, 1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('E', 'mine', 700000005000000000, 1, 0);
        INSERT INTO message (guid, text, date, is_from_me, handle_id, associated_message_type, associated_message_guid) VALUES ('F', 'Loved', 700000006000000000, 0, 1, 2000, 'p:0/E');
        INSERT INTO message (guid, text, date, is_from_me, handle_id, item_type) VALUES ('G', '', 700000007000000000, 0, 1, 1);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('H', 'ok', 700000008000000000, 0, 1);
        INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(1,5),(1,6),(1,7),(1,8);
        """)
        let reader = MessagesReader(database: MessagesDatabase(path: modern))
        let unseen = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: [], seenBoundaries: [alex: 1]), unlessUnchangedFrom: nil))
        XCTAssertEqual(unseen.conversations.first { $0.id == alex }?.unreadCount, 4, "three identical texts and one more: four")
        let seen = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: [], seenBoundaries: [alex: 8]), unlessUnchangedFrom: nil))
        XCTAssertEqual(seen.conversations.first { $0.id == alex }?.unreadCount, 0)
        let none = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: []), unlessUnchangedFrom: nil))
        XCTAssertEqual(none.conversations.first { $0.id == alex }?.unreadCount, 0, "no boundary, nothing counted")
        XCTAssertEqual(LoadRequest(openIDs: [], seenBoundaries: [alex: 1]), LoadRequest(openIDs: []), "boundaries alone do not make a different load")
    }

    /// Earlier pages follow a (date, row) cursor: paged back two at a time, a history whose
    /// messages share moments comes back whole, in order, each message once. A cursor whose row
    /// was deleted places the page by its time.
    func testEarlierPagesFollowAStableCursorWithoutRepeatsOrGaps() throws {
        let base: Int64 = 710_000_000_000_000_000
        let dates = [0, 1, 1, 1, 2, 3, 3].map { base + Int64($0) * 1_000_000_000 }
        var sql = ""
        for (n, date) in dates.enumerated() {
            sql += "INSERT INTO message VALUES ('m\(n)',NULL,\(date),0,1,0,0,0,0,0,0,0); INSERT INTO chat_message_join VALUES (1, last_insert_rowid());"
        }
        execute(sql)
        let reader = MessagesReader(database: MessagesDatabase(path: path))
        let all = try XCTUnwrap(try reader.pageSync(forChat: alex, limit: 100)).messages.map(\.text)
        XCTAssertEqual(all, ["First", "Second", "m0", "m1", "m2", "m3", "m4", "m5", "m6"])
        var shown = try XCTUnwrap(try reader.pageSync(forChat: alex, limit: 2)).messages
        XCTAssertEqual(shown.map(\.text), ["m5", "m6"])
        for _ in 0..<10 {
            let oldest = shown[0]
            let page = try XCTUnwrap(try reader.earlierPageSync(forChat: alex, before: try XCTUnwrap(Int64(oldest.id)), date: oldest.date, limit: 2))
            shown = page.messages + shown
            if page.messages.count < 2 { break }
        }
        XCTAssertEqual(shown.map(\.text), all)
        XCTAssertEqual(Set(shown.map(\.id)).count, shown.count)
        let m3 = try XCTUnwrap(shown.first { $0.text == "m3" })
        execute("DELETE FROM chat_message_join WHERE message_id = \(m3.id); DELETE FROM message WHERE ROWID = \(m3.id);")
        let placed = try XCTUnwrap(try reader.earlierPageSync(forChat: alex, before: try XCTUnwrap(Int64(m3.id)), date: m3.date, limit: 10))
        XCTAssertEqual(placed.messages.map(\.text), ["First", "Second", "m0", "m1", "m2"])
        XCTAssertNil(try reader.earlierPageSync(forChat: "iMessage;-;nobody@example.test", before: 1, date: m3.date))
    }

    /// One conversation's page on its own, for a tile that just opened; unknown conversations have none.
    func testASingleConversationPageLoadsOnItsOwn() throws {
        let reader = MessagesReader(database: MessagesDatabase(path: path))
        let page = try XCTUnwrap(try reader.pageSync(forChat: alex, limit: 1))
        XCTAssertEqual(page.messages.map(\.text), ["Second"])
        XCTAssertNil(try reader.pageSync(forChat: "iMessage;-;nobody@example.test"))
        // The full load's change detection is untouched by it.
        let full = try XCTUnwrap(try reader.loadSync(LoadRequest(openIDs: [alex]), unlessUnchangedFrom: nil))
        _ = try reader.pageSync(forChat: alex)
        XCTAssertNil(try reader.loadSync(LoadRequest(openIDs: [alex]), unlessUnchangedFrom: full.token))
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
