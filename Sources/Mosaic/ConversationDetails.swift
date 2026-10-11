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
        guard let history else { return }
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
    /// The files that are on this Mac, for Quick Look's next and previous.
    var localMedia: [URL] { media.compactMap { $0.attachment.path.map(URL.init(fileURLWithPath:)) } }
    var localFiles: [URL] { files.compactMap { $0.attachment.path.map(URL.init(fileURLWithPath:)) } }
}

extension Notification.Name {
    /// Opens the details of the tile whose id is the object.
    static let showConversationDetails = Notification.Name("Mosaic.showConversationDetails")
}

/// A tile's details (⌘I, or the header's menu), in place of its thread: People, Photos & Videos,
/// Files and Links from the loaded messages. Each item previews in Quick Look (or opens, for a
/// link) and can be shown where it was sent. Closing it leaves the draft as it was.
struct ConversationDetailsPanel: View {
    @Environment(WorkspaceStore.self) private var store
    let conversation: Conversation
    /// Whether the tile has more history than it has loaded.
    let hasOlderHistory: Bool
    let onShowMessage: (String) -> Void
    let onClose: () -> Void
    @State private var section: Section = .people
    /// The whole history's files and links, once read (nil until then, and in the demo workspace).
    @State private var history: SharedHistory?
    @State private var readingHistory = false

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
        let content = SharedContent(messages: conversation.messages, history: history)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Details", selection: $section) {
                    ForEach(Section.allCases) { section in Text(title(section, content)).tag(section) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                Button("Done", action: onClose).buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider().opacity(0.6)
            ScrollView {
                Group {
                    switch section {
                    case .people: people
                    case .media: media(content)
                    case .files: files(content)
                    case .links: links(content)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.6)
            HStack(spacing: 6) {
                if readingHistory { ProgressView().controlSize(.mini) }
                Text(scope).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
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
    private var scope: String {
        if readingHistory { return "Looking through the whole conversation…" }
        if let history {
            var notes: [String] = []
            if !history.filesComplete { notes.append("the newest 1,000 files") }
            if !history.linksComplete { notes.append("the newest 1,000 links") }
            let base = notes.isEmpty ? "From the whole conversation" : "From the whole conversation · " + notes.joined(separator: " and ")
            // Links are found where a message mentions "http" or "www.".
            return base + (section == .links ? " · links written with http or www" : "")
        }
        let loaded = conversation.messages.filter { $0.sendState == nil }.count
        let base = "From the \(loaded) loaded message\(loaded == 1 ? "" : "s")"
        return hasOlderHistory ? base + " · older ones aren't included" : base
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

    @ViewBuilder private func media(_ content: SharedContent) -> some View {
        if content.media.isEmpty {
            empty("No photos or videos in the loaded messages.")
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

    @ViewBuilder private func files(_ content: SharedContent) -> some View {
        if content.files.isEmpty {
            empty("No files in the loaded messages.")
        } else {
            VStack(alignment: .leading, spacing: 2) {
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

    @ViewBuilder private func links(_ content: SharedContent) -> some View {
        if content.links.isEmpty {
            empty("No links in the loaded messages.")
        } else {
            VStack(alignment: .leading, spacing: 2) {
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

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// A small square picture of a photo or video, decoded at its small size; one that is not on this
/// Mac says so.
struct MediaThumbnail: View {
    let attachment: Attachment
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle().fill(Palette.incoming)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                } else if attachment.path == nil {
                    VStack(spacing: 3) {
                        Image(systemName: attachment.kind == .video ? "video.slash" : "icloud.slash").font(.system(size: 14))
                        Text("Not on this Mac").font(.system(size: 9))
                    }.foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if attachment.kind == .video, image != nil {
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
                image = await ThumbnailCache.shared.image(for: attachment, tier: ThumbnailCache.tier(forPoints: 120, scale: displayScale))
            }
    }
}
