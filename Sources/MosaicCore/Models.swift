import Foundation

public struct Message: Identifiable, Equatable, Sendable {
    /// What a row in the conversation is: a message someone wrote (or a file they sent), or a
    /// line about the conversation itself (someone joined, the name changed).
    public enum Kind: String, Sendable { case message, activity }
    /// The database row (or a local "pending-…" id until Messages reports the row).
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
    public let kind: Kind
    /// Messages' own identity for the row, the one reactions and replies refer to. Nil for a
    /// pending message and for databases without the column.
    public let guid: String?
    /// For a reply: the GUID of the message it answers, and which part of it (a message with
    /// several attachments has several parts).
    public let replyToGUID: String?
    public let replyToPart: Int?
    /// When the text was last edited, and when it was unsent, where the database records them.
    public let dateEdited: Date?
    public let dateRetracted: Date?
    /// For a message Mosaic sent and the database has not reported yet: where it stands.
    public var sendState: SendState?

    public init(id: String, text: String, date: Date, isFromMe: Bool, sender: String? = nil,
                attachmentCount: Int = 0, attachments: [Attachment] = [],
                isDelivered: Bool = false, isRead: Bool = false, error: Int = 0,
                kind: Kind = .message, guid: String? = nil, replyToGUID: String? = nil, replyToPart: Int? = nil,
                dateEdited: Date? = nil, dateRetracted: Date? = nil) {
        self.id = id; self.presentationID = id; self.text = text; self.date = date; self.isFromMe = isFromMe
        self.sender = sender; self.attachmentCount = max(attachmentCount, attachments.count); self.attachments = attachments
        self.isDelivered = isDelivered; self.isRead = isRead; self.error = error
        self.kind = kind; self.guid = guid; self.replyToGUID = replyToGUID; self.replyToPart = replyToPart
        self.dateEdited = dateEdited; self.dateRetracted = dateRetracted
    }
    public var isEdited: Bool { dateEdited != nil }
    public var isUnsent: Bool { dateRetracted != nil }
    /// A local message the database has not confirmed (pending, submitted or failed).
    public var isLocal: Bool { sendState != nil }
}

/// Where a message Mosaic sent stands between Return and the database: being handed to Messages,
/// handed over (the database has not reported it yet; delivery is the database's to say), or
/// refused — a failed message is never retried by itself.
public enum SendState: Equatable, Sendable {
    case sending
    case submitted
    case failed(String)
    public var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// A Tapback someone put on (or took off) a message: one row of the database, kept apart from the
/// messages so it never takes a message's place in a history page. The latest state per actor and
/// target is what a thread shows; the reducer that builds it lives with the view.
public struct ReactionEvent: Identifiable, Equatable, Sendable {
    /// Messages' reaction codes: 2000–2999 put a reaction on, 3000–3999 take the same one off.
    public enum Kind: Equatable, Sendable {
        case love, like, dislike, laugh, emphasize, question
        /// A custom emoji reaction (newer systems); the emoji is the row's text.
        case emoji(String)
        case other(Int)
    }
    public let id: String
    public let date: Date
    public let isFromMe: Bool
    public let actor: String?
    /// The GUID of the message reacted to, and the part of it, from Messages' `p:<part>/<guid>`,
    /// `bp:<guid>` or bare `<guid>` forms.
    public let targetGUID: String
    public let targetPart: Int?
    public let kind: Kind
    public let isRemoval: Bool

    public init(id: String, date: Date, isFromMe: Bool, actor: String?, targetGUID: String, targetPart: Int?, kind: Kind, isRemoval: Bool) {
        self.id = id; self.date = date; self.isFromMe = isFromMe; self.actor = actor
        self.targetGUID = targetGUID; self.targetPart = targetPart; self.kind = kind; self.isRemoval = isRemoval
    }

    /// Whether a row's `associated_message_type` is a reaction at all.
    public static func isReaction(type: Int) -> Bool { (2000..<4000).contains(type) }
    public static func kind(forType type: Int, text: String?) -> Kind {
        switch type % 1000 {
        case 0: return .love
        case 1: return .like
        case 2: return .dislike
        case 3: return .laugh
        case 4: return .emphasize
        case 5: return .question
        case 6: return .emoji(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        default: return .other(type)
        }
    }
    /// Splits Messages' target reference into the GUID and the part it points at.
    public static func target(from reference: String?) -> (guid: String, part: Int?)? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
        if reference.hasPrefix("bp:") { return (String(reference.dropFirst(3)), nil) }
        if reference.hasPrefix("p:"), let slash = reference.firstIndex(of: "/") {
            let part = Int(reference[reference.index(reference.startIndex, offsetBy: 2)..<slash])
            let guid = String(reference[reference.index(after: slash)...])
            return guid.isEmpty ? nil : (guid, part)
        }
        return (reference, nil)
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
    /// The file's size as Messages recorded it, when known: one more way to tell two sent files apart.
    public let byteCount: Int?

    public init(id: String, path: String?, name: String, mimeType: String? = nil, uti: String? = nil,
                isSticker: Bool = false, pixelWidth: Int? = nil, pixelHeight: Int? = nil, byteCount: Int? = nil) {
        self.id = id; self.path = path; self.name = name; self.mimeType = mimeType; self.uti = uti
        self.isSticker = isSticker; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.byteCount = byteCount
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
    /// Reactions on the loaded messages (not shown yet; kept apart from the history page).
    public var reactions: [ReactionEvent]
    /// A tile for a message that has no conversation yet: the reader is still choosing recipients.
    public var isComposeDraft: Bool

    public init(id: String, databaseID: Int64 = 0, name: String, participants: [String],
                service: String = "iMessage", preview: String = "", lastActivity: Date = Date(),
                unreadCount: Int = 0, messages: [Message] = [], reactions: [ReactionEvent] = [], isComposeDraft: Bool = false) {
        self.id = id; self.databaseID = databaseID; self.name = name; self.participants = participants
        self.service = service; self.preview = preview; self.lastActivity = lastActivity
        self.unreadCount = unreadCount; self.messages = messages; self.reactions = reactions; self.isComposeDraft = isComposeDraft
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
    /// Puts `id` where `victim` was, focused; the layout keeps its shape.
    public mutating func replace(_ victim: String, with id: String) {
        guard let index = openIDs.firstIndex(of: victim), !openIDs.contains(id) else { return }
        openIDs[index] = id
        focusedID = id
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
