import XCTest
import MosaicCore
@testable import Mosaic

/// Photos on their way into a composer: progress when Photos reports it, Stop, Retry where the
/// item can be asked for again, and a preview of ready files in the composer's order.
final class ImportTests: XCTestCase {
    /// A stand-in for Photos: each identifier behaves as the test says.
    final class FakePhotos: @unchecked Sendable {
        private let lock = NSLock()
        private var _available: Set<String> = []
        private var _requests: [String] = []
        let folder: URL
        init(folder: URL) { self.folder = folder }
        var available: Set<String> { get { lock.lock(); defer { lock.unlock() }; return _available } set { lock.lock(); _available = newValue; lock.unlock() } }
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
        func export(_ identifier: String, _ progress: @escaping @Sendable (Double) -> Void) async -> URL? {
            lock.lock(); _requests.append(identifier); let ok = _available.contains(identifier); lock.unlock()
            if identifier.hasPrefix("slow") {
                // Takes long enough for the test to stop it; a file is still written if it is not.
                try? await Task.sleep(for: .seconds(1))
            }
            progress(0.5)
            try? await Task.sleep(for: .milliseconds(30))
            guard ok else { return nil }
            let url = folder.appending(path: "\(identifier)-\(UUID().uuidString).heic")
            try? Data(identifier.utf8).write(to: url)
            return url
        }
    }

    @MainActor private func store() -> WorkspaceStore {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return WorkspaceStore(defaults: UserDefaults(suiteName: name)!, forceDemo: true)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor func testPhotosArriveInOrderAndAFailedOneCanBeTriedAgain() async throws {
        let store = store()
        let photos = FakePhotos(folder: store.services.outgoing.pending)
        try FileManager.default.createDirectory(at: store.services.outgoing.pending, withIntermediateDirectories: true)
        photos.available = ["a", "c"]
        store.exportPhoto = { identifier, progress in await photos.export(identifier, progress) }
        store.photoExists = { _ in true }
        let id = store.openIDs[0]
        store.importPhotos(["a", "b", "c"], to: id)
        XCTAssertEqual(store.outgoing[id]?.map(\.state), [.importing, .importing, .importing], "each has its place at once")
        try await wait { store.outgoing[id]?.contains { $0.state == .importing } == false }
        let files = try XCTUnwrap(store.outgoing[id])
        XCTAssertEqual(files.map(\.state.isFailed), [false, true, false], "the order chosen, whatever finished first")
        XCTAssertTrue(files[1].canRetry, "a Photos item can be asked for again")
        XCTAssertNil(files[0].progress, "a finished file shows no progress")

        // Photos has it now: Retry adds it in its place.
        photos.available.insert("b")
        store.retryImport(files[1].id, in: id)
        XCTAssertEqual(store.outgoing[id]?[1].state, .importing)
        try await wait { store.outgoing[id]?[1].state == .ready }
        XCTAssertEqual(store.outgoing[id]?.map(\.state), [.ready, .ready, .ready])
        XCTAssertEqual(store.outgoing[id]?.map(\.id), files.map(\.id), "the same places, in the same order")
        XCTAssertEqual(store.readyOutgoingURLs(id).count, 3, "Quick Look steps through them in the composer's order")
        XCTAssertEqual(store.readyOutgoingURLs(id), store.outgoing[id]?.compactMap(\.url))

        // An item gone from the library is not retried.
        photos.available = []
        store.importPhotos(["d"], to: id)
        try await wait { store.outgoing[id]?.last?.state.isFailed == true }
        let gone = try XCTUnwrap(store.outgoing[id]?.last)
        store.photoExists = { _ in false }
        store.retryImport(gone.id, in: id)
        XCTAssertEqual(store.outgoing[id]?.last?.state, .failed("This item is no longer in your Photos library."))
        XCTAssertFalse(store.outgoing[id]?.last?.canRetry ?? true, "Retry is offered only when it could work")
    }

    @MainActor func testStoppingAnImportStopsItsExportAndNothingLandsLate() async throws {
        let store = store()
        let photos = FakePhotos(folder: store.services.outgoing.pending)
        try FileManager.default.createDirectory(at: store.services.outgoing.pending, withIntermediateDirectories: true)
        photos.available = ["slow-1", "slow-2"]
        store.exportPhoto = { identifier, progress in await photos.export(identifier, progress) }
        let id = store.openIDs[0], other = store.openIDs[1]
        store.importPhotos(["slow-1"], to: id)
        store.importPhotos(["slow-2"], to: other)
        let slot = try XCTUnwrap(store.outgoing[id]?.first?.id)
        store.removeAttachment(slot, from: id)
        XCTAssertNil(store.outgoing[id], "stopped at once")
        try await wait { store.outgoing[other]?.first?.state == .ready }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.outgoing[id], "the stopped one never lands")
        XCTAssertEqual(store.outgoing[other]?.count, 1, "nor in another composer")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.services.outgoing.pending.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("slow-1") }, "a file written for a stopped place is removed")
    }
}
