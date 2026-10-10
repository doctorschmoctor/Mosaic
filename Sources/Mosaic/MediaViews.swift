import SwiftUI
import AppKit
import ImageIO
import LinkPresentation
import QuickLookThumbnailing
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MosaicCore
#endif

// MARK: - Attachments

/// Work several views may wait on at once — one decode or fetch per key, however many rows ask.
/// A view that stops waiting (it went away, or now wants another size) leaves; when the last one
/// leaves, the work is cancelled, so a queued decode never starts and a running fetch is told to
/// stop. A completion that belongs to replaced work never removes its successor.
@MainActor final class SharedRequests<Key: Hashable, Value: Sendable> {
    private struct Entry { let generation: Int; let task: Task<Value, Never>; var consumers: Set<Int> }
    private var entries: [Key: Entry] = [:]
    private var nextID = 0
    /// Keys with work under way (tests).
    var activeCount: Int { entries.count }
    func consumers(of key: Key) -> Int { entries[key]?.consumers.count ?? 0 }

    func value(for key: Key, start: () -> Task<Value, Never>) async -> Value {
        nextID += 1
        let consumer = nextID
        let entry: Entry
        if var existing = entries[key] {
            existing.consumers.insert(consumer)
            entries[key] = existing
            entry = existing
        } else {
            entry = Entry(generation: consumer, task: start(), consumers: [consumer])
            entries[key] = entry
        }
        let value = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor in self.leave(key, consumer: consumer, generation: entry.generation) }
        }
        if entries[key]?.generation == entry.generation { entries[key] = nil }
        return value
    }
    private func leave(_ key: Key, consumer: Int, generation: Int) {
        guard var entry = entries[key], entry.generation == generation, entry.consumers.remove(consumer) != nil else { return }
        if entry.consumers.isEmpty {
            entry.task.cancel()
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }
}

/// Decoded thumbnails, shared by every tile. Decoding happens off the main thread, a few at a
/// time (newest request first: the rows on screen are usually the latest), at the smallest of a
/// few pixel sizes that covers the bubble at the current zoom and screen scale. Entries are keyed
/// by file version, so a picture that finishes downloading is decoded again; one that could not
/// be decoded is retried after `retryInterval`. NSCache's cost limit is a hint, not a hard cap.
@MainActor final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Pixel sizes thumbnails are decoded at.
    nonisolated static let tiers = [320, 640, 1280]
    nonisolated static let retryInterval: TimeInterval = 30
    /// The tier for an image whose longest side is shown at `points` on a screen of `scale`.
    nonisolated static func tier(forPoints points: CGFloat, scale: CGFloat) -> Int {
        let pixels = Int((points * max(1, scale)).rounded(.up))
        return tiers.first { $0 >= pixels } ?? tiers[tiers.count - 1]
    }

    /// A picture's cache key: its path, size tier and file version. Making one reads the file's
    /// metadata, so it is made off the main thread (`resolveKey`).
    struct Key: Hashable {
        let path: String, tier: Int, modified: Date?, size: Int?
        init(path: String, tier: Int) {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            self.init(path: path, tier: tier, modified: values?.contentModificationDate, size: values?.fileSize)
        }
        init(path: String, tier: Int, modified: Date?, size: Int?) {
            self.path = path; self.tier = tier; self.modified = modified; self.size = size
        }
        func with(tier: Int) -> Key { Key(path: path, tier: tier, modified: modified, size: size) }
        var name: NSString { "\(tier)|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(size ?? -1)|\(path)" as NSString }
    }

    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        cache.countLimit = 600
        return cache
    }()
    private var failures = LRUCache<Key, Date>(capacity: 500)
    let requests = SharedRequests<Key, CGImage?>()
    let limiter = AsyncLimiter(limit: 3, order: .newestFirst)
    /// Decodes that ran, whether or not they produced a picture (tests).
    private(set) var decodeCount = 0

    /// The key for a picture, with its file version read off the main thread: a stat can be slow
    /// for a file still arriving from iCloud or on a busy disk, and every bubble asks, cache hit
    /// or not. Only the lookup that follows runs on the main actor.
    nonisolated static func resolveKey(path: String, tier: Int) async -> Key {
        await Task.detached(priority: .userInitiated) { Key(path: path, tier: tier) }.value
    }

    func image(for attachment: Attachment, tier: Int) async -> NSImage? {
        guard let path = attachment.path else { return nil }
        let key = await Self.resolveKey(path: path, tier: tier)
        // The bubble went away while the file was looked at: nothing more to do for it.
        if Task.isCancelled { return nil }
        // The asked size, or a larger one already decoded.
        for candidate in Self.tiers where candidate >= tier {
            if let hit = images.object(forKey: key.with(tier: candidate).name) { return hit }
        }
        if let failed = failures.peek(key), Date().timeIntervalSince(failed) < Self.retryInterval { return nil }
        let kind = attachment.kind
        let limiter = self.limiter
        let cgImage = await requests.value(for: key) {
            Task {
                do {
                    let rendered = try await limiter.run { await ThumbnailCache.render(path: path, kind: kind, pixels: tier) }
                    self.decodeCount += 1
                    return rendered
                } catch {
                    return nil // given up while queued: every view that wanted it went away
                }
            }
        }
        guard let cgImage else {
            // A view that went away did not see a failure; only a finished attempt counts.
            if !Task.isCancelled { failures.insert(Date(), for: key) }
            return nil
        }
        failures.removeValue(for: key)
        if let hit = images.object(forKey: key.name) { return hit }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        images.setObject(image, forKey: key.name, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    private nonisolated static func render(path: String, kind: Attachment.Kind, pixels: Int) async -> CGImage? {
        if Task.isCancelled { return nil }
        let url = URL(fileURLWithPath: path)
        if kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: pixels]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels), scale: 1,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

/// Sizes its content from the available width and a fixed aspect ratio, so a bubble keeps the
/// same height before and after its picture loads (no scroll jumps while thumbnails decode).
struct AspectBox: Layout {
    let ratio: CGFloat
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? maxWidth
        let width = max(48, min(available, maxWidth, maxHeight * ratio))
        return CGSize(width: width, height: (width / ratio).rounded())
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

struct AttachmentView: View {
    let attachment: Attachment
    @State private var image: NSImage?
    @State private var failed = false
    @Environment(\.zoomScale) private var zoom
    @Environment(\.displayScale) private var displayScale
    /// The conversation's other attachments, for Quick Look's next and previous.
    @Environment(\.threadAttachments) private var siblings

    var body: some View {
        switch attachment.kind {
        case .image, .video: visual
        case .audio, .file: fileChip
        }
    }

    private var ratio: CGFloat {
        let fallback: Double = attachment.kind == .video ? 16.0 / 9.0 : 4.0 / 3.0
        let value: Double = attachment.aspectRatio ?? fallback
        return CGFloat(min(3.0, max(0.33, value)))
    }
    private var visual: some View {
        let sticker = attachment.isSticker
        return AspectBox(ratio: ratio, maxWidth: (sticker ? 110 : 240) * zoom, maxHeight: (sticker ? 110 : 300) * zoom) {
            Rectangle().fill(sticker ? Color.clear : Palette.incoming)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .aspectRatio(contentMode: sticker ? .fit : .fill)
                    } else if failed || attachment.path == nil {
                        VStack(spacing: 5) {
                            Image(systemName: attachment.kind == .video ? "video" : "photo").font(.system(size: 18))
                            Text(attachment.path == nil ? "Not downloaded" : "Preview unavailable").font(.system(size: 10))
                        }.foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay {
                    if attachment.kind == .video, image != nil {
                        Image(systemName: "play.circle.fill").font(.system(size: 34)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.35)).shadow(radius: 3)
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: sticker ? 0 : 14 * zoom, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .hoverCursor(.pointingHand, enabled: attachment.path != nil)
        .contextMenu { menu }
        .help(attachment.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachment.kind == .video ? "Video \(attachment.name)" : "Photo \(attachment.name)")
        .accessibilityAddTraits(.isButton)
        .task(id: ThumbnailRequest(path: attachment.path, tier: thumbnailTier)) {
            guard attachment.path != nil else { return }
            let tier = thumbnailTier
            // The picture already shown stays while a sharper one decodes. A file that could not
            // be read yet (still arriving) gets a few more tries.
            for _ in 0..<4 {
                if let loaded = await ThumbnailCache.shared.image(for: attachment, tier: tier) {
                    image = loaded; failed = false
                    return
                }
                if Task.isCancelled { return }
                if image == nil { failed = true }
                try? await Task.sleep(for: .seconds(ThumbnailCache.retryInterval))
                if Task.isCancelled { return }
            }
        }
    }
    private struct ThumbnailRequest: Hashable { let path: String?; let tier: Int }
    /// The decode size for this bubble: its longest side at the current zoom and screen scale.
    private var thumbnailTier: Int {
        let sticker = attachment.isSticker
        let width = min((sticker ? 110 : 240) * zoom, (sticker ? 110 : 300) * zoom * ratio)
        return ThumbnailCache.tier(forPoints: max(width, width / ratio), scale: displayScale)
    }
    private var fileChip: some View {
        HStack(spacing: 9) {
            Image(nsImage: attachment.path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .data))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(attachment.path == nil ? "Not downloaded · Open in Messages" : "Click to preview").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Palette.incoming, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .contextMenu { menu }
    }
    @ViewBuilder private var menu: some View { AttachmentMenuItems(attachment: attachment, siblings: siblings) }
    /// A click previews the file in Quick Look, like Space in the Finder; Open With hands it to its app.
    private func open() { AttachmentActions.quickLook(attachment, among: siblings) }
    static func defaultAppName(for path: String) -> String? { AttachmentActions.defaultAppName(for: path) }
}

/// What can be done with a received file, wherever it is shown (a bubble, the details' media
/// and files): Quick Look, open it in its app, copy, save, show it in the Finder.
struct AttachmentMenuItems: View {
    let attachment: Attachment
    var siblings: [URL] = []
    var body: some View {
        if let path = attachment.path {
            Button("Quick Look") { AttachmentActions.quickLook(attachment, among: siblings) }
            Button("Open With \(AttachmentActions.defaultAppName(for: path) ?? "Default App")") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button(attachment.kind == .image ? "Copy Image" : "Copy") { AttachmentActions.copy(attachment) }
            Button("Save to Downloads") { AttachmentActions.saveToDownloads(attachment) }
            Button("Save As…") { AttachmentActions.saveAs(attachment) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
    }
}

@MainActor enum AttachmentActions {
    /// Previews the file in Quick Look, with the conversation's other files a key press away.
    static func quickLook(_ attachment: Attachment, among siblings: [URL]) {
        guard let path = attachment.path else { return }
        QuickLook.shared.show(URL(fileURLWithPath: path), among: siblings)
    }
    static func defaultAppName(for path: String) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path))
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }
    /// Puts the file on the pasteboard — as a file, and for a picture as image data too, so it
    /// pastes into another Mosaic composer, Messages, Mail or an image editor alike.
    static func copy(_ attachment: Attachment) {
        guard let path = attachment.path else { return }
        let url = URL(fileURLWithPath: path)
        let isImage = attachment.kind == .image
        // The file's bytes are read off the main thread; the pasteboard is written on it.
        Task {
            let data = isImage ? await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value : nil
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            var items: [NSPasteboardWriting] = [url as NSURL]
            if let data, let image = NSImage(data: data) { items.append(image) }
            pasteboard.writeObjects(items)
        }
    }
    static func saveToDownloads(_ attachment: Attachment) {
        guard let path = attachment.path, let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let destination = SavedFiles.freeName(for: attachment.name, in: downloads)
        Task {
            do {
                try await OutgoingFiles.copyInBackground(URL(fileURLWithPath: path), to: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { NSSound.beep() }
        }
    }
    static func saveAs(_ attachment: Attachment) {
        guard let path = attachment.path else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do { try await OutgoingFiles.copyInBackground(URL(fileURLWithPath: path), to: destination, replacing: true) }
            catch { NSSound.beep() }
        }
    }
}

/// Names for files saved out of a conversation.
enum SavedFiles {
    /// `name`, or `name 2`, `name 3`… when the folder already has one.
    static func freeName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}

// MARK: - Link previews

/// Immutable once made (the images are never changed), so it can be handed between tasks.
struct LinkPreview: @unchecked Sendable {
    let title: String?
    let host: String
    let image: NSImage?
    let icon: NSImage?
}

/// Fetches page metadata with LinkPresentation (the framework Messages uses), at most four at a
/// time. Results are kept for the most recent 200 URLs, with images downsampled to the card's
/// size. A failed fetch (offline, timed out) shows the plain host card and is tried again after
/// `failureTTL`. A card that goes away before its fetch starts or finishes gives the fetch up,
/// unless another card for the same URL still waits on it.
@MainActor final class LinkPreviewLoader {
    static let shared = LinkPreviewLoader()
    typealias Fetch = @Sendable (URL) async throws -> LinkPreview
    static let failureTTL: TimeInterval = 300

    private var cache: LRUCache<URL, LinkPreview>
    private var failures = LRUCache<URL, Date>(capacity: 200)
    let requests = SharedRequests<URL, LinkPreview?>()
    let limiter: AsyncLimiter
    private let fetcher: Fetch
    private let now: () -> Date
    /// Fetches that ran to the end, successful or not (tests).
    private(set) var fetchCount = 0
    var cachedCount: Int { cache.count }

    init(capacity: Int = 200, concurrency: Int = 4, now: @escaping () -> Date = Date.init,
         fetch: Fetch? = nil) {
        cache = LRUCache(capacity: capacity)
        limiter = AsyncLimiter(limit: concurrency)
        fetcher = fetch ?? { url in try await LinkPreviewLoader.fetchMetadata(url) }
        self.now = now
    }

    func preview(for url: URL) async -> LinkPreview {
        if let hit = cache.value(for: url) { return hit }
        let fallback = LinkPreview(title: nil, host: Self.host(url), image: nil, icon: nil)
        if let failed = failures.peek(url), now().timeIntervalSince(failed) < Self.failureTTL { return fallback }
        let limiter = self.limiter, fetcher = self.fetcher
        let result = await requests.value(for: url) {
            Task {
                do {
                    let preview = try await limiter.run { try await fetcher(url) }
                    self.fetchCount += 1
                    self.cache.insert(preview, for: url)
                    self.failures.removeValue(for: url)
                    return preview
                } catch {
                    // Given up because no card wants it any more: not a failure to remember.
                    if Task.isCancelled || error is CancellationError { return nil }
                    self.fetchCount += 1
                    self.failures.insert(self.now(), for: url)
                    return nil
                }
            }
        }
        return result ?? fallback
    }

    /// The real fetch. The provider is cancelled when the request is given up.
    static func fetchMetadata(_ url: URL) async throws -> LinkPreview {
        let provider = LPMetadataProvider()
        provider.timeout = 15
        let metadata = try await withTaskCancellationHandler {
            try await provider.startFetchingMetadata(for: url)
        } onCancel: {
            Task { @MainActor in provider.cancel() }
        }
        try Task.checkCancellation()
        func picture(_ image: CGImage?) -> NSImage? { image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
        let image = picture(await Self.loadImage(metadata.imageProvider, maxPixels: 640))
        let icon = image == nil ? picture(await Self.loadImage(metadata.iconProvider, maxPixels: 128)) : nil
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkPreview(title: title?.isEmpty == false ? title : nil, host: Self.host(metadata.url ?? url), image: image, icon: icon)
    }

    nonisolated static func host(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    /// The provider's image, decoded no larger than `maxPixels` on its longest side (a page's
    /// preview image can be several thousand pixels wide; the card is 128 points tall).
    private nonisolated static func loadImage(_ provider: NSItemProvider?, maxPixels: Int) async -> CGImage? {
        guard let provider else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in continuation.resume(returning: data) }
            }
            if let data, let image = downsample(data, maxPixels: maxPixels) { return image }
        }
        guard provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                // A provider without image data: its picture, decoded no larger than asked.
                let image = (object as? NSImage)?.tiffRepresentation.flatMap { downsample($0, maxPixels: maxPixels) }
                continuation.resume(returning: image)
            }
        }
    }
    nonisolated static func downsample(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A fixed-height card, so the conversation never jumps when metadata arrives.
struct LinkPreviewCard: View {
    let url: URL
    @State private var preview: LinkPreview?
    @Environment(\.zoomScale) private var zoom

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.06))
                .frame(height: 128 * zoom)
                .overlay {
                    if let image = preview?.image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else if let icon = preview?.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else if preview == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "safari").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(preview?.title ?? LinkPreviewLoader.host(url)).font(.system(size: 12 * zoom, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(.primary)
                Text(preview?.host ?? LinkPreviewLoader.host(url)).font(.system(size: 10 * zoom)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 62 * zoom, maxHeight: 62 * zoom, alignment: .topLeading)
            .background(Palette.incoming)
        }
        .frame(maxWidth: 250 * zoom)
        .clipShape(RoundedRectangle(cornerRadius: 14 * zoom, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14 * zoom, style: .continuous))
        .onTapGesture { NSWorkspace.shared.open(url) }
        .hoverCursor(.pointingHand)
        .help(url.absoluteString)
        .contextMenu {
            Button("Open Link") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .task(id: url) { preview = await LinkPreviewLoader.shared.preview(for: url) }
    }
}

// MARK: - Demo pictures

/// Draws two original illustrations for the demo workspace so attachments can be shown without real photos.
enum DemoAssets {
    static func imagePaths() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return [render("demo-cabin-v1.png", width: 1200, height: 800, in: directory, draw: drawCabin),
                render("demo-mockup-v1.png", width: 900, height: 1100, in: directory, draw: drawMockup)].compactMap { $0 }
    }

    private static func render(_ name: String, width: Int, height: Int, in directory: URL,
                               draw: (CGContext, CGFloat, CGFloat) -> Void) -> String? {
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context, CGFloat(width), CGFloat(height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }
    /// Fills a polygon given as fractions of the canvas (kept simple so the compiler checks it quickly).
    private static func polygon(_ context: CGContext, _ size: CGSize, _ fractions: [(CGFloat, CGFloat)], _ fill: CGColor) {
        guard let first = fractions.first else { return }
        context.beginPath()
        context.move(to: CGPoint(x: first.0 * size.width, y: first.1 * size.height))
        for point in fractions.dropFirst() { context.addLine(to: CGPoint(x: point.0 * size.width, y: point.1 * size.height)) }
        context.closePath()
        context.setFillColor(fill)
        context.fillPath()
    }
    private static func rect(_ size: CGSize, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
    private static func roundedRect(_ context: CGContext, _ frame: CGRect, radius: CGFloat, _ fill: CGColor) {
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
    }

    private static func drawCabin(_ context: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let size = CGSize(width: w, height: h)
        let skyColors: [CGColor] = [color(250, 205, 160), color(120, 165, 220)]
        let locations: [CGFloat] = [0, 1]
        if let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: skyColors as CFArray, locations: locations) {
            let start = CGPoint(x: 0, y: h * 0.3)
            let end = CGPoint(x: 0, y: h)
            context.drawLinearGradient(sky, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.setFillColor(color(255, 238, 200, 0.95))
        context.fillEllipse(in: CGRect(x: w * 0.66, y: h * 0.56, width: h * 0.17, height: h * 0.17))
        let far: [(CGFloat, CGFloat)] = [(0, 0.38), (0.22, 0.7), (0.42, 0.45), (0.62, 0.74), (0.86, 0.48), (1, 0.6), (1, 0), (0, 0)]
        polygon(context, size, far, color(96, 128, 150))
        let near: [(CGFloat, CGFloat)] = [(0, 0.28), (0.3, 0.42), (0.58, 0.3), (0.8, 0.4), (1, 0.3), (1, 0), (0, 0)]
        polygon(context, size, near, color(58, 102, 78))
        for index in 0..<9 {
            let step = CGFloat(index)
            let left: CGFloat = 0.05 + step * 0.11
            let base: CGFloat = 0.18 + CGFloat(index % 3) * 0.03
            let tree: [(CGFloat, CGFloat)] = [(left, base), (left + 0.035, base + 0.2), (left + 0.07, base)]
            polygon(context, size, tree, color(33, 72, 54))
        }
        context.setFillColor(color(140, 88, 56))
        context.fill(rect(size, 0.4, 0.14, 0.2, 0.16))
        let roof: [(CGFloat, CGFloat)] = [(0.38, 0.3), (0.5, 0.42), (0.62, 0.3)]
        polygon(context, size, roof, color(92, 54, 38))
        context.setFillColor(color(255, 214, 120))
        context.fill(rect(size, 0.43, 0.19, 0.045, 0.06))
        context.setFillColor(color(70, 44, 30))
        context.fill(rect(size, 0.52, 0.14, 0.045, 0.1))
    }

    private static func drawMockup(_ context: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let size = CGSize(width: w, height: h)
        context.setFillColor(color(238, 240, 246))
        context.fill(CGRect(origin: .zero, size: size))
        let card = rect(size, 0.12, 0.06, 0.76, 0.88)
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.15))
        roundedRect(context, card, radius: 46, color(255, 255, 255))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let toolbar = CGRect(x: card.minX + 40, y: card.maxY - 120, width: card.width - 80, height: 70)
        roundedRect(context, toolbar, radius: 18, color(52, 120, 246))
        for row in 0..<6 {
            let shade = CGFloat(row)
            let y: CGFloat = card.maxY - 230 - shade * 120
            context.setFillColor(color(52 + shade * 25, 199 - shade * 12, 89 + shade * 20, 0.9))
            context.fillEllipse(in: CGRect(x: card.minX + 40, y: y, width: 64, height: 64))
            let title = CGRect(x: card.minX + 130, y: y + 36, width: card.width * 0.5, height: 20)
            roundedRect(context, title, radius: 10, color(210, 214, 222))
            let detail = CGRect(x: card.minX + 130, y: y + 6, width: card.width * 0.32, height: 16)
            roundedRect(context, detail, radius: 8, color(230, 232, 238))
        }
    }
}
