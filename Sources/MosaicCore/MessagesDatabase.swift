import Foundation
import CSQLite

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

public struct MessagesDatabase: Sendable {
    public let path: String
    public init(path: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path) {
        self.path = path
    }

    public func load(openIDs: Set<String>, limit: Int = 500, historyLimit: Int = 100) throws -> [Conversation] {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw DatabaseError.accessDenied
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1200)
        // A read transaction ensures metadata and tile histories represent the same snapshot.
        try execute(db, "BEGIN")
        defer { try? execute(db, "ROLLBACK") }
        let columns = try tableColumns(db, table: "message")
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
            let members = try participants(db, chatID: rowID)
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
                let members = try participants(db, chatID: rowID)
                let history = try history(db, chatID: rowID, columns: columns, limit: historyLimit)
                let display = string(pinned, 1) ?? ""
                conversations.append(Conversation(id: id, databaseID: rowID,
                    name: display.isEmpty ? (members.isEmpty ? (string(pinned, 2) ?? id) : members.joined(separator: ", ")) : display,
                    participants: members, service: string(pinned, 3) ?? "iMessage", preview: history.last?.text ?? "",
                    lastActivity: history.last?.date ?? .distantPast, messages: history))
            }
        }
        return conversations.filter { !$0.id.isEmpty }
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
        var messages: [Message] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var text = BodyDecoder.decode(text: string(statement, 1), attributedBody: blob(statement, 2))
            let attachment = Int(sqlite3_column_int(statement, 9))
            let association = sqlite3_column_int(statement, 10)
            let itemType = sqlite3_column_int(statement, 11)
            if text.isEmpty {
                if attachment > 0 { text = "Attachment · Open in Messages" }
                else if association != 0 { text = "Reaction · Open in Messages" }
                else if itemType != 0 { text = "Conversation activity" }
                else { text = "Message · Open in Messages" }
            }
            messages.append(Message(id: String(sqlite3_column_int64(statement, 0)), text: text,
                date: Self.appleDate(sqlite3_column_int64(statement, 3)), isFromMe: sqlite3_column_int(statement, 4) != 0,
                sender: string(statement, 5), attachmentCount: attachment,
                isDelivered: sqlite3_column_int(statement, 6) != 0, isRead: sqlite3_column_int(statement, 7) != 0,
                error: Int(sqlite3_column_int(statement, 8))))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return messages.reversed()
    }

    public static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 10_000_000_000 || raw < -10_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
    private func participants(_ db: OpaquePointer, chatID: Int64) throws -> [String] {
        let statement = try prepare(db, "SELECT h.id FROM handle h JOIN chat_handle_join j ON j.handle_id = h.ROWID WHERE j.chat_id = ? ORDER BY h.ROWID")
        defer { sqlite3_finalize(statement) }; sqlite3_bind_int64(statement, 1, chatID)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let id = string(statement, 0) { result.append(id) } }
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
