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

/// A cheap summary of everything in the database that Mosaic displays. Two equal fingerprints mean
/// a full load would produce the same conversations, so the poll can skip it.
public struct DatabaseFingerprint: Equatable, Sendable {
    public let values: [Int64]
    public init(values: [Int64]) { self.values = values }
}

/// The result of a load: the conversations and the fingerprint they correspond to.
public struct DatabaseSnapshot: Sendable {
    public let conversations: [Conversation]
    public let fingerprint: DatabaseFingerprint
}

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

    public func load(openIDs: Set<String>, limit: Int = 500, historyLimit: Int = 100) throws -> [Conversation] {
        try snapshot(openIDs: openIDs, limit: limit, historyLimit: historyLimit, unlessUnchangedFrom: nil)!.conversations
    }

    /// Loads conversations, or returns nil when `unlessUnchangedFrom` matches the database's current
    /// fingerprint (nothing that Mosaic shows has changed since that load).
    public func snapshot(openIDs: Set<String>, limit: Int = 500, historyLimit: Int = 100,
                         unlessUnchangedFrom known: DatabaseFingerprint?) throws -> DatabaseSnapshot? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw DatabaseError.accessDenied
        }
        defer { sqlite3_close(db) }
        // Messages writes to this database while it is read; wait rather than fail when it holds a lock.
        sqlite3_busy_timeout(db, 3000)
        // A read transaction ensures metadata and tile histories represent the same snapshot.
        try execute(db, "BEGIN DEFERRED")
        defer { try? execute(db, "ROLLBACK") }
        let columns = try tableColumns(db, table: "message")
        let fingerprint = try fingerprint(db, messageColumns: columns)
        if let known, known == fingerprint { return nil }
        // One query for every conversation's members, instead of one query per conversation.
        let membersByChat = try participantsByChat(db)
        guard columns.contains("is_from_me"), columns.contains("date"), columns.contains("text") else { throw DatabaseError.unsupportedSchema }
        func col(_ name: String, fallback: String = "0") -> String { columns.contains(name) ? "m.\(name)" : fallback }
        let body = col("attributedBody", fallback: "NULL")
        let sql = """
        SELECT c.ROWID, c.guid, c.display_name, c.chat_identifier, c.service_name,
               m.text, \(body), m.date, m.ROWID
        FROM chat c
        LEFT JOIN message m ON m.ROWID = (SELECT MAX(message_id) FROM chat_message_join WHERE chat_id = c.ROWID)
        ORDER BY COALESCE(m.date, 0) DESC LIMIT ?
        """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 5000))))
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
            let messages = openIDs.contains(guid) ? try history(db, chatID: rowID, columns: columns, limit: historyLimit) : []
            conversations.append(Conversation(id: guid, databaseID: rowID, name: name, participants: members,
                service: string(statement, 4) ?? "iMessage", preview: preview.isEmpty ? "Attachment or activity" : preview,
                lastActivity: Self.appleDate(sqlite3_column_int64(statement, 7)), messages: messages))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        // Keep pinned conversations even if they fall outside the recent-conversation limit.
        for id in openIDs.subtracting(Set(conversations.map(\.id))) {
            let pinned = try prepare(db, "SELECT ROWID, display_name, chat_identifier, service_name FROM chat WHERE guid = ?")
            defer { sqlite3_finalize(pinned) }
            bind(pinned, 1, id)
            if sqlite3_step(pinned) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(pinned, 0)
                let members = membersByChat[rowID] ?? []
                let history = try history(db, chatID: rowID, columns: columns, limit: historyLimit)
                let display = string(pinned, 1) ?? ""
                conversations.append(Conversation(id: id, databaseID: rowID,
                    name: display.isEmpty ? (members.isEmpty ? (string(pinned, 2) ?? id) : members.joined(separator: ", ")) : display,
                    participants: members, service: string(pinned, 3) ?? "iMessage", preview: history.last?.text ?? "",
                    lastActivity: history.last?.date ?? .distantPast, messages: history))
            }
        }
        return DatabaseSnapshot(conversations: conversations.filter { !$0.id.isEmpty }, fingerprint: fingerprint)
    }

    /// Counts and maxima over the tables Mosaic reads: new or deleted rows, new dates, delivery and
    /// read receipts, edits, retractions and attachment transfers all move at least one of them.
    private func fingerprint(_ db: OpaquePointer, messageColumns: Set<String>) throws -> DatabaseFingerprint {
        func max(_ column: String) -> String { messageColumns.contains(column) ? "(SELECT MAX(\(column)) FROM message)" : "0" }
        var parts = ["(SELECT COUNT(*) FROM message)", "(SELECT MAX(ROWID) FROM message)", max("date"), max("date_delivered"),
                     max("date_read"), max("date_edited"), max("date_retracted"), "(SELECT COUNT(*) FROM chat)",
                     "(SELECT MAX(ROWID) FROM chat_message_join)"]
        let attachmentColumns = try tableColumns(db, table: "attachment")
        if !attachmentColumns.isEmpty {
            parts.append("(SELECT COUNT(*) FROM attachment)")
            if attachmentColumns.contains("transfer_state") { parts.append("(SELECT SUM(transfer_state) FROM attachment)") }
        }
        let statement = try prepare(db, "SELECT " + parts.joined(separator: ", "))
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return DatabaseFingerprint(values: (0..<Int32(parts.count)).map { sqlite3_column_int64(statement, $0) })
    }

    private func history(_ db: OpaquePointer, chatID: Int64, columns: Set<String>, limit: Int) throws -> [Message] {
        func col(_ name: String, fallback: String = "0") -> String { columns.contains(name) ? "m.\(name)" : fallback }
        let statement = try prepare(db, """
            SELECT m.ROWID, m.text, \(col("attributedBody", fallback: "NULL")), m.date, m.is_from_me, h.id,
                   \(col("is_delivered")), \(col("is_read")), \(col("error")), \(col("cache_has_attachments")),
                   \(col("associated_message_type")), \(col("item_type"))
            FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = ? ORDER BY m.date DESC, m.ROWID DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 1000))))
        struct Row {
            let id: Int64; let text: String; let date: Date; let isFromMe: Bool; let sender: String?
            let attachmentCount: Int; let association: Int32; let itemType: Int32
            let isDelivered: Bool; let isRead: Bool; let error: Int
        }
        var rows: [Row] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(Row(id: sqlite3_column_int64(statement, 0),
                text: BodyDecoder.decode(text: string(statement, 1), attributedBody: blob(statement, 2)),
                date: Self.appleDate(sqlite3_column_int64(statement, 3)), isFromMe: sqlite3_column_int(statement, 4) != 0,
                sender: string(statement, 5), attachmentCount: Int(sqlite3_column_int(statement, 9)),
                association: sqlite3_column_int(statement, 10), itemType: sqlite3_column_int(statement, 11),
                isDelivered: sqlite3_column_int(statement, 6) != 0, isRead: sqlite3_column_int(statement, 7) != 0,
                error: Int(sqlite3_column_int(statement, 8))))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        let files = try attachments(db, chatID: chatID, from: rows.map(\.id).min(), messageIDs: Set(rows.map(\.id)))
        var messages: [Message] = []
        messages.reserveCapacity(rows.count)
        for row in rows.reversed() {
            let attached = files[row.id] ?? []
            var text = row.text
            if text.isEmpty && attached.isEmpty {
                if row.attachmentCount > 0 { text = "Attachment · Open in Messages" }
                else if row.association != 0 { text = "Reaction · Open in Messages" }
                else if row.itemType != 0 { text = "Conversation activity" }
                else { text = "Message · Open in Messages" }
            }
            messages.append(Message(id: String(row.id), text: text, date: row.date, isFromMe: row.isFromMe,
                sender: row.sender, attachmentCount: row.attachmentCount, attachments: attached,
                isDelivered: row.isDelivered, isRead: row.isRead, error: row.error))
        }
        return messages
    }

    /// Attachment metadata for the loaded messages. Missing tables (older or synthetic schemas) yield no attachments.
    private func attachments(_ db: OpaquePointer, chatID: Int64, from minimumID: Int64?, messageIDs: Set<Int64>) throws -> [Int64: [Attachment]] {
        guard let minimumID, !messageIDs.isEmpty else { return [:] }
        let columns = try tableColumns(db, table: "attachment")
        let joinColumns = try tableColumns(db, table: "message_attachment_join")
        guard columns.contains("filename"), joinColumns.contains("attachment_id") else { return [:] }
        func col(_ name: String, fallback: String = "NULL") -> String { columns.contains(name) ? "a.\(name)" : fallback }
        let statement = try prepare(db, """
            SELECT maj.message_id, a.ROWID, \(col("guid")), a.filename, \(col("mime_type")), \(col("uti")),
                   \(col("transfer_name")), \(col("is_sticker", fallback: "0")), \(col("hide_attachment", fallback: "0"))
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
            let path = Self.resolve(rawPath, home: home)
            let name = string(statement, 6) ?? rawPath.map { ($0 as NSString).lastPathComponent } ?? "Attachment"
            var attachment = Attachment(id: string(statement, 2) ?? "attachment-\(sqlite3_column_int64(statement, 1))",
                path: path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }, name: name,
                mimeType: string(statement, 4), uti: string(statement, 5), isSticker: sqlite3_column_int(statement, 7) != 0)
            if attachment.kind == .image, let file = attachment.path, let size = ImageSizeProbe.shared.size(at: file) {
                attachment = Attachment(id: attachment.id, path: file, name: name, mimeType: attachment.mimeType, uti: attachment.uti,
                    isSticker: attachment.isSticker, pixelWidth: size.width, pixelHeight: size.height)
            }
            result[messageID, default: []].append(attachment)
        }
        return result
    }

    static func resolve(_ raw: String?, home: URL) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value == "~" { return home.path }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))).path }
        return value
    }

    public static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 10_000_000_000 || raw < -10_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
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
