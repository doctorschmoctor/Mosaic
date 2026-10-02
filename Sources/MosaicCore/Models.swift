import Foundation

public struct Message: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let date: Date
    public let isFromMe: Bool
    public let sender: String?
    public let attachmentCount: Int
    public let isDelivered: Bool
    public let isRead: Bool
    public let error: Int

    public init(id: String, text: String, date: Date, isFromMe: Bool, sender: String? = nil,
                attachmentCount: Int = 0, isDelivered: Bool = false, isRead: Bool = false, error: Int = 0) {
        self.id = id; self.text = text; self.date = date; self.isFromMe = isFromMe
        self.sender = sender; self.attachmentCount = attachmentCount
        self.isDelivered = isDelivered; self.isRead = isRead; self.error = error
    }
}

public struct Conversation: Identifiable, Equatable, Sendable {
    public let id: String
    public let databaseID: Int64
    public var name: String
    public let participants: [String]
    public let service: String
    public var preview: String
    public var lastActivity: Date
    public var unreadCount: Int
    public var messages: [Message]

    public init(id: String, databaseID: Int64 = 0, name: String, participants: [String],
                service: String = "iMessage", preview: String = "", lastActivity: Date = Date(),
                unreadCount: Int = 0, messages: [Message] = []) {
        self.id = id; self.databaseID = databaseID; self.name = name; self.participants = participants
        self.service = service; self.preview = preview; self.lastActivity = lastActivity
        self.unreadCount = unreadCount; self.messages = messages
    }

    public var initials: String {
        let parts = name.split(separator: " ")
        if name.first == "+" { return String(name.suffix(2)) }
        return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
    public var isGroup: Bool { participants.count > 1 }
}

public enum WorkspaceLayout: String, Codable, CaseIterable, Sendable {
    case grid, columns, focus
    public var title: String { rawValue.capitalized }
}

/// Only layout, seen IDs, and drafts are persisted; message history stays in memory.
public struct Workspace: Codable, Equatable, Sendable {
    public static let maximumTiles = 8
    public var openIDs: [String] = []
    public var focusedID: String?
    public var layout: WorkspaceLayout = .grid
    public var drafts: [String: String] = [:]
    public var seenMessageIDs: [String: String] = [:]

    public init(openIDs: [String] = []) {
        var seen = Set<String>()
        self.openIDs = Array(openIDs.filter { seen.insert($0).inserted }.prefix(Self.maximumTiles))
        self.focusedID = self.openIDs.first
    }
    @discardableResult public mutating func open(_ id: String) -> Bool {
        if openIDs.contains(id) { focusedID = id; return true }
        guard openIDs.count < Self.maximumTiles else { return false }
        openIDs.append(id); focusedID = id
        return true
    }
    public mutating func close(_ id: String) {
        openIDs.removeAll { $0 == id }
        if focusedID == id { focusedID = openIDs.first }
    }
    public mutating func reorder(_ source: String, before destination: String) {
        guard source != destination, openIDs.contains(source), openIDs.contains(destination) else { return }
        openIDs.removeAll { $0 == source }
        if let index = openIDs.firstIndex(of: destination) { openIDs.insert(source, at: index) }
    }
    public mutating func reconcile(availableIDs: Set<String>) {
        var seen = Set<String>()
        openIDs = Array(openIDs.filter { availableIDs.contains($0) && seen.insert($0).inserted }.prefix(Self.maximumTiles))
        if !openIDs.contains(focusedID ?? "") { focusedID = openIDs.first }
    }
}
