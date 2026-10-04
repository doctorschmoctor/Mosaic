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

/// Decoded thumbnails, shared by every tile. Decoding happens off the main thread and is never repeated.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()
    private let lock = NSLock()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var failures = Set<String>()

    func image(for attachment: Attachment) async -> NSImage? {
        guard let path = attachment.path else { return nil }
        if let hit = images.object(forKey: path as NSString) { return hit }
        let kind = attachment.kind
        let task: Task<CGImage?, Never>? = lock.withLock {
            if failures.contains(path) { return nil }
            if let running = inFlight[path] { return running }
            let created = Task.detached(priority: .userInitiated) { await ThumbnailCache.render(path: path, kind: kind) }
            inFlight[path] = created
            return created
        }
        guard let task else { return nil }
        let cgImage = await task.value
        lock.withLock {
            inFlight[path] = nil
            if cgImage == nil { failures.insert(path) }
        }
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        images.setObject(image, forKey: path as NSString, cost: cgImage.width * cgImage.height * 4)
        return image
    }

    private static func render(path: String, kind: Attachment.Kind) async -> CGImage? {
        let url = URL(fileURLWithPath: path)
        if kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 900]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 450, height: 450), scale: 2,
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

struct AttachmentView<Extra: View>: View {
    let attachment: Attachment
    /// More items for the context menu (Quote in Reply).
    @ViewBuilder var extraActions: () -> Extra
    @State private var image: NSImage?
    @State private var failed = false
    @Environment(\.zoomScale) private var zoom

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
        .task(id: attachment.path) {
            guard image == nil, attachment.path != nil else { return }
            let loaded = await ThumbnailCache.shared.image(for: attachment)
            image = loaded
            failed = loaded == nil
        }
    }
    private var fileChip: some View {
        HStack(spacing: 9) {
            Image(nsImage: attachment.path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .data))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(attachment.path == nil ? "Not downloaded · Open in Messages" : "Click to open").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Palette.incoming, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .contextMenu { menu }
    }
    @ViewBuilder private var menu: some View {
        if let path = attachment.path {
            Button("Open") { open() }
            Button(attachment.kind == .image ? "Copy Image" : "Copy") { copy() }
            Button("Save to Downloads") { saveToDownloads() }
            Button("Save As…") { saveAs() }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        extraActions()
    }
    private func open() {
        guard let path = attachment.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    /// Puts the file on the pasteboard — as a file, and for a picture as image data too, so it
    /// pastes into another Mosaic composer, Messages, Mail or an image editor alike.
    private func copy() {
        guard let path = attachment.path else { return }
        let url = URL(fileURLWithPath: path)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var items: [NSPasteboardWriting] = [url as NSURL]
        if attachment.kind == .image, let image = NSImage(contentsOf: url) { items.append(image) }
        pasteboard.writeObjects(items)
    }
    private func saveToDownloads() {
        guard let path = attachment.path, let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let destination = SavedFiles.freeName(for: attachment.name, in: downloads)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { NSSound.beep() }
    }
    private func saveAs() {
        guard let path = attachment.path else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
        } catch { NSSound.beep() }
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

struct LinkPreview {
    let title: String?
    let host: String
    let image: NSImage?
    let icon: NSImage?
}

/// Fetches page metadata with LinkPresentation (the framework Messages uses), a few at a time, once per URL.
@MainActor final class LinkPreviewLoader {
    static let shared = LinkPreviewLoader()
    private var cache: [URL: LinkPreview] = [:]
    private var inFlight: [URL: Task<LinkPreview, Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func preview(for url: URL) async -> LinkPreview {
        if let hit = cache[url] { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task { await self.fetch(url) }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        cache[url] = result
        return result
    }

    private func fetch(_ url: URL) async -> LinkPreview {
        if active >= 4 { await withCheckedContinuation { waiting.append($0) } }
        active += 1
        defer {
            active -= 1
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        let provider = LPMetadataProvider()
        provider.timeout = 15
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else {
            return LinkPreview(title: nil, host: Self.host(url), image: nil, icon: nil)
        }
        let image = await Self.loadImage(metadata.imageProvider)
        let icon = image == nil ? await Self.loadImage(metadata.iconProvider) : nil
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkPreview(title: title?.isEmpty == false ? title : nil, host: Self.host(metadata.url ?? url), image: image, icon: icon)
    }

    nonisolated static func host(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private nonisolated static func loadImage(_ provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in continuation.resume(returning: object as? NSImage) }
        }
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
