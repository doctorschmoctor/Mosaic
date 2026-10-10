import XCTest
import CSQLite
import Contacts
import MosaicCore
@testable import Mosaic

/// The suite is a fixture run: it never reads the Mac's Contacts or asks for a permission, never
/// reads the signed-in Messages database, keeps outgoing files in a temporary folder of its own
/// (so its cleanup cannot remove a file the installed app's drafts point at), and cannot send.
final class IsolationTests: XCTestCase {
    static let alex = "iMessage;-;alex@example.test"
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "MosaicIsolationTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A Messages-shaped database with one fictional conversation.
    private func makeDatabase() throws -> String {
        let path = directory.appending(path: "chat-\(UUID().uuidString).db").path
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
    private func defaults() -> UserDefaults {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
    /// Waits (a bounded time) for a condition the store reaches asynchronously.
    @MainActor private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor func testTheSuiteIsAFixtureRunWithItsOwnFolders() {
        XCTAssertTrue(MosaicRuntime.isIsolated)
        XCTAssertNotEqual(OutgoingStorage.processDefault, .system, "never the installed app's outgoing folders")
        XCTAssertTrue(OutgoingFiles.pendingDirectory.path.hasPrefix(MosaicRuntime.isolatedRoot.path))
        XCTAssertTrue(OutgoingFiles.stagingDirectory.path.hasPrefix(MosaicRuntime.isolatedRoot.path))
        XCTAssertTrue(StoreServices.processDefault.contacts is FixtureContacts, "never the Mac's Contacts")
        XCTAssertFalse(OutgoingStorage.isolated.owns(OutgoingStorage.system.pending.appending(path: "Image.png")))
        XCTAssertTrue(OutgoingStorage.isolated.owns(OutgoingStorage.isolated.pending.appending(path: "Image.png")))
        XCTAssertFalse(OutgoingStorage.isolated.owns(OutgoingStorage.isolated.pending), "the folder itself is not a file it wrote")
    }

    /// Left to its defaults, a live store in a fixture run reads no Messages database it was not
    /// given (so it finds none) and has nothing to send through.
    @MainActor func testADefaultLiveStoreReadsNoRealDatabaseAndCannotSend() async throws {
        let store = WorkspaceStore(defaults: defaults())
        XCTAssertTrue(store.isLive)
        XCTAssertTrue(store.transport is UnavailableTransport)
        try await eventually { !store.isLoadingConversations }
        XCTAssertNotNil(store.connectionError, "the signed-in Messages database is never read")
        XCTAssertTrue(store.conversations.isEmpty)
    }

    /// Given a synthetic database and no transport, a send is refused by the fixture transport:
    /// nothing reaches Messages, and the message waits for the reader as any refused one does.
    @MainActor func testAFixtureRunRefusesToSend() async throws {
        let store = WorkspaceStore(defaults: defaults(), database: MessagesDatabase(path: try makeDatabase()))
        try await eventually { store.openIDs.contains(Self.alex) && store.canSend }
        store.workspace.drafts[Self.alex] = "Never sent"
        await store.send(Self.alex)
        XCTAssertEqual((store.transport as? UnavailableTransport)?.refusals, 1)
        XCTAssertEqual(store.conversations.first?.messages.last?.sendState, .failed("Sending is off in this run."))
    }

    /// Names come only from the store's contacts source, which is read once and never asked for
    /// access at launch.
    @MainActor func testContactNamesComeOnlyFromTheInjectedSource() async throws {
        let contacts = FixtureContacts(status: .authorized, entries: [ContactNames.Entry(id: "c1", name: "Alex Example", addresses: ["alex@example.test"])])
        let store = WorkspaceStore(defaults: defaults(), database: MessagesDatabase(path: try makeDatabase()),
                                   transport: RecordingTransport(), services: .isolated(contacts: contacts))
        try await eventually { store.conversations.first?.name == "Alex Example" }
        XCTAssertEqual(store.conversations.first?.name, "Alex Example")
        XCTAssertEqual(store.contactAuthorization, .authorized)
        XCTAssertEqual(contacts.entryReads, 1)
        XCTAssertEqual(contacts.accessRequests, 0, "launch never asks for access")
    }

    /// Contacts that were never allowed, or were denied, are neither read nor asked about at launch.
    @MainActor func testUndecidedOrDeniedContactsAreLeftAloneAtLaunch() async throws {
        for status in [CNAuthorizationStatus.notDetermined, .denied, .restricted] {
            let contacts = FixtureContacts(status: status, entries: [ContactNames.Entry(id: "c1", name: "Alex Example", addresses: ["alex@example.test"])])
            let store = WorkspaceStore(defaults: defaults(), database: MessagesDatabase(path: try makeDatabase()),
                                       transport: RecordingTransport(), services: .isolated(contacts: contacts))
            try await eventually { !store.conversations.isEmpty && store.contactAuthorization == status }
            XCTAssertEqual(store.contactAuthorization, status)
            XCTAssertEqual(contacts.accessRequests, 0, "\(status.rawValue): no prompt at launch")
            XCTAssertEqual(contacts.entryReads, 0, "\(status.rawValue): nothing read")
            XCTAssertEqual(store.conversations.first?.name, "alex@example.test")
        }
    }

    /// A contacts source that is slow or fails holds up nothing: the list and the open tile's
    /// history load as usual.
    @MainActor func testASlowOrFailingContactsSourceNeverHoldsUpHistory() async throws {
        let slow = FixtureContacts(status: .authorized, delay: .seconds(60))
        let store = WorkspaceStore(defaults: defaults(), database: MessagesDatabase(path: try makeDatabase()),
                                   transport: RecordingTransport(), services: .isolated(contacts: slow))
        try await eventually { store.conversations.first?.messages.count == 2 }
        XCTAssertEqual(store.conversations.first?.messages.map(\.text), ["Hello", "Hi!"])
        XCTAssertTrue(store.isLoadingContacts, "the names are still on their way")

        let failing = FixtureContacts(status: .authorized, failure: "Contacts is unavailable")
        let other = WorkspaceStore(defaults: defaults(), database: MessagesDatabase(path: try makeDatabase()),
                                   transport: RecordingTransport(), services: .isolated(contacts: failing))
        try await eventually { other.conversations.first?.messages.count == 2 && other.contactStatus != nil }
        XCTAssertEqual(other.conversations.first?.messages.count, 2)
        XCTAssertEqual(other.contactStatus, "Contact sync failed: Contacts is unavailable")
    }

    /// Launch cleanup removes stale files from the store's own folder only; a folder that stands
    /// in for the installed app's is never touched.
    @MainActor func testLaunchCleanupStaysInTheStoresOwnFolder() async throws {
        let own = OutgoingStorage(root: directory.appending(path: "own"))
        let installed = OutgoingStorage(root: directory.appending(path: "installed"))
        let old = Date().addingTimeInterval(-10 * 86400)
        var stale: [URL] = []
        for storage in [own, installed] {
            try FileManager.default.createDirectory(at: storage.pending, withIntermediateDirectories: true)
            let file = storage.pending.appending(path: "Image old.png")
            try Data([1, 2, 3]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            stale.append(file)
        }
        _ = WorkspaceStore(defaults: defaults(), forceDemo: true, services: .isolated(outgoing: own))
        try await eventually { !FileManager.default.fileExists(atPath: stale[0].path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale[0].path), "the store's own stale file goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale[1].path), "another folder is never cleaned")
    }
}
