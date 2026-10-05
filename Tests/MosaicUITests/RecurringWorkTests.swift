import XCTest
import AppKit
import MosaicCore
@testable import Mosaic

/// Batch 4: work that recurs while Mosaic runs — polling, media decoding, link previews, row
/// preparation — stays bounded and is not repeated without cause.
final class RecurringWorkTests: XCTestCase {
    func testFallbackPollFollowsActivityAndPendingSends() {
        XCTAssertEqual(RefreshPolicy.pollInterval(appActive: true, awaitingConfirmation: false), .seconds(3))
        XCTAssertEqual(RefreshPolicy.pollInterval(appActive: false, awaitingConfirmation: false), .seconds(15))
        XCTAssertEqual(RefreshPolicy.pollInterval(appActive: false, awaitingConfirmation: true), .seconds(1))
        XCTAssertEqual(RefreshPolicy.pollInterval(appActive: true, awaitingConfirmation: true), .seconds(1))
    }

    /// A writer that never pauses still gets a refresh within the maximum wait; a single write
    /// settles after the short quiet time.
    func testContinuousWritesStillRefreshWithinTheMaximumWait() {
        let start = ContinuousClock.now
        XCTAssertEqual(RefreshPolicy.refreshDeadline(now: start, burstStarted: start), start + RefreshPolicy.settle)
        var deadline = start
        for step in 1...40 { // a write every 50 ms for two seconds
            deadline = RefreshPolicy.refreshDeadline(now: start + .milliseconds(50 * step), burstStarted: start)
            XCTAssertLessThanOrEqual(deadline, start + RefreshPolicy.maxWait)
        }
        XCTAssertEqual(deadline, start + RefreshPolicy.maxWait)
    }

    /// Thumbnails decode at the smallest size that covers the bubble: small screens and zooms get
    /// small images, high zoom stays sharp, and nothing is decoded beyond the largest size.
    func testThumbnailSizeFollowsZoomAndScreenScale() {
        XCTAssertEqual(ThumbnailCache.tier(forPoints: 240, scale: 1), 320)
        XCTAssertEqual(ThumbnailCache.tier(forPoints: 240, scale: 2), 640)
        XCTAssertEqual(ThumbnailCache.tier(forPoints: 240 * 1.6, scale: 2), 1280)
        XCTAssertEqual(ThumbnailCache.tier(forPoints: 110 * 0.8, scale: 2), 320)
        XCTAssertEqual(ThumbnailCache.tier(forPoints: 2000, scale: 2), 1280)
    }

    /// Decoding a picture happens once per size and file version; another size is its own decode,
    /// and a smaller request is served by a larger image already decoded.
    @MainActor func testThumbnailsDecodeOncePerSizeAndFileVersion() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MosaicTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "picture.png")
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:])).write(to: file)
        let attachment = Attachment(id: "a", path: file.path, name: "picture.png", uti: "public.png")
        let cache = ThumbnailCache.shared
        let start = cache.decodeCount
        let large = await cache.image(for: attachment, tier: 640)
        XCTAssertNotNil(large)
        XCTAssertEqual(cache.decodeCount, start + 1)
        _ = await cache.image(for: attachment, tier: 640)
        _ = await cache.image(for: attachment, tier: 320)
        XCTAssertEqual(cache.decodeCount, start + 1, "the same or a smaller size is a cache hit")
        _ = await cache.image(for: attachment, tier: 1280)
        XCTAssertEqual(cache.decodeCount, start + 2)
        // A missing file is not retried at once.
        let missing = Attachment(id: "m", path: folder.appending(path: "absent.png").path, name: "absent.png", uti: "public.png")
        let none = await cache.image(for: missing, tier: 320)
        XCTAssertNil(none)
        let decodesAfterMiss = cache.decodeCount
        _ = await cache.image(for: missing, tier: 320)
        XCTAssertEqual(cache.decodeCount, decodesAfterMiss)
    }

    /// Shared work stops only when every waiting view has left; a view leaving while another still
    /// waits does not cancel it.
    @MainActor func testSharedRequestStopsOnlyWhenEveryConsumerLeaves() async throws {
        let requests = SharedRequests<String, Int?>()
        let started = Counter()
        func start() -> Task<Int?, Never> {
            Task {
                started.value += 1
                do { try await Task.sleep(for: .seconds(30)); return 1 } catch { return nil }
            }
        }
        let first = Task { await requests.value(for: "k", start: start) }
        let second = Task { await requests.value(for: "k", start: start) }
        while requests.consumers(of: "k") < 2 || started.value == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(started.value, 1, "one piece of work for both")
        first.cancel()
        while requests.consumers(of: "k") > 1 { await Task.yield() }
        XCTAssertEqual(requests.activeCount, 1, "the other view still waits")
        second.cancel()
        let clock = ContinuousClock()
        let began = clock.now
        let results = [await first.value, await second.value]
        XCTAssertEqual(results, [nil, nil])
        XCTAssertLessThan(clock.now - began, .seconds(10), "the work was cancelled, not waited out")
        XCTAssertEqual(requests.activeCount, 0)
    }

    /// A picture's key carries its file version, read off the main thread: a picture that
    /// finishes arriving gets a new key (and is decoded again); a missing file has no version.
    @MainActor func testThumbnailKeysFollowTheFileVersion() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MosaicTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "arriving.jpg")
        try Data(repeating: 0, count: 4).write(to: file)
        let partial = await ThumbnailCache.resolveKey(path: file.path, tier: 320)
        XCTAssertEqual(partial.size, 4)
        XCTAssertEqual(partial.tier, 320)
        try Data(repeating: 1, count: 64).write(to: file)
        let complete = await ThumbnailCache.resolveKey(path: file.path, tier: 320)
        XCTAssertEqual(complete.size, 64)
        XCTAssertNotEqual(partial, complete)
        let missing = await ThumbnailCache.resolveKey(path: folder.appending(path: "absent.jpg").path, tier: 640)
        XCTAssertNil(missing.size)
        XCTAssertNil(missing.modified)
    }

    /// Link previews: at most four fetches at once, results kept for a bounded number of URLs, a
    /// failure shown as the plain card and retried only after its time is up.
    @MainActor func testLinkPreviewsAreBoundedAndFailuresRetryLater() async throws {
        let gauge = FetchGauge()
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        let loader = LinkPreviewLoader(capacity: 3, concurrency: 4, now: { now }) { url in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
            if url.host == "offline.example" { throw URLError(.notConnectedToInternet) }
            return LinkPreview(title: url.host, host: url.host ?? "", image: nil, icon: nil)
        }
        let urls = (0..<12).map { URL(string: "https://site\($0).example/page")! }
        let previews = await withTaskGroup(of: LinkPreview.self, returning: [LinkPreview].self) { group in
            for url in urls { group.addTask { await loader.preview(for: url) } }
            var all: [LinkPreview] = []
            for await preview in group { all.append(preview) }
            return all
        }
        XCTAssertEqual(previews.count, 12)
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(loader.cachedCount, 3, "only the most recent URLs are kept")
        XCTAssertEqual(loader.fetchCount, 12)

        let offline = URL(string: "https://offline.example/")!
        let failed = await loader.preview(for: offline)
        XCTAssertNil(failed.title)
        XCTAssertEqual(failed.host, "offline.example")
        XCTAssertEqual(loader.fetchCount, 13)
        _ = await loader.preview(for: offline)
        XCTAssertEqual(loader.fetchCount, 13, "a recent failure is not fetched again")
        now = now.addingTimeInterval(LinkPreviewLoader.failureTTL + 1)
        _ = await loader.preview(for: offline)
        XCTAssertEqual(loader.fetchCount, 14, "after a while it is tried again")
    }

    /// Contact photos are read only when an avatar asks: avatars of one contact share one read,
    /// a few are read at a time, only the most recent are kept, a contact without a photo is not
    /// asked again, and new contacts start over.
    @MainActor func testContactPhotosAreReadOnDemandAndBounded() async {
        let gauge = FetchGauge()
        let photos = ContactPhotos(capacity: 2, concurrency: 2) { id in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
            return id == "nobody" ? nil : tinyPicture()
        }
        XCTAssertEqual(photos.fetchCount, 0, "nothing is read until an avatar asks")
        let shared = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<3 { group.addTask { await photos.image(for: "alex") != nil } }
            var all: [Bool] = []
            for await found in group { all.append(found) }
            return all
        }
        XCTAssertEqual(shared, [true, true, true])
        XCTAssertEqual(photos.fetchCount, 1, "three avatars of one contact, one read")
        XCTAssertNotNil(photos.cachedImage(for: "alex"))
        await withTaskGroup(of: Void.self) { group in
            for id in ["b", "c", "d", "e", "f"] { group.addTask { _ = await photos.image(for: id) } }
        }
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(photos.fetchCount, 6)
        XCTAssertEqual(photos.cachedCount, 2, "only the most recent are kept")
        XCTAssertNil(photos.cachedImage(for: "alex"))
        _ = await photos.image(for: "nobody")
        _ = await photos.image(for: "nobody")
        XCTAssertEqual(photos.fetchCount, 7, "a contact without a photo is asked once")
        photos.reset()
        XCTAssertEqual(photos.cachedCount, 0)
        _ = await photos.image(for: "nobody")
        XCTAssertEqual(photos.fetchCount, 8, "after contacts change it is asked again")
    }

    /// A thread's rows are prepared once per change of its messages or reactions: scrolling,
    /// highlights and resizes render with the same rows.
    @MainActor func testThreadRowsArePreparedOncePerChange() {
        var conversation = DemoData.conversations()[0]
        let presentation = ThreadPresentation()
        let first = presentation.prepared(for: conversation)
        _ = presentation.prepared(for: conversation)
        _ = presentation.prepared(for: conversation)
        XCTAssertEqual(presentation.buildCount, 1)
        XCTAssertEqual(first.rows.map(\.id), MessageRow.rows(for: conversation).map(\.id))
        conversation.name = "Renamed" // not part of the rows
        _ = presentation.prepared(for: conversation)
        XCTAssertEqual(presentation.buildCount, 1)
        conversation.messages.append(Message(id: "9999", text: "One more", date: Date(), isFromMe: true))
        let second = presentation.prepared(for: conversation)
        XCTAssertEqual(presentation.buildCount, 2, "a new message changes the rows")
        XCTAssertEqual(second.rows.last?.message.text, "One more")
    }
}

@MainActor private final class Counter { var value = 0 }

private actor FetchGauge {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

/// A 2×2 picture standing in for a contact's thumbnail.
private func tinyPicture() -> CGImage? {
    let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return context?.makeImage()
}
