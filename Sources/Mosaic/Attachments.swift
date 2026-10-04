import SwiftUI
import AppKit
import ImageIO
import Photos
import QuickLookThumbnailing
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

// MARK: - Model

/// A file waiting in a composer to go out with the next message — a pasted or dropped picture, a
/// photo from the library, or a chosen file — or the place reserved for one still on its way in.
struct OutgoingAttachment: Identifiable, Equatable {
    enum State: Equatable {
        /// Reserved; the file is being fetched or written.
        case importing
        case ready
        case failed(String)
        var isFailed: Bool { if case .failed = self { return true } else { return false } }
    }
    let id: String
    /// The file to send, once it is here. Pasted pictures and picked photos live in Mosaic's
    /// outgoing folder; a chosen file stays where it is.
    var url: URL?
    var state: State

    init(url: URL) {
        id = "outgoing-\(UUID().uuidString)"
        self.url = url
        state = .ready
    }
    static func importing() -> OutgoingAttachment { OutgoingAttachment(importing: ()) }
    private init(importing: Void) {
        id = "outgoing-\(UUID().uuidString)"
        url = nil
        state = .importing
    }
    /// A file a restored draft points at that is no longer there: shown, and blocking the send,
    /// until it is removed.
    static func missing(_ url: URL) -> OutgoingAttachment {
        var file = OutgoingAttachment(url: url)
        file.state = .failed("\(url.lastPathComponent) is no longer on this Mac.")
        return file
    }
    var isMissing: Bool { state.isFailed && url != nil }
    var name: String { url?.lastPathComponent ?? "Photo" }
    /// Whether the file is one Mosaic wrote (and may remove), not one the user chose.
    var isOwnedByMosaic: Bool { url.map(OutgoingFiles.isOwned) ?? false }
    /// The file as a message attachment, with its size (read from disk) for matching the row
    /// Messages later writes for it.
    var attachment: Attachment {
        let path = url?.path
        let size = path.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.intValue }
        return Attachment(id: id, path: path, name: name, uti: url.flatMap { UTType(filenameExtension: $0.pathExtension)?.identifier }, byteCount: size)
    }
    var kind: Attachment.Kind { Attachment(id: id, path: url?.path, name: name, uti: url.flatMap { UTType(filenameExtension: $0.pathExtension)?.identifier }).kind }
    /// The bubble shown while Messages takes the file; the real message replaces it.
    func pendingMessage(date: Date = Date()) -> Message {
        Message(id: "pending-\(UUID().uuidString)", text: "", date: date, isFromMe: true, attachments: [attachment])
    }
    /// How the sidebar previews a message that is only this file.
    var previewText: String {
        switch kind {
        case .image: return url?.pathExtension.lowercased() == "gif" ? "GIF" : "Photo"
        case .video: return "Video"
        case .audio: return "Audio"
        case .file: return name
        }
    }
}

// MARK: - Files

/// Where outgoing files live. Pasted pictures, picked photos and GIFs are written to Mosaic's own
/// folder in Application Support. At send time every file is copied into a folder inside
/// `~/Library/Messages`: Messages' sandbox reads attachments only from its own folders, so a file
/// handed to it from anywhere else is accepted by AppleScript and then quietly fails to send.
enum OutgoingFiles {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var pendingDirectory: URL { home.appending(path: "Library/Application Support/Mosaic/Outgoing") }
    static var stagingDirectory: URL { home.appending(path: "Library/Messages/.mosaic-outgoing") }
    /// Whether a file is in Mosaic's own outgoing folder (one it wrote, and may remove).
    static func isOwned(_ url: URL) -> Bool { url.path.hasPrefix(pendingDirectory.path) }

    /// Writes picture data (pasted or dropped) as its own file. TIFF, the clipboard's native
    /// picture format, is converted to PNG; everything else keeps its format (a GIF stays animated).
    static func store(_ data: Data, type: UTType, in directory: URL = pendingDirectory) throws -> URL {
        var data = data, type = type
        if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) { data = png; type = .png }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(type == .gif ? "GIF" : "Image") \(stamp()).\(type.preferredFilenameExtension ?? "png")")
        try data.write(to: url, options: .atomic)
        return url
    }
    /// Keeps a file that will not stay where it is (a Photos picker file representation disappears
    /// when its completion handler returns). Moved when the volume allows it, which is instant;
    /// copied otherwise.
    static func keep(_ source: URL, in directory: URL = pendingDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.lastPathComponent.isEmpty ? "File" : source.lastPathComponent
        let url = directory.appending(path: "\(stamp()) \(name)")
        do { try FileManager.default.moveItem(at: source, to: url) }
        catch { try FileManager.default.copyItem(at: source, to: url) }
        return url
    }
    /// A small thumbnail for the composer strip, quickly: a camera file's embedded preview when it
    /// has one, else a reduced decode; videos go through Quick Look at strip size.
    static func quickThumbnail(for file: OutgoingAttachment, maxPixelSize: Int = 240) async -> NSImage? {
        guard let url = file.url else { return nil }
        let kind = file.kind
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceShouldCacheImmediately: true,
                                                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
            }
            guard kind == .image || kind == .video else { return nil }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixelSize / 2, height: maxPixelSize / 2), scale: 2,
                                                       representationTypes: .thumbnail)
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }.value
    }
    /// Copies a file into Messages' folder for sending, in a folder of its own; returns the copy.
    static func stage(_ source: URL, in directory: URL = stagingDirectory) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return destination
    }
    /// The same copy, off the main thread: a large video copies while every composer stays responsive.
    static func stageInBackground(_ source: URL, in directory: URL = stagingDirectory) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try stage(source, in: directory) }.value
    }
    /// Removes a staged copy now (its send failed); the original it was copied from is untouched.
    static func removeStaged(_ staged: URL) {
        let folder = staged.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == stagingDirectory.standardizedFileURL.path else { return }
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: folder) }
    }
    /// Copies a file to a destination off the main thread, replacing what is there when asked.
    static func copyInBackground(_ source: URL, to destination: URL, replacing: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            if replacing, manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: source, to: destination)
        }.value
    }
    /// Removes a staged copy once Messages has had time to take it (Messages copies the file into
    /// its own Attachments folder as it sends).
    static func scheduleRemoval(of staged: URL, after seconds: TimeInterval = 180) {
        let folder = staged.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { try? FileManager.default.removeItem(at: folder) }
    }
    /// Drops leftovers from earlier runs: staged copies, and pending files more than two days old
    /// that no saved draft still points at. Only Mosaic's own folders are looked at.
    static func purgeStale(now: Date = Date(), keeping referenced: Set<String> = []) {
        purge(stagingDirectory, olderThan: 3600, now: now)
        purge(pendingDirectory, olderThan: 2 * 86400, now: now, keeping: referenced)
    }
    /// The same cleanup on a utility thread, so launch never waits for it.
    static func purgeStaleInBackground(keeping referenced: Set<String>) {
        Task.detached(priority: .utility) { purgeStale(keeping: referenced) }
    }
    static func purge(_ directory: URL, olderThan age: TimeInterval, now: Date, keeping referenced: Set<String> = []) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let kept = Set(referenced.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
        for item in items {
            if kept.contains(item.standardizedFileURL.resolvingSymlinksInPath().path) { continue }
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? manager.removeItem(at: item) }
        }
    }
    /// Reads any files or pictures a pasteboard carries: file URLs first (a Finder copy, a drag),
    /// then picture data (a screenshot, Copy Image in a browser). Nil when it carries neither.
    static func contents(of pasteboard: NSPasteboard) -> PasteboardContents? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        for type in [UTType.png, .jpeg, .gif, .heic, .tiff] {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)) { return .picture(data, type) }
        }
        return nil
    }
    enum PasteboardContents: Equatable {
        case files([URL])
        case picture(Data, UTType)
    }
    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return formatter.string(from: Date())
    }
}

// MARK: - Composer strip

/// The files waiting in a composer, as thumbnails above the text in the order they were added,
/// each with a remove badge: a placeholder while one is still on its way in, a warning for one
/// that could not be added.
struct AttachmentStrip: View {
    let files: [OutgoingAttachment]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(files) { file in
                    slot(file)
                        .overlay(alignment: .topTrailing) {
                            Button { onRemove(file.id) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.65))
                            }
                            .buttonStyle(.plain).offset(x: 6, y: -6)
                            .accessibilityLabel("Remove \(file.name)")
                        }
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
        }
        .scrollClipDisabled()
        .frame(height: 72)
    }
    @ViewBuilder private func slot(_ file: OutgoingAttachment) -> some View {
        switch file.state {
        case .ready:
            OutgoingThumbnail(file: file)
        case .importing:
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.incoming)
                .frame(width: 60, height: 60)
                .overlay { ProgressView().controlSize(.small) }
                .accessibilityLabel("Adding a photo")
        case .failed(let reason):
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.incoming)
                .frame(width: 60, height: 60)
                .overlay { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .help(reason)
                .accessibilityLabel("Could not add this file: \(reason)")
        }
    }
}

struct OutgoingThumbnail: View {
    let file: OutgoingAttachment
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.incoming)
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else if file.kind == .file || file.kind == .audio {
                VStack(spacing: 3) {
                    Image(nsImage: file.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .data)).resizable().frame(width: 26, height: 26)
                    Text(file.name).font(.system(size: 8)).lineLimit(1).foregroundStyle(.secondary).padding(.horizontal, 3)
                }
            } else {
                Image(systemName: file.kind == .video ? "video" : "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(file.name)
        .accessibilityLabel(file.previewText)
        .task(id: file.url) {
            guard image == nil, file.url != nil, file.kind == .image || file.kind == .video else { return }
            image = await OutgoingFiles.quickThumbnail(for: file)
        }
    }
}

// MARK: - The + button

/// The round + button at the left of a composer, as in Messages. Its menu offers the Photos
/// library (Mosaic's own grid, in a popover card) and a file chooser. An AppKit view, so the
/// picker has a real view to anchor its popover to.
struct AttachmentMenuButton: NSViewRepresentable {
    let conversationName: String
    /// Files ready to attach now (chosen in the file panel).
    let onFiles: ([URL]) -> Void
    /// This many photos are on their way from the Photos picker, in the order chosen; the places
    /// reserved for them come back, and each photo then arrives at its place through `onAdded`
    /// (nil when one could not be read), whichever finishes first.
    let onBeginAdding: (Int) -> [String]
    let onAdded: (String, URL?) -> Void
    /// The Photos card or the file chooser was dismissed with Esc, Cancel or Add: the keyboard
    /// goes back to this tile's message field. (Clicking somewhere else leaves it where it went.)
    var onFinish: () -> Void = {}

    func makeNSView(context: Context) -> PlusButtonView { let view = PlusButtonView(); configure(view); return view }
    func updateNSView(_ view: PlusButtonView, context: Context) { configure(view) }
    private func configure(_ view: PlusButtonView) {
        view.onFiles = onFiles
        view.onBeginAdding = onBeginAdding
        view.onAdded = onAdded
        view.onFinish = onFinish
        view.setAccessibilityLabel("Add a photo or file to the message to \(conversationName)")
        view.toolTip = "Photos and files"
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlusButtonView, context: Context) -> CGSize? { CGSize(width: 31, height: 31) }

    final class PlusButtonView: NSView, NSPopoverDelegate {
        var onFiles: (([URL]) -> Void)?
        var onBeginAdding: ((Int) -> [String])?
        var onAdded: ((String, URL?) -> Void)?
        var onFinish: (() -> Void)?
        private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
        private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
        private var trackingArea: NSTrackingArea?
        private var photosPopover: NSPopover?

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area); trackingArea = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func draw(_ dirtyRect: NSRect) {
            let diameter: CGFloat = 26
            let circle = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            NSColor.labelColor.withAlphaComponent(pressed ? 0.18 : hovered ? 0.13 : 0.09).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            guard let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            let tinted = symbol.tinted(NSColor.secondaryLabelColor)
            let size = tinted.size
            tinted.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2, width: size.width, height: size.height))
        }
        override func mouseDown(with event: NSEvent) {
            pressed = true
            showMenu()
            pressed = false
        }
        override func accessibilityPerformPress() -> Bool { showMenu(); return true }

        private func showMenu() {
            let menu = NSMenu()
            menu.addItem(item("Photos…", symbol: "photo.on.rectangle", #selector(pickPhotos)))
            menu.addItem(item("Choose File…", symbol: "doc", #selector(chooseFile)))
            // The last item sits just above the button, so the menu opens upward, as in Messages.
            menu.popUp(positioning: menu.items.last, at: NSPoint(x: 0, y: bounds.height + 6), in: self)
        }
        private func item(_ title: String, symbol: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }

        /// Mosaic's Photos grid, in a popover card from this button. Chosen pictures show up in the
        /// composer behind placeholders at once and are written out all at the same time.
        @objc private func pickPhotos() {
            photosPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentSize = PhotoLibraryPickerView.size
            let view = PhotoLibraryPickerView(
                onCancel: { [weak self, weak popover] in
                    popover?.close()
                    self?.onFinish?()
                },
                onAdd: { [weak self, weak popover] assets in
                    popover?.close()
                    self?.onFinish?()
                    guard let self, !assets.isEmpty, let slots = self.onBeginAdding?(assets.count), slots.count == assets.count else { return }
                    Task { @MainActor in
                        await withTaskGroup(of: (String, URL?).self) { group in
                            for (slot, asset) in zip(slots, assets) { group.addTask { (slot, await PhotoLibraryExport.file(for: asset)) } }
                            for await (slot, url) in group { self.onAdded?(slot, url) }
                        }
                    }
                })
            popover.contentViewController = NSHostingController(rootView: view)
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
            photosPopover = popover
            // The card takes the keyboard, so Esc reaches it (and closes it) straight away.
            popover.contentViewController?.view.window?.makeKey()
        }
        func popoverDidClose(_ notification: Notification) {
            photosPopover = nil
            // Closed by Esc (the popover's own handling): back to the message field, as Cancel does.
            if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 { onFinish?() }
        }

        @objc private func chooseFile() {
            guard let window else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.message = "Choose files to send"
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, !panel.urls.isEmpty { self?.onFiles?(panel.urls) }
                self?.onFinish?()
            }
        }
    }
}

extension NSImage {
    /// The image drawn in one color (for template symbols).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
