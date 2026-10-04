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
        while requests.consumers(of: "k") < 2 { await Task.yield() }
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
