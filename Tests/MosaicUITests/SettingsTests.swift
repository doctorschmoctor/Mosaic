import XCTest
import MosaicCore
@testable import Mosaic

/// Settings › Privacy & Data: link previews that can be turned off (then nothing is fetched, not
/// even a request already waiting), clearing the media cache without touching drafts, and
/// clearing every draft at once with one Undo.
final class SettingsTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated { LinkPreviewLoader.shared.allowsFetching = true }
        super.tearDown()
    }
    private func defaults() -> UserDefaults {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// Holds the first fetch until released, and counts every fetch that starts.
    actor Gate {
        private var held: [CheckedContinuation<Void, Never>] = []
        private(set) var started: [URL] = []
        func enter(_ url: URL) async {
            started.append(url)
            if started.count == 1 { await withCheckedContinuation { held.append($0) } }
        }
        func release() { for continuation in held { continuation.resume() }; held = [] }
    }

    @MainActor func testWithPreviewsOffNothingIsFetchedNotEvenAWaitingRequest() async throws {
        let gate = Gate()
        let loader = LinkPreviewLoader(concurrency: 1) { url in
            await gate.enter(url)
            return LinkPreview(title: "Title", host: url.host ?? "", image: nil, icon: nil)
        }
        let a = URL(string: "https://example.com/a")!, b = URL(string: "https://example.com/b")!
        async let first = loader.preview(for: a)
        try await Task.sleep(for: .milliseconds(50))
        async let second = loader.preview(for: b)
        try await Task.sleep(for: .milliseconds(50))
        loader.allowsFetching = false
        await gate.release()
        _ = await first
        let waited = await second
        XCTAssertNil(waited.title, "the waiting request was not fetched")
        let afterwards = await loader.preview(for: URL(string: "https://example.com/c")!)
        XCTAssertNil(afterwards.title)
        let started = await gate.started
        XCTAssertEqual(started, [a], "only the fetch already under way ran")
    }

    @MainActor func testTheLinkPreviewSettingIsKeptAndAppliesEverywhere() {
        let suite = defaults()
        let store = WorkspaceStore(defaults: suite, forceDemo: true)
        XCTAssertEqual(store.linkPreviews, .automatic, "existing users keep automatic previews")
        store.linkPreviews = .off
        XCTAssertFalse(LinkPreviewLoader.shared.allowsFetching)
        XCTAssertEqual(WorkspaceStore(defaults: suite, forceDemo: true).linkPreviews, .off)
        store.linkPreviews = .onClick
        XCTAssertTrue(LinkPreviewLoader.shared.allowsFetching, "On Click fetches when a card asks")
    }

    @MainActor func testClearingTheMediaCacheKeepsDraftsAndWaitingFiles() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let id = store.openIDs[0]
        let file = FileManager.default.temporaryDirectory.appending(path: "MosaicSettings-\(UUID()).txt")
        try Data("x".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        store.workspace.drafts[id] = "keep"
        store.attach([file], to: id)
        store.clearMediaCaches()
        XCTAssertEqual(store.drafts[id], "keep")
        XCTAssertEqual(store.outgoing[id]?.compactMap(\.url), [file])
        XCTAssertEqual(LinkPreviewLoader.shared.cachedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testClearingAllDraftsHasOneUndo() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let a = store.openIDs[0], b = store.openIDs[1]
        store.workspace.drafts[a] = "one"
        store.workspace.drafts[b] = "two"
        let newID = try XCTUnwrap(store.beginNewChat())
        store.workspace.drafts[newID] = "three"
        store.updateDraftSummaries()
        let ids = store.draftRows.map(\.id)
        XCTAssertEqual(Set(ids), [a, b, newID])
        store.discardDrafts(ids)
        XCTAssertTrue(store.draftRows.isEmpty)
        XCTAssertEqual(store.undoNote?.message, "3 drafts cleared")
        store.undoLast()
        XCTAssertEqual(store.drafts[a], "one")
        XCTAssertEqual(store.drafts[b], "two")
        XCTAssertEqual(store.drafts[newID], "three")
        XCTAssertNotNil(store.composeDrafts[newID])
    }
}
