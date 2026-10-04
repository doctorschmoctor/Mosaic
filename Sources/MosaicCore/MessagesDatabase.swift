import Foundation
import CSQLite
import ImageIO

public enum DatabaseError: LocalizedError {
    case accessDenied, sqlite(String), unsupportedSchema
    public var errorDescription: String? {
        switch self {
        case .accessDenied: return "Mosaic cannot read Messages yet. Add Mosaic.app in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Mosaic."
        case .sqlite(let reason): return "Messages could not be read: \(reason)"
        case .unsupportedSchema: return "This Messages database uses an unsupported format. Open Messages and try again, or use demo mode."
        }
    }
}

/// Where the database is. Reading goes through a `MessagesReader`, which keeps one connection open.
public struct MessagesDatabase: Sendable {
    public let path: String
    /// Messages stores attachment paths relative to the user's home ("~/Library/Messages/Attachments/…").
    public let home: URL
    public init(path: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.path = path
        self.home = home
    }
    /// Files whose changes mean the database content changed (the write-ahead log is where new
    /// messages land first).
    public var watchedPaths: [String] { [path, path + "-wal"] }

    /// A one-off load with a reader of its own (tests, tools).
    public func load(openIDs: Set<String>, limit: Int = 500, historyLimit: Int = 100) throws -> [Conversation] {
        let request = LoadRequest(openIDs: openIDs, limit: limit, historyLimits: [:], defaultHistoryLimit: historyLimit)
        return try MessagesReader(database: self).loadSync(request, unlessUnchangedFrom: nil)!.conversations
    }

    public static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 10_000_000_000 || raw < -10_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
    static func resolve(_ raw: String?, home: URL) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value == "~" { return home.path }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))).path }
        return value
    }
}

/// What a load should cover: which conversations get a history, and how deep each one goes.
public struct LoadRequest: Equatable, Sendable {
    public var openIDs: Set<String>
    /// How many recent conversations the sidebar lists.
    public var limit: Int
    /// History depth per conversation; `defaultHistoryLimit` for the rest. One tile asking for
    /// more history never deepens the others.
    public var historyLimits: [String: Int]
    public var defaultHistoryLimit: Int
    public init(openIDs: Set<String>, limit: Int = 500, historyLimits: [String: Int] = [:], defaultHistoryLimit: Int = 100) {
        self.openIDs = openIDs; self.limit = limit; self.historyLimits = historyLimits; self.defaultHistoryLimit = defaultHistoryLimit
    }
    public func historyLimit(for id: String) -> Int { historyLimits[id] ?? defaultHistoryLimit }
}

/// Marks the state of the database a load saw: SQLite's `data_version` on the reader's own
/// connection, which changes whenever another connection commits, plus which connection it came
/// from. Equal tokens from the same reader mean nothing was committed in between.
public struct ChangeToken: Equatable, Sendable {
    public let version: Int64
    public let connection: Int
}

/// The result of a load: the conversations and the state they correspond to.
public struct DatabaseSnapshot: Sendable {
    public let conversations: [Conversation]
    public let token: ChangeToken
}

/// One read-only connection to Messages' database, kept open and used from one serial queue.
///
/// Change detection is SQLite's `PRAGMA data_version`, read on this same connection (it is only
/// meaningful there): it moves when any other connection commits — a new message, an old row's
/// edit or read receipt, a renamed chat, an attachment finishing its transfer — so an unchanged
/// poll costs one pragma, not aggregates over the message table. The version is read *before* a
/// load begins, so a commit that lands while the load runs is not taken as already seen. The
/// connection is reopened when the file is replaced or a read fails, which invalidates tokens
/// from the earlier connection. No read transaction is held between loads.
public final class MessagesReader: @unchecked Sendable {
    public let database: MessagesDatabase
    private let queue = DispatchQueue(label: "Mosaic.MessagesReader", qos: .userInitiated)
    private var db: OpaquePointer?
    private var connectionNumber = 0
    private var fileIdentity: UInt64?
    private var schema: Schema?

    struct Schema {
        let message: Set<String>, attachment: Set<String>, attachmentJoin: Set<String>
        func col(_ name: String, prefix: String = "m", fallback: String = "0") -> String { message.contains(name) ? "\(prefix).\(name)" : fallback }
    }

    public init(database: MessagesDatabase) { self.database = database }
    deinit { if let db { sqlite3_close(db) } }

    /// Loads what the request asks for, or returns nil when the database has not changed since the
    /// load that produced `known` and the request is the same as that load's.
    public func load(_ request: LoadRequest, unlessUnchangedFrom known: ChangeToken?) async throws -> DatabaseSnapshot? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.perform(request, unlessUnchangedFrom: known)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// The same load, waited for (tests and one-off tools).
    public func loadSync(_ request: LoadRequest, unlessUnchangedFrom known: ChangeToken?) throws -> DatabaseSnapshot? {
        try queue.sync { try self.perform(request, unlessUnchangedFrom: known) }
    }
    /// The current token without loading anything (a cheap "has anything changed?" probe).
    public func currentToken() throws -> ChangeToken {
        try queue.sync {
            let db = try self.openIfNeeded()
            return ChangeToken(version: try self.dataVersion(db), connection: self.connectionNumber)
        }
    }

    private var lastRequest: LoadRequest?

    /// The load itself, on the reader's queue.
    private func perform(_ request: LoadRequest, unlessUnchangedFrom known: ChangeToken?) throws -> DatabaseSnapshot? {
        do {
            let db = try openIfNeeded()
            // Read before the load: a commit that lands during the load moves the version past this
            // one, so the next poll loads again instead of taking the commit as seen.
            let token = ChangeToken(version: try dataVersion(db), connection: connectionNumber)
            if let known, known == token, lastRequest == request { return nil }
            let snapshot = try load(db, request: request, token: token)
            lastRequest = request
            return snapshot
        } catch let error as DatabaseError {
            // A failed read may mean the file went away or was replaced: start over next time.
            if case .sqlite = error { closeConnection() }
            throw error
        }
    }

    // MARK: Connection

    private func openIfNeeded() throws -> OpaquePointer {
        if let db {
            // The same path, but a different file (Messages rebuilt it, or access came back): reopen.
            if let identity = Self.identity(of: database.path), identity != fileIdentity { closeConnection() }
            else { return db }
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = connection else {
            if let connection { sqlite3_close(connection) }
            throw DatabaseError.accessDenied
        }
        // Messages writes to this database while it is read; wait rather than fail when it holds a lock.
        sqlite3_busy_timeout(opened, 3000)
        db = opened
        connectionNumber += 1
        fileIdentity = Self.identity(of: database.path)
        schema = nil
        lastRequest = nil
        return opened
    }
    private func closeConnection() {
        if let db { sqlite3_close(db) }
        db = nil; schema = nil; lastRequest = nil; fileIdentity = nil
    }
    private static func identity(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }
    private func dataVersion(_ db: OpaquePointer) throws -> Int64 {
        let statement = try prepare(db, "PRAGMA data_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return sqlite3_column_int64(statement, 0)
    }
    private func schema(_ db: OpaquePointer) throws -> Schema {
        if let schema { return schema }
        let message = try tableColumns(db, table: "message")
        guard message.contains("is_from_me"), message.contains("date"), message.contains("text") else { throw DatabaseError.unsupportedSchema }
        let probed = Schema(message: message, attachment: try tableColumns(db, table: "attachment"),
                            attachmentJoin: try tableColumns(db, table: "message_attachment_join"))
        schema = probed
        return probed
    }

    // MARK: Loading

    private func load(_ db: OpaquePointer, request: LoadRequest, token: ChangeToken) throws -> DatabaseSnapshot {
        // A read transaction ensures metadata and tile histories represent the same snapshot.
        try execute(db, "BEGIN DEFERRED")
        defer { try? execute(db, "ROLLBACK") }
        let schema = try schema(db)
        // One query for every conversation's members, instead of one query per conversation.
        let membersByChat = try participantsByChat(db)
        let body = schema.col("attributedBody", fallback: "NULL")
        let sql = """
        SELECT c.ROWID, c.guid, c.display_name, c.chat_identifier, c.service_name,
               m.text, \(body), m.date, m.ROWID
        FROM chat c
        LEFT JOIN message m ON m.ROWID = (SELECT MAX(message_id) FROM chat_message_join WHERE chat_id = c.ROWID)
        ORDER BY COALESCE(m.date, 0) DESC LIMIT ?
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(request.limit, 5000))))
        var conversations: [Conversation] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            let guid = string(statement, 1) ?? ""
            let members = membersByChat[rowID] ?? []
            let displayName = string(statement, 2) ?? ""
            let fallback = members.isEmpty ? (string(statement, 3) ?? "Conversation") : members.joined(separator: ", ")
            let name = displayName.isEmpty ? fallback : displayName
            let preview = BodyDecoder.decode(text: string(statement, 5), attributedBody: blob(statement, 6))
            let thread = request.openIDs.contains(guid) ? try history(db, chatID: rowID, schema: schema, limit: request.historyLimit(for: guid)) : (messages: [], reactions: [])
            conversations.append(Conversation(id: guid, databaseID: rowID, name: name, participants: members,
                service: string(statement, 4) ?? "iMessage", preview: preview.isEmpty ? "Attachment or activity" : preview,
                lastActivity: MessagesDatabase.appleDate(sqlite3_column_int64(statement, 7)), messages: thread.messages, reactions: thread.reactions))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        // Keep pinned conversations even if they fall outside the recent-conversation limit.
        for id in request.openIDs.subtracting(Set(conversations.map(\.id))) {
            let pinned = try prepare(db, "SELECT ROWID, display_name, chat_identifier, service_name FROM chat WHERE guid = ?")
            defer { sqlite3_finalize(pinned) }
            bind(pinned, 1, id)
            if sqlite3_step(pinned) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(pinned, 0)
                let members = membersByChat[rowID] ?? []
                let thread = try history(db, chatID: rowID, schema: schema, limit: request.historyLimit(for: id))
                let display = string(pinned, 1) ?? ""
                conversations.append(Conversation(id: id, databaseID: rowID,
                    name: display.isEmpty ? (members.isEmpty ? (string(pinned, 2) ?? id) : members.joined(separator: ", ")) : display,
                    participants: members, service: string(pinned, 3) ?? "iMessage", preview: thread.messages.last?.text ?? "",
                    lastActivity: thread.messages.last?.date ?? .distantPast, messages: thread.messages, reactions: thread.reactions))
            }
        }
        return DatabaseSnapshot(conversations: conversations.filter { !$0.id.isEmpty }, token: token)
    }

    /// The newest `limit` messages of a chat (oldest first) and the reactions on them. Reaction
    /// rows are not messages: they are left out of the page and loaded by their targets, so a
    /// burst of Tapbacks never pushes real messages out of view.
    private func history(_ db: OpaquePointer, chatID: Int64, schema: Schema, limit: Int) throws -> (messages: [Message], reactions: [ReactionEvent]) {
        func col(_ name: String, _ prefix: String = "m", _ fallback: String = "0") -> String { schema.col(name, prefix: prefix, fallback: fallback) }
        let hasAssociation = schema.message.contains("associated_message_type")
        let notReaction = hasAssociation ? "AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type >= 4000)" : ""
        let statement = try prepare(db, """
            SELECT m.ROWID, m.text, \(col("attributedBody", "m", "NULL")), m.date, m.is_from_me, h.id,
                   \(col("is_delivered")), \(col("is_read")), \(col("error")), \(col("cache_has_attachments")),
                   \(col("associated_message_type")), \(col("item_type")), \(col("guid", "m", "NULL")),
                   \(col("thread_originator_guid", "m", "NULL")), \(col("thread_originator_part", "m", "NULL")),
                   \(col("date_edited", "m", "NULL")), \(col("date_retracted", "m", "NULL"))
            FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = ? \(notReaction) ORDER BY m.date DESC, m.ROWID DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 1000))))
        struct Row {
            let id: Int64; let text: String; let date: Date; let isFromMe: Bool; let sender: String?
            let attachmentCount: Int; let association: Int32; let itemType: Int32
            let isDelivered: Bool; let isRead: Bool; let error: Int
            let guid: String?; let replyToGUID: String?; let replyToPart: Int?; let edited: Date?; let retracted: Date?
        }
        var rows: [Row] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let reply = ReactionEvent.target(from: string(statement, 13))
            rows.append(Row(id: sqlite3_column_int64(statement, 0),
                text: BodyDecoder.decode(text: string(statement, 1), attributedBody: blob(statement, 2)),
                date: MessagesDatabase.appleDate(sqlite3_column_int64(statement, 3)), isFromMe: sqlite3_column_int(statement, 4) != 0,
                sender: string(statement, 5), attachmentCount: Int(sqlite3_column_int(statement, 9)),
                association: sqlite3_column_int(statement, 10), itemType: sqlite3_column_int(statement, 11),
                isDelivered: sqlite3_column_int(statement, 6) != 0, isRead: sqlite3_column_int(statement, 7) != 0,
                error: Int(sqlite3_column_int(statement, 8)),
                guid: string(statement, 12), replyToGUID: reply?.guid,
                // Messages writes the part as "index:…" text; the index is what a reply points at.
                replyToPart: string(statement, 14).flatMap { Int($0.split(separator: ":").first ?? "") } ?? reply?.part,
                edited: optionalDate(statement, 15), retracted: optionalDate(statement, 16)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        let files = try attachments(db, chatID: chatID, schema: schema, from: rows.map(\.id).min(), messageIDs: Set(rows.map(\.id)))
        var messages: [Message] = []
        messages.reserveCapacity(rows.count)
        for row in rows.reversed() {
            let attached = files[row.id] ?? []
            var text = row.text
            let activity = row.itemType != 0
            if text.isEmpty && attached.isEmpty && row.retracted == nil {
                if row.attachmentCount > 0 { text = "Attachment · Open in Messages" }
                else if activity { text = "Conversation activity" }
                else { text = "Message · Open in Messages" }
            }
            messages.append(Message(id: String(row.id), text: text, date: row.date, isFromMe: row.isFromMe,
                sender: row.sender, attachmentCount: row.attachmentCount, attachments: attached,
                isDelivered: row.isDelivered, isRead: row.isRead, error: row.error,
                kind: activity ? .activity : .message, guid: row.guid, replyToGUID: row.replyToGUID, replyToPart: row.replyToPart,
                dateEdited: row.edited, dateRetracted: row.retracted))
        }
        let reactions = hasAssociation && schema.message.contains("associated_message_guid")
            ? try reactions(db, chatID: chatID, schema: schema, targets: Set(rows.compactMap(\.guid)), since: rows.last.map(\.date))
            : []
        return (messages, reactions)
    }

    /// The reaction rows of a chat that point at the loaded messages: those are at least as new
    /// as the oldest loaded message, so the scan is bounded by the page.
    private func reactions(_ db: OpaquePointer, chatID: Int64, schema: Schema, targets: Set<String>, since: Date?) throws -> [ReactionEvent] {
        guard !targets.isEmpty, let since else { return [] }
        let statement = try prepare(db, """
            SELECT m.ROWID, m.date, m.is_from_me, h.id, m.associated_message_guid, m.associated_message_type, m.text
            FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = ? AND m.associated_message_type >= 2000 AND m.associated_message_type < 4000
              AND (m.date >= ?2 OR (m.date < 10000000000 AND m.date >= ?3))
            ORDER BY m.date, m.ROWID
            """)
        defer { sqlite3_finalize(statement) }
        // Dates are nanoseconds in current databases and seconds in old ones; accept either.
        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int64(statement, 2, Int64((since.timeIntervalSinceReferenceDate * 1_000_000_000).rounded(.down)))
        sqlite3_bind_int64(statement, 3, Int64(since.timeIntervalSinceReferenceDate.rounded(.down)))
        var events: [ReactionEvent] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(statement) }
            guard let target = ReactionEvent.target(from: string(statement, 4)), targets.contains(target.guid) else { continue }
            let type = Int(sqlite3_column_int(statement, 5))
            events.append(ReactionEvent(id: String(sqlite3_column_int64(statement, 0)), date: MessagesDatabase.appleDate(sqlite3_column_int64(statement, 1)),
                isFromMe: sqlite3_column_int(statement, 2) != 0, actor: string(statement, 3), targetGUID: target.guid, targetPart: target.part,
                kind: ReactionEvent.kind(forType: type, text: string(statement, 6)), isRemoval: type >= 3000))
        }
        guard status == SQLITE_DONE else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return events
    }

    /// Attachment metadata for the loaded messages. Missing tables (older or synthetic schemas) yield no attachments.
    private func attachments(_ db: OpaquePointer, chatID: Int64, schema: Schema, from minimumID: Int64?, messageIDs: Set<Int64>) throws -> [Int64: [Attachment]] {
        guard let minimumID, !messageIDs.isEmpty else { return [:] }
        let columns = schema.attachment
        guard columns.contains("filename"), schema.attachmentJoin.contains("attachment_id") else { return [:] }
        func col(_ name: String, fallback: String = "NULL") -> String { columns.contains(name) ? "a.\(name)" : fallback }
        let statement = try prepare(db, """
            SELECT maj.message_id, a.ROWID, \(col("guid")), a.filename, \(col("mime_type")), \(col("uti")),
                   \(col("transfer_name")), \(col("is_sticker", fallback: "0")), \(col("hide_attachment", fallback: "0")), \(col("total_bytes", fallback: "0"))
            FROM chat_message_join j
            JOIN message_attachment_join maj ON maj.message_id = j.message_id
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE j.chat_id = ? AND j.message_id >= ?
            ORDER BY maj.message_id, a.ROWID
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int64(statement, 2, minimumID)
        var result: [Int64: [Attachment]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = sqlite3_column_int64(statement, 0)
            guard messageIDs.contains(messageID), sqlite3_column_int(statement, 8) == 0 else { continue }
            let rawPath = string(statement, 3)
            // Link-preview payloads are rendered from the URL itself, not shown as files.
            if let rawPath, rawPath.hasSuffix(".pluginPayloadAttachment") { continue }
            let path = MessagesDatabase.resolve(rawPath, home: database.home)
            let name = string(statement, 6) ?? rawPath.map { ($0 as NSString).lastPathComponent } ?? "Attachment"
            let bytes = sqlite3_column_int64(statement, 9)
            var attachment = Attachment(id: string(statement, 2) ?? "attachment-\(sqlite3_column_int64(statement, 1))",
                path: path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }, name: name,
                mimeType: string(statement, 4), uti: string(statement, 5), isSticker: sqlite3_column_int(statement, 7) != 0,
                byteCount: bytes > 0 ? Int(bytes) : nil)
            if attachment.kind == .image, let file = attachment.path, let size = ImageSizeProbe.shared.size(at: file) {
                attachment = Attachment(id: attachment.id, path: file, name: name, mimeType: attachment.mimeType, uti: attachment.uti,
                    isSticker: attachment.isSticker, pixelWidth: size.width, pixelHeight: size.height, byteCount: attachment.byteCount)
            }
            result[messageID, default: []].append(attachment)
        }
        return result
    }

    private func participantsByChat(_ db: OpaquePointer) throws -> [Int64: [String]] {
        let statement = try prepare(db, "SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id ORDER BY j.chat_id, h.ROWID")
        defer { sqlite3_finalize(statement) }
        var result: [Int64: [String]] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let id = string(statement, 1) { result[sqlite3_column_int64(statement, 0), default: []].append(id) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return result
    }
    private func tableColumns(_ db: OpaquePointer, table: String) throws -> Set<String> {
        let statement = try prepare(db, "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let name = string(statement, 1) { result.insert(name) } }
        return result
    }
    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }; return statement
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }; return String(cString: value)
    }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let value = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, index)))
    }
    /// A date column that may be absent, NULL or zero (Messages uses 0 for "never").
    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let raw = sqlite3_column_int64(statement, index)
        return raw == 0 ? nil : MessagesDatabase.appleDate(raw)
    }
}

/// Reads image dimensions from file headers (no decoding) and remembers them for the session.
final class ImageSizeProbe: @unchecked Sendable {
    static let shared = ImageSizeProbe()
    private let lock = NSLock()
    private var sizes: [String: (width: Int, height: Int)] = [:]
    private var failures = Set<String>()

    func size(at path: String) -> (width: Int, height: Int)? {
        lock.lock()
        if let known = sizes[path] { lock.unlock(); return known }
        if failures.contains(path) { lock.unlock(); return nil }
        lock.unlock()
        let measured = Self.measure(path)
        lock.lock()
        if let measured { sizes[path] = measured } else { failures.insert(path) }
        lock.unlock()
        return measured
    }

    private static func measure(_ path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}
