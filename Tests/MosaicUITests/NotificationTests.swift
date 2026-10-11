import XCTest
import CSQLite
import MosaicCore
@testable import Mosaic

/// Mosaic's own notifications (opt-in), through the real store with a synthetic database and a
/// recording notifier — nothing is shown and no permission is asked of the system. A new incoming
/// message notifies once; the first load, unchanged refreshes, reactions, your own messages, muted
/// conversations and a conversation you can see never do; clicking opens the conversation.
final class NotificationTests: XCTestCase {
    static let alex = "iMessage;-;alex@example.test"
    static let crew = "iMessage;+;chat-crew"
    var directory: URL!
    var path: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "MosaicNotifyTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appending(path: "chat.db").path
        try sql("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
          is_delivered INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, error INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0,
          associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT, item_type INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
        INSERT INTO handle VALUES ('alex@example.test'), ('sam@example.test');
        INSERT INTO chat VALUES ('\(Self.alex)', '', 'alex@example.test', 'iMessage'), ('\(Self.crew)', 'Weekend crew', 'chat-crew', 'iMessage');
        INSERT INTO chat_handle_join VALUES (1,1),(2,1),(2,2);
        INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('G1', 'Hello', 700000001000000000, 0, 1), ('G2', 'Hi all', 700000002000000000, 0, 2);
        INSERT INTO chat_message_join VALUES (1,1),(2,2);
        """)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func sql(_ statement: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    private var date: Int64 { Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) }
    /// A message arrives in a chat (chat 1 is Alex's, 2 the group), from a handle (1 Alex, 2 Sam), or from you.
    private func arrive(_ text: String, chat: Int, from handle: Int, fromMe: Bool = false, reaction: Bool = false) throws {
        let association = reaction ? ", associated_message_type, associated_message_guid" : ""
        let values = reaction ? ", 2000, 'p:0/G1'" : ""
        try sql("""
        INSERT INTO message (guid, text, date, is_from_me, handle_id\(association)) VALUES ('\(UUID().uuidString)', '\(text)', \(date), \(fromMe ? 1 : 0), \(fromMe ? 0 : handle)\(values));
        INSERT INTO chat_message_join VALUES (\(chat), last_insert_rowid());
        """)
    }

    @MainActor private func liveStore() async throws -> (WorkspaceStore, RecordingNotifier) {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let notifier = RecordingNotifier()
        notifier.granted = .allowed
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: name)!, database: MessagesDatabase(path: path),
                                   transport: RecordingTransport(), services: .isolated(notifier: { notifier }))
        for _ in 0..<200 where store.conversations.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.conversations.count, 2)
        // Nothing open: every conversation is one the reader can't see.
        for id in store.openIDs { store.close(id) }
        await store.setNotificationsEnabled(true)
        XCTAssertTrue(store.notificationsEnabled)
        return (store, notifier)
    }
    @MainActor private func settle(_ store: WorkspaceStore) async throws {
        await store.refresh()
        try await Task.sleep(for: .milliseconds(250))
    }

    @MainActor func testNotificationsAreOffUntilTurnedOnAndAskOnce() async throws {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let notifier = RecordingNotifier()
        let defaults = UserDefaults(suiteName: name)!
        let store = WorkspaceStore(defaults: defaults, forceDemo: true, services: .isolated(notifier: { notifier }))
        XCTAssertFalse(store.notificationsEnabled, "off until the reader turns them on")
        XCTAssertEqual(notifier.permissionRequests, 0, "nothing is asked at launch")
        notifier.grants = false
        await store.setNotificationsEnabled(true)
        XCTAssertFalse(store.notificationsEnabled, "declined: they stay off")
        XCTAssertEqual(store.notificationPermission, .denied)
        notifier.grants = true
        notifier.granted = .notDetermined
        await store.setNotificationsEnabled(true)
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertEqual(notifier.permissionRequests, 2)
        await store.setNotificationsEnabled(true)
        XCTAssertEqual(notifier.permissionRequests, 2, "allowed already: not asked again")
        store.notificationPreview = .nameOnly
        let again = WorkspaceStore(defaults: defaults, forceDemo: true, services: .isolated(notifier: { RecordingNotifier() }))
        XCTAssertTrue(again.notificationsEnabled, "kept across a relaunch")
        XCTAssertEqual(again.notificationPreview, .nameOnly)
    }

    @MainActor func testANewMessageNotifiesOnceAndOnlyANewIncomingOne() async throws {
        let (store, notifier) = try await liveStore()
        try await settle(store)
        XCTAssertTrue(notifier.posted.isEmpty, "the first load notifies nothing")

        try arrive("Are you around?", chat: 1, from: 1)
        try await settle(store)
        XCTAssertEqual(notifier.posted.count, 1)
        let first = try XCTUnwrap(notifier.posted.first)
        XCTAssertEqual(first.conversationID, Self.alex)
        XCTAssertEqual(first.body, "Are you around?")
        try await settle(store)
        XCTAssertEqual(notifier.posted.count, 1, "a refresh with nothing new notifies nothing")

        try arrive("Loved it", chat: 1, from: 1, reaction: true)
        try arrive("On my way", chat: 1, from: 0, fromMe: true)
        try await settle(store)
        XCTAssertEqual(notifier.posted.count, 1, "reactions and your own messages never notify")

        // A group says who wrote.
        try arrive("Cabin booked", chat: 2, from: 2)
        try await settle(store)
        XCTAssertEqual(notifier.posted.last?.conversationID, Self.crew)
        XCTAssertEqual(notifier.posted.last?.title, "Weekend crew")
        XCTAssertTrue(notifier.posted.last?.body.hasSuffix(": Cabin booked") == true)

        // Name only.
        store.notificationPreview = .nameOnly
        try arrive("Secret plans", chat: 1, from: 1)
        try await settle(store)
        XCTAssertEqual(notifier.posted.last?.body, "New message")
        XCTAssertFalse(notifier.posted.contains { $0.body.contains("Secret") })
    }

    @MainActor func testMutedAndVisibleConversationsDoNotNotify() async throws {
        let (store, notifier) = try await liveStore()
        try await settle(store)
        store.mute(Self.alex, .hour)
        XCTAssertTrue(store.isMuted(Self.alex))
        try arrive("Muted?", chat: 1, from: 1)
        try await settle(store)
        XCTAssertTrue(notifier.posted.isEmpty, "a muted conversation is quiet")
        XCTAssertEqual(store.mutedConversations.map(\.id), [Self.alex])
        store.unmute(Self.alex)

        // Open and in view: the reader can see it.
        store.open(Self.alex)
        store.setAppActive(true)
        XCTAssertTrue(store.canSee(Self.alex))
        try arrive("You can see this", chat: 1, from: 1)
        try await settle(store)
        XCTAssertTrue(notifier.posted.isEmpty, "a conversation in view never notifies")

        // Muting until tomorrow ends at 8 the next morning.
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        store.mute(Self.crew, .untilTomorrow, now: now)
        let until = try XCTUnwrap(store.mutedUntil[Self.crew])
        XCTAssertEqual(Calendar.current.component(.hour, from: until), 8)
        XCTAssertGreaterThan(until, now)
    }

    @MainActor func testClickingANotificationOpensItsConversation() async throws {
        let (store, notifier) = try await liveStore()
        try await settle(store)
        try arrive("Open me", chat: 2, from: 2)
        try await settle(store)
        let notification = try XCTUnwrap(notifier.posted.last)
        XCTAssertFalse(store.openIDs.contains(Self.crew))
        notifier.click(notification)
        XCTAssertTrue(store.openIDs.contains(Self.crew), "opened in a tile")
        XCTAssertEqual(store.focusTarget, Self.crew, "with the keyboard in its message field")
        // Reading it takes its notification away.
        store.markSeen(Self.crew)
        XCTAssertTrue(notifier.withdrawn.contains(Self.crew))
    }
}
