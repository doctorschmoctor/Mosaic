import SwiftUI
import AppKit
import ImageIO
import PhotosUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

// MARK: - Model

/// A file waiting in a composer to go out with the next message: a pasted or dropped picture, a
/// photo from the library, a GIF, or a chosen file.
struct OutgoingAttachment: Identifiable, Equatable {
    let id: String
    /// The file to send. Pasted pictures and picked photos live in Mosaic's outgoing folder; a
    /// chosen file stays where it is.
    let url: URL
    init(url: URL) {
        id = "outgoing-\(UUID().uuidString)"
        self.url = url
    }
    var name: String { url.lastPathComponent }
    var attachment: Attachment {
        Attachment(id: id, path: url.path, name: name, uti: UTType(filenameExtension: url.pathExtension)?.identifier)
    }
    var kind: Attachment.Kind { attachment.kind }
    /// The bubble shown while Messages takes the file; the real message replaces it.
    func pendingMessage(date: Date = Date()) -> Message {
        Message(id: "pending-\(UUID().uuidString)", text: "", date: date, isFromMe: true, attachments: [attachment])
    }
    /// How the sidebar previews a message that is only this file.
    var previewText: String {
        switch kind {
        case .image: return url.pathExtension.lowercased() == "gif" ? "GIF" : "Photo"
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
        let url = file.url, kind = file.kind
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
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
    /// Removes a staged copy once Messages has had time to take it (Messages copies the file into
    /// its own Attachments folder as it sends).
    static func scheduleRemoval(of staged: URL, after seconds: TimeInterval = 180) {
        let folder = staged.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { try? FileManager.default.removeItem(at: folder) }
    }
    /// Drops leftovers from earlier runs: staged copies, and pending files more than two days old.
    static func purgeStale(now: Date = Date()) {
        purge(stagingDirectory, olderThan: 3600, now: now)
        purge(pendingDirectory, olderThan: 2 * 86400, now: now)
    }
    static func purge(_ directory: URL, olderThan age: TimeInterval, now: Date) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
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
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return formatter.string(from: Date())
    }
}

// MARK: - Composer strip

/// The files waiting in a composer, as thumbnails above the text, each with a remove badge, plus a
/// placeholder for every file still on its way in (from the Photos picker, or a picture being written).
struct AttachmentStrip: View {
    let files: [OutgoingAttachment]
    var loading = 0
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(files) { file in
                    OutgoingThumbnail(file: file)
                        .overlay(alignment: .topTrailing) {
                            Button { onRemove(file.id) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.65))
                            }
                            .buttonStyle(.plain).offset(x: 6, y: -6)
                            .accessibilityLabel("Remove \(file.name)")
                        }
                }
                ForEach(0..<max(0, loading), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.incoming)
                        .frame(width: 60, height: 60)
                        .overlay { ProgressView().controlSize(.small) }
                        .accessibilityLabel("Adding a photo")
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
        }
        .scrollClipDisabled()
        .frame(height: 72)
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
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 26, height: 26)
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
        .task(id: file.id) {
            guard image == nil, file.kind == .image || file.kind == .video else { return }
            image = await OutgoingFiles.quickThumbnail(for: file)
        }
    }
}

// MARK: - The + button

/// The round + button at the left of a composer, as in Messages. Its menu offers the Photos
/// library (the system picker, in a popover card) and a file chooser. An AppKit view, so the
/// picker has a real view to anchor its popover to.
struct AttachmentMenuButton: NSViewRepresentable {
    let conversationName: String
    /// Files ready to attach now (chosen in the file panel).
    let onFiles: ([URL]) -> Void
    /// This many photos are on their way from the Photos picker; each then arrives through
    /// `onAdded` (nil when one could not be read), so the strip can show them coming.
    let onBeginAdding: (Int) -> Void
    let onAdded: (URL?) -> Void

    func makeNSView(context: Context) -> PlusButtonView { let view = PlusButtonView(); configure(view); return view }
    func updateNSView(_ view: PlusButtonView, context: Context) { configure(view) }
    private func configure(_ view: PlusButtonView) {
        view.onFiles = onFiles
        view.onBeginAdding = onBeginAdding
        view.onAdded = onAdded
        view.setAccessibilityLabel("Add a photo or file to the message to \(conversationName)")
        view.toolTip = "Photos and files"
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlusButtonView, context: Context) -> CGSize? { CGSize(width: 31, height: 31) }

    final class PlusButtonView: NSView, PHPickerViewControllerDelegate {
        var onFiles: (([URL]) -> Void)?
        var onBeginAdding: ((Int) -> Void)?
        var onAdded: ((URL?) -> Void)?
        private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
        private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
        private var trackingArea: NSTrackingArea?

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

        /// The system Photos picker, in a popover card from this button, as in Messages. It runs
        /// out of process and needs no library permission; chosen items arrive as temporary files,
        /// which are copied into Mosaic's outgoing folder before they vanish. The picker sits in a
        /// host controller of a fixed size: on its own, the popover shrank to the remote view's
        /// minimal fitting size.
        @objc private func pickPhotos() {
            guard let presenter = window?.contentViewController else { return }
            var configuration = PHPickerConfiguration()
            configuration.selectionLimit = 0
            configuration.filter = .any(of: [.images, .videos])
            configuration.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            let host = PhotosPickerCard(picker: picker)
            presenter.present(host, asPopoverRelativeTo: bounds, of: self, preferredEdge: .maxY, behavior: .transient)
        }
        nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            Task { @MainActor in
                if let card = picker.parent as? PhotosPickerCard { card.presentingViewController?.dismiss(card) }
                else { picker.presentingViewController?.dismiss(picker) }
                guard !results.isEmpty else { return }
                // Placeholders at once; the files are fetched all at the same time and each shows
                // up as soon as it lands.
                self.onBeginAdding?(results.count)
                await withTaskGroup(of: URL?.self) { group in
                    for result in results { group.addTask { await Self.file(for: result) } }
                    for await url in group { self.onAdded?(url) }
                }
            }
        }
        /// A picked item's file, kept while its representation exists (it is only valid inside the
        /// handler). The current representation is asked for, so nothing is transcoded.
        nonisolated private static func file(for result: PHPickerResult) async -> URL? {
            let provider = result.itemProvider
            let type = [UTType.image, .movie].first { provider.hasItemConformingToTypeIdentifier($0.identifier) } ?? .data
            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    continuation.resume(returning: url.flatMap { try? OutgoingFiles.keep($0) })
                }
            }
        }

        @objc private func chooseFile() {
            guard let window else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.message = "Choose files to send"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, !panel.urls.isEmpty else { return }
                self?.onFiles?(panel.urls)
            }
        }
    }
}

/// The Photos picker's popover card: a fixed-size host whose only child is the picker. The card
/// is as narrow as Messages' — the picker adds a sidebar of albums once it is wider, which
/// squeezes the grid and its buttons.
final class PhotosPickerCard: NSViewController {
    static let size = NSSize(width: 356, height: 560)
    private let picker: PHPickerViewController
    init(picker: PHPickerViewController) {
        self.picker = picker
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.size
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        addChild(picker)
        picker.view.frame = view.bounds
        picker.view.autoresizingMask = [.width, .height]
        view.addSubview(picker.view)
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
