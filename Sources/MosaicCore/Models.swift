import Foundation

public struct Message: Identifiable, Equatable, Sendable {
    public let id: String
    public var presentationID: String
    public let text: String
    public let date: Date
    public let isFromMe: Bool
    public let sender: String?
    public let attachmentCount: Int
    /// Files Messages stored for this message (photos, videos, documents) that exist on this Mac.
    public let attachments: [Attachment]
    public let isDelivered: Bool
    public let isRead: Bool
    public let error: Int

    public init(id: String, text: String, date: Date, isFromMe: Bool, sender: String? = nil,
                attachmentCount: Int = 0, attachments: [Attachment] = [],
                isDelivered: Bool = false, isRead: Bool = false, error: Int = 0) {
        self.id = id; self.presentationID = id; self.text = text; self.date = date; self.isFromMe = isFromMe
        self.sender = sender; self.attachmentCount = max(attachmentCount, attachments.count); self.attachments = attachments
        self.isDelivered = isDelivered; self.isRead = isRead; self.error = error
    }
}

/// A file attached to a message. Only metadata is held in memory; pixels are loaded lazily by the UI.
public struct Attachment: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case image, video, audio, file }
    public let id: String
    /// Absolute path of the local file, or nil when Messages has no downloaded copy.
    public let path: String?
    public let name: String
    public let mimeType: String?
    public let uti: String?
    public let isSticker: Bool
    /// Display size in pixels after EXIF orientation, when it could be read cheaply from the file header.
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(id: String, path: String?, name: String, mimeType: String? = nil, uti: String? = nil,
                isSticker: Bool = false, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.id = id; self.path = path; self.name = name; self.mimeType = mimeType; self.uti = uti
        self.isSticker = isSticker; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    public var kind: Kind {
        let mime = (mimeType ?? "").lowercased()
        let type = (uti ?? "").lowercased()
        let ext = ((path ?? name) as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || Self.imageTypes.contains(type) || Self.imageExtensions.contains(ext) { return .image }
        if mime.hasPrefix("video/") || Self.videoTypes.contains(type) || Self.videoExtensions.contains(ext) { return .video }
        if mime.hasPrefix("audio/") || Self.audioExtensions.contains(ext) { return .audio }
        return .file
    }
    /// Width divided by height, used to reserve a stable frame before the thumbnail loads.
    public var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }
    private static let imageTypes: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.heif", "com.compuserve.gif",
                                                  "public.tiff", "org.webmproject.webp", "public.image", "com.microsoft.bmp"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"]
    private static let videoTypes: Set<String> = ["com.apple.quicktime-movie", "public.mpeg-4", "public.movie", "public.video"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp"]
    private static let audioExtensions: Set<String> = ["caf", "m4a", "amr", "mp3", "wav", "aac"]
}

public struct Conversation: Identifiable, Equatable, Sendable {
    public let id: String
    public let databaseID: Int64
    public var name: String
    public var participants: [String]
    public let service: String
    public var preview: String
    public var lastActivity: Date
    public var unreadCount: Int
    public var messages: [Message]
    /// A tile for a message that has no conversation yet: the reader is still choosing recipients.
    public var isComposeDraft: Bool

    public init(id: String, databaseID: Int64 = 0, name: String, participants: [String],
                service: String = "iMessage", preview: String = "", lastActivity: Date = Date(),
                unreadCount: Int = 0, messages: [Message] = [], isComposeDraft: Bool = false) {
        self.id = id; self.databaseID = databaseID; self.name = name; self.participants = participants
        self.service = service; self.preview = preview; self.lastActivity = lastActivity
        self.unreadCount = unreadCount; self.messages = messages; self.isComposeDraft = isComposeDraft
    }

    /// The participants as comparable keys, so a chosen set of people can be matched to a chat.
    public var participantKeys: Set<String> { Set(participants.map(Recipient.key(for:))) }

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

/// Someone a new message is addressed to: a handle (phone number or email) and the name shown for it.
public struct Recipient: Identifiable, Equatable, Hashable, Sendable {
    public let address: String
    public let name: String
    public var id: String { Recipient.key(for: address) }
    public init(address: String, name: String? = nil) {
        self.address = address
        self.name = name?.isEmpty == false ? name! : Recipient.display(address)
    }

    /// A comparable form of a handle: emails lowercased, phone numbers reduced to digits without a
    /// leading country code 1, so "(917) 831-0374" and "+19178310374" are the same person.
    public static func key(for address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["mailto:", "tel:", "imessage:", "sms:"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.contains("@") { return value }
        var digits = value.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
        return digits.isEmpty ? value : digits
    }
    /// The handle in the form Messages accepts for a new recipient.
    public static func handle(for address: String) -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@") { return value.lowercased() }
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return value }
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return value.hasPrefix("+") ? "+" + digits : digits
    }
    /// A phone number formatted for display; other addresses unchanged.
    public static func display(_ address: String) -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("@") else { return value }
        var digits = value.filter(\.isNumber)
        guard !digits.isEmpty, digits.count == value.filter { !"+()- .".contains($0) }.count else { return value }
        var prefix = ""
        if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst(); prefix = "+1 " }
        else if digits.count == 10 { prefix = value.hasPrefix("+") ? "+" : "" }
        guard digits.count == 10 else { return value }
        let area = digits.prefix(3), middle = digits.dropFirst(3).prefix(3), last = digits.suffix(4)
        return "\(prefix)(\(area)) \(middle)-\(last)"
    }
}

/// Only layout, seen IDs, drafts and hidden conversations are persisted; message history stays in memory.
public struct Workspace: Codable, Equatable, Sendable {
    public static let maximumTiles = 4
    public var openIDs: [String] = []
    public var focusedID: String?
    public var layout: WorkspaceLayout = .grid
    public var drafts: [String: String] = [:]
    public var seenMessageIDs: [String: String] = [:]
    /// Conversations removed from Mosaic, with the id of their newest message when they were
    /// removed: a newer message brings a conversation back, as in Messages.
    public var hidden: [String: String] = [:]

    public init(openIDs: [String] = []) {
        var seen = Set<String>()
        self.openIDs = Array(openIDs.filter { seen.insert($0).inserted }.prefix(Self.maximumTiles))
        self.focusedID = self.openIDs.first
    }
    private enum CodingKeys: String, CodingKey { case openIDs, focusedID, layout, drafts, seenMessageIDs, hidden }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openIDs = try container.decodeIfPresent([String].self, forKey: .openIDs) ?? []
        focusedID = try container.decodeIfPresent(String.self, forKey: .focusedID)
        layout = try container.decodeIfPresent(WorkspaceLayout.self, forKey: .layout) ?? .grid
        drafts = try container.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
        seenMessageIDs = try container.decodeIfPresent([String: String].self, forKey: .seenMessageIDs) ?? [:]
        hidden = try container.decodeIfPresent([String: String].self, forKey: .hidden) ?? [:]
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
