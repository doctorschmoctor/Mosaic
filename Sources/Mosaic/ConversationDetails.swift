import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// What a conversation has shared — photos and videos, files and links, newest first — from the
/// messages the tile has loaded (so it follows edits, unsends and deletions as they arrive) and,
/// in the installed app, from its whole history (`SharedHistory`, read on the background
/// connection), each item once.
struct SharedContent: Equatable {
    struct Item: Identifiable, Equatable {
        let messageID: String
        let attachment: Attachment
        let date: Date
        var id: String { messageID + "/" + attachment.id }
    }
    struct Link: Identifiable, Equatable {
        let messageID: String
        let url: URL
        let date: Date
        var id: String { url.absoluteString }
    }
    var media: [Item] = []
    var files: [Item] = []
    var links: [Link] = []
    /// The files that are on this Mac, for Quick Look's next and previous: worked out once, not
    /// for each picture's menu as it was drawn (hundreds of times over, in a long history).
    private(set) var localMedia: [URL] = []
    private(set) var localFiles: [URL] = []

    init(messages: [Message], history: SharedHistory? = nil) {
        var seenItems = Set<String>(), seenLinks = Set<String>()
        func add(_ item: Item) {
            guard seenItems.insert(item.id).inserted else { return }
            switch item.attachment.kind {
            case .image, .video: media.append(item)
            case .audio, .file: files.append(item)
            }
        }
        func add(_ link: Link) { if seenLinks.insert(link.id).inserted { links.append(link) } }
        for message in messages.reversed() where !message.isUnsent && message.sendState == nil {
            for attachment in message.attachments where !attachment.isSticker {
                add(Item(messageID: message.id, attachment: attachment, date: message.date))
            }
            for match in LinkDetector.links(in: message.text) { add(Link(messageID: message.id, url: match.url, date: message.date)) }
        }
        if let history {
            // The whole history's, after the loaded ones; a loaded message's items are already in.
            for file in history.files where !file.attachment.isSticker {
                add(Item(messageID: file.messageID, attachment: file.attachment, date: file.date))
            }
            for link in history.links { add(Link(messageID: link.messageID, url: link.url, date: link.date)) }
            // Newest first across both.
            media.sort { $0.date > $1.date }
            files.sort { $0.date > $1.date }
            links.sort { $0.date > $1.date }
        }
        localMedia = media.compactMap { $0.attachment.path.map(URL.init(fileURLWithPath:)) }
        localFiles = files.compactMap { $0.attachment.path.map(URL.init(fileURLWithPath:)) }
    }
}

/// A tile's shared content, worked out again only when its messages or the whole history's files
/// and links change — not each time the tile is drawn again (a focus change, a refresh, a message
/// in another conversation), which with a long history's hundreds of pictures and links held up
/// every change in the workspace while the details were open.
@MainActor final class SharedContentCache {
    private var messages: [Message]?
    private var history: SharedHistory?
    private(set) var content = SharedContent(messages: [])
    /// Goes up each time the content is worked out again: the lists compare it to tell whether
    /// they have anything new to draw.
    private(set) var version = 0
    func content(for messages: [Message], history: SharedHistory?) -> SharedContent {
        if let known = self.messages, known == messages, self.history == history { return content }
        self.messages = messages
        self.history = history
        content = SharedContent(messages: messages, history: history)
        version += 1
        return content
    }
}

extension Notification.Name {
    /// Opens the details of the tile whose id is the object (or closes them, when open).
    static let showConversationDetails = Notification.Name("Mosaic.showConversationDetails")
    /// Closes the details of the tile whose id is the object (Esc).
    static let closeConversationDetails = Notification.Name("Mosaic.closeConversationDetails")
}

/// A tile's details (⌘I, or the header's menu), in place of its thread: People, Photos & Videos,
/// Files and Links from the loaded messages. Each item previews in Quick Look (or opens, for a
/// link) and can be shown where it was sent. Closing it leaves the draft as it was.
struct ConversationDetailsPanel: View {
    @Environment(WorkspaceStore.self) private var store
    let conversation: Conversation
    let onShowMessage: (String) -> Void
    let onClose: () -> Void
    @State private var section: Section = .people
    /// The whole history's files and links, once read (nil until then, and in the demo workspace).
    @State private var history: SharedHistory?
    @State private var readingHistory = false
    @State private var shared = SharedContentCache()

    enum Section: String, CaseIterable, Identifiable {
        case people, media, files, links
        var id: String { rawValue }
        var title: String {
            switch self {
            case .people: return "People"
            case .media: return "Photos & Videos"
            case .files: return "Files"
            case .links: return "Links"
            }
        }
    }

    var body: some View {
        let content = shared.content(for: conversation.messages, history: history)
        let version = shared.version
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Details", selection: $section) {
                    ForEach(Section.allCases) { section in Text(title(section, content)).tag(section) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                // While the whole history is being read.
                if readingHistory { ProgressView().controlSize(.mini).accessibilityLabel("Reading the whole conversation") }
                Button("Done", action: onClose).buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                    .help("Back to the conversation (Esc)")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider().opacity(0.6)
            ScrollView {
                Group {
                    // Each list is drawn again only when what it shows changes, not each time the
                    // tile is; the long ones lay out only the rows in view (and a few more).
                    switch section {
                    case .people: people
                    case .media: SharedMediaGrid(content: content, version: version, onShowMessage: onShowMessage).equatable()
                    case .files: SharedFilesList(content: content, version: version, onShowMessage: onShowMessage).equatable()
                    case .links: SharedLinksList(content: content, version: version, onShowMessage: onShowMessage).equatable()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The whole history is read once the panel is open, on the background connection.
        .task(id: conversation.id) {
            guard store.isLive, history == nil else { return }
            readingHistory = true
            history = await store.sharedHistory(conversation.id)
            readingHistory = false
        }
    }

    private func title(_ section: Section, _ content: SharedContent) -> String {
        switch section {
        case .people: return section.title
        case .media: return content.media.isEmpty ? section.title : "\(section.title) \(content.media.count)"
        case .files: return content.files.isEmpty ? section.title : "\(section.title) \(content.files.count)"
        case .links: return content.links.isEmpty ? section.title : "\(section.title) \(content.links.count)"
        }
    }
    private var people: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conversation.isGroup {
                Text("\(conversation.participants.count + 1) people, including you").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(conversation.participants, id: \.self) { address in
                let name = store.name(for: address)
                HStack(spacing: 10) {
                    Avatar(conversation: Conversation(id: address, name: name, participants: [address]), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        // The address Messages sends to, which can differ from how the contact is named.
                        Text(Recipient.display(address)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Service: \(conversation.service)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

}

/// Says a list has nothing in it.
private struct DetailsEmpty: View {
    let text: String
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
}

/// The photos and videos: a grid that lays out the pictures in view (and a few more) as it
/// scrolls, drawn again only when the shared content changes (`version`).
struct SharedMediaGrid: View, Equatable {
    let content: SharedContent
    let version: Int
    let onShowMessage: (String) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }

    var body: some View {
        if content.media.isEmpty {
            DetailsEmpty(text: "No photos or videos in the loaded messages.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: 6)], spacing: 6) {
                ForEach(content.media) { item in
                    MediaThumbnail(attachment: item.attachment)
                        .onTapGesture { AttachmentActions.quickLook(item.attachment, among: content.localMedia) }
                        .contextMenu {
                            AttachmentMenuItems(attachment: item.attachment, siblings: content.localMedia)
                            Divider()
                            Button("Show in Conversation") { onShowMessage(item.messageID) }
                        }
                        .help("\(item.attachment.name) · \(MessageText.day(item.date))")
                }
            }
        }
    }
}

/// The files, one row each, laid out as they scroll into view.
struct SharedFilesList: View, Equatable {
    let content: SharedContent
    let version: Int
    let onShowMessage: (String) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }

    var body: some View {
        if content.files.isEmpty {
            DetailsEmpty(text: "No files in the loaded messages.")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(content.files) { item in
                    HStack(spacing: 9) {
                        Image(nsImage: item.attachment.path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .data))
                            .resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.attachment.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Text(item.attachment.path == nil ? "Not on this Mac · \(MessageText.day(item.date))" : MessageText.day(item.date))
                                .font(.system(size: 10)).foregroundStyle(item.attachment.path == nil ? Color.orange : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { AttachmentActions.quickLook(item.attachment, among: content.localFiles) }
                    .contextMenu {
                        AttachmentMenuItems(attachment: item.attachment, siblings: content.localFiles)
                        Divider()
                        Button("Show in Conversation") { onShowMessage(item.messageID) }
                    }
                }
            }
        }
    }
}

/// The links, one row each, laid out as they scroll into view.
struct SharedLinksList: View, Equatable {
    let content: SharedContent
    let version: Int
    let onShowMessage: (String) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }

    var body: some View {
        if content.links.isEmpty {
            DetailsEmpty(text: "No links in the loaded messages.")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(content.links) { link in
                    HStack(spacing: 9) {
                        Image(systemName: "link").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(LinkPreviewLoader.host(link.url)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(link.url.absoluteString).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Text(MessageText.day(link.date)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(link.url) }
                    .contextMenu {
                        Button("Open Link") { NSWorkspace.shared.open(link.url) }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                        }
                        Divider()
                        Button("Show in Conversation") { onShowMessage(link.messageID) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isLink)
                }
            }
        }
    }
}

/// A small square picture of a photo or video, decoded at its small size; one that is not on this
/// Mac says so.
struct MediaThumbnail: View {
    let attachment: Attachment
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let tier = ThumbnailCache.tier(forPoints: 120, scale: displayScale)
        // Decoded already (seen before, here or in the thread): shown from the first frame.
        let shown = image ?? attachment.path.flatMap { ThumbnailCache.shared.decoded(path: $0, tier: tier) }
        Rectangle().fill(Palette.incoming)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let shown {
                    Image(nsImage: shown).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                } else if attachment.path == nil {
                    VStack(spacing: 3) {
                        Image(systemName: attachment.kind == .video ? "video.slash" : "icloud.slash").font(.system(size: 14))
                        Text("Not on this Mac").font(.system(size: 9))
                    }.foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if attachment.kind == .video, shown != nil {
                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.white).padding(5).shadow(radius: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((attachment.kind == .video ? "Video " : "Photo ") + attachment.name + (attachment.path == nil ? ", not on this Mac" : ""))
            .accessibilityAddTraits(.isButton)
            .task(id: attachment.path) {
                guard attachment.path != nil, image == nil else { return }
                image = await ThumbnailCache.shared.image(for: attachment, tier: tier)
            }
            // Out of view, the picture is the cache's to keep or let go of: a long history's
            // hundreds would otherwise all stay in memory once scrolled past.
            .onDisappear { image = nil }
    }
}
