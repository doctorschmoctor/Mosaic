import XCTest
import AppKit
import UniformTypeIdentifiers
import MosaicCore
@testable import Mosaic

final class AttachmentTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MosaicTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 6), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    /// A pasted picture is written as its own file (TIFF from the clipboard becomes PNG, a GIF stays
    /// a GIF); at send time a copy is staged in a folder of its own, and old leftovers are purged.
    func testOutgoingFilesStoreStageAndPurge() throws {
        let pending = try temporaryDirectory(), staging = try temporaryDirectory()
        let tiff = try XCTUnwrap(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }.tiffRepresentation)
        let picture = try OutgoingFiles.store(tiff, type: .tiff, in: pending)
        XCTAssertEqual(picture.pathExtension, "png")
        XCTAssertEqual(OutgoingAttachment(url: picture).kind, .image)
        XCTAssertEqual(OutgoingAttachment(url: picture).previewText, "Photo")
        let gif = try OutgoingFiles.store(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), type: .gif, in: pending)
        XCTAssertEqual(gif.pathExtension, "gif")
        XCTAssertEqual(OutgoingAttachment(url: gif).previewText, "GIF")
        let staged = try OutgoingFiles.stage(picture, in: staging)
        XCTAssertEqual(staged.lastPathComponent, picture.lastPathComponent)
        XCTAssertEqual(staged.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path,
                       staging.resolvingSymlinksInPath().path, "each staged file has a folder of its own")
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: picture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path), "the pending copy stays until the message is delivered")
        // Purging removes only what is older than the age given.
        OutgoingFiles.purge(staging, olderThan: 3600, now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        OutgoingFiles.purge(staging, olderThan: 3600, now: Date().addingTimeInterval(7200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        // A pending message carries the file as an attachment with an empty text, which is how the
        // database reports a sent picture, so the real message takes the bubble's place.
        let message = OutgoingAttachment(url: picture).pendingMessage()
        XCTAssertEqual(message.text, "")
        XCTAssertEqual(message.attachments.first?.path, picture.path)
        XCTAssertTrue(message.isFromMe)
    }

    /// The pasteboard: file URLs win, then picture data; plain text is left to the text view.
    @MainActor func testPasteboardContentsAndComposerPaste() throws {
        let directory = try temporaryDirectory()
        let file = directory.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MosaicTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertEqual(OutgoingFiles.contents(of: pasteboard), .files([file]))
        pasteboard.clearContents()
        let png = try pngData()
        pasteboard.setData(png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        XCTAssertEqual(OutgoingFiles.contents(of: pasteboard), .picture(png, .png))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertNil(OutgoingFiles.contents(of: pasteboard))
        // The composer hands both kinds to its callbacks and pastes nothing itself.
        let editor = DraftTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        var files: [URL] = []; var pictures: [UTType] = []
        editor.onAttachFiles = { files = $0 }
        editor.onAttachPicture = { _, type in pictures.append(type) }
        XCTAssertFalse(editor.attach(from: pasteboard))
        pasteboard.clearContents(); pasteboard.writeObjects([file as NSURL])
        XCTAssertTrue(editor.attach(from: pasteboard))
        XCTAssertEqual(files, [file])
        pasteboard.clearContents(); pasteboard.setData(png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        XCTAssertTrue(editor.attach(from: pasteboard))
        XCTAssertEqual(pictures, [.png])
        XCTAssertEqual(editor.string, "")
    }

    /// Files attached to a tile go out with its next message, each as its own bubble before the
    /// text; removing one drops it, and a chosen file is never deleted.
    @MainActor func testAttachmentsGoOutWithTheMessage() async throws {
        let directory = try temporaryDirectory()
        let photo = directory.appending(path: "photo.png"), document = directory.appending(path: "report.pdf")
        try pngData().write(to: photo)
        try Data("%PDF".utf8).write(to: document)
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let id = store.workspace.openIDs[0]
        let before = store.conversations[0].messages.count
        store.attach([photo, document], to: id)
        XCTAssertEqual(store.outgoing[id]?.map(\.name), ["photo.png", "report.pdf"])
        store.attach([photo], to: "not-open")
        XCTAssertNil(store.outgoing["not-open"])
        let documentID = try XCTUnwrap(store.outgoing[id]?[1].id)
        store.removeAttachment(documentID, from: id)
        XCTAssertEqual(store.outgoing[id]?.map(\.name), ["photo.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path), "a chosen file is the user's; only Mosaic's own copies are deleted")
        store.workspace.drafts[id] = "Look at this"
        await store.send(id)
        let messages = store.conversations[0].messages
        XCTAssertEqual(messages.count, before + 2)
        XCTAssertEqual(messages[before].text, "")
        XCTAssertEqual(messages[before].attachments.first?.path, photo.path)
        XCTAssertEqual(messages[before + 1].text, "Look at this")
        XCTAssertNil(store.outgoing[id])
        XCTAssertEqual(store.workspace.drafts[id], "")
        XCTAssertEqual(store.conversations[0].preview, "Look at this")
        // A picture alone is a message too; the sidebar says what it was.
        store.attach([photo], to: id)
        await store.send(id)
        XCTAssertEqual(store.conversations[0].messages.count, before + 3)
        XCTAssertEqual(store.conversations[0].preview, "Photo")
        XCTAssertNil(store.outgoing[id])
    }

    /// Photos from the picker take reserved places in the order chosen, whichever finishes first;
    /// a Return pressed while one is still on its way waits for it, and a photo that could not be
    /// added stops the send with a note rather than being left out quietly.
    @MainActor func testImportsKeepTheirOrderAndASendWaitsForThem() async throws {
        let directory = try temporaryDirectory()
        let first = directory.appending(path: "first.png"), third = directory.appending(path: "third.png")
        try pngData().write(to: first); try pngData().write(to: third)
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let id = store.workspace.openIDs[0]
        let before = store.conversations[0].messages.count
        let slots = store.beginImports(3, to: id)
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(store.outgoing[id]?.map(\.state), [.importing, .importing, .importing])
        // The third finishes first, then the second fails, then the first lands: the order holds.
        store.completeImport(slots[2], url: third, in: id)
        store.completeImport(slots[1], url: nil, in: id)
        XCTAssertEqual(store.outgoing[id]?.map(\.name), ["Photo", "Photo", "third.png"])
        store.workspace.drafts[id] = "Here they are"
        let sendTask = Task { await store.send(id) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.sendNotes[id], "Waiting for photos to finish adding…")
        XCTAssertEqual(store.conversations[0].messages.count, before, "nothing goes out while a photo is still arriving")
        store.completeImport(slots[0], url: first, in: id)
        await sendTask.value
        XCTAssertNil(store.sendNotes[id])
        XCTAssertEqual(store.conversations[0].messages.count, before, "a photo that could not be added stops the send")
        XCTAssertEqual(store.sendErrors[id], "Photo couldn't be added. Remove it or add it again, then send.")
        XCTAssertEqual(store.workspace.drafts[id], "Here they are", "the text is kept")
        // Removing the failed one lets the send go, with the files in the order chosen, then the text.
        store.removeAttachment(slots[1], from: id)
        XCTAssertNil(store.sendErrors[id])
        await store.send(id)
        let messages = store.conversations[0].messages
        XCTAssertEqual(messages.count, before + 3)
        XCTAssertEqual(messages[before].attachments.first?.path, first.path)
        XCTAssertEqual(messages[before + 1].attachments.first?.path, third.path)
        XCTAssertEqual(messages[before + 2].text, "Here they are")
        XCTAssertEqual(messages.suffix(3).map(\.sendState), [.submitted, .submitted, .submitted])
        XCTAssertNil(store.outgoing[id])
        XCTAssertEqual(store.workspace.drafts[id], "")
        // A place in a tile that was closed takes nothing; a file written for it is removed.
        let late = store.beginImports(1, to: id)[0]
        let owned = OutgoingFiles.pendingDirectory.appending(path: "MosaicTest-late-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: OutgoingFiles.pendingDirectory, withIntermediateDirectories: true)
        try pngData().write(to: owned)
        store.close(id)
        store.completeImport(late, url: owned, in: id)
        XCTAssertNil(store.outgoing[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path), "an import for a closed tile is cleaned up")
        XCTAssertTrue(store.beginImports(1, to: "not-open").isEmpty)
    }

    /// Chosen photos are written out a few at a time, starting in the order chosen, and every one
    /// lands at its own place — the ones that could not be written too.
    @MainActor func testPhotoExportsRunAFewAtATimeAndEveryOneLands() async {
        let gauge = ExportGauge()
        let items = (0..<10).map { "photo\($0)" }
        let slots = (0..<10).map { "slot\($0)" }
        var landed: [(slot: String, url: URL?)] = []
        await PhotoLibraryExport.export(items, slots: slots, write: { item in
            await gauge.enter(item)
            try? await Task.sleep(for: .milliseconds(15))
            await gauge.leave()
            return item == "photo4" ? nil : URL(fileURLWithPath: "/tmp/\(item).heic")
        }) { slot, url in landed.append((slot, url)) }
        XCTAssertEqual(Set(landed.map(\.slot)), Set(slots))
        XCTAssertEqual(landed.count, 10)
        XCTAssertNil(landed.first { $0.slot == "slot4" }?.url ?? nil)
        XCTAssertEqual(landed.first { $0.slot == "slot7" }?.url?.lastPathComponent, "photo7.heic")
        let peak = await gauge.peak
        XCTAssertEqual(PhotoLibraryExport.concurrentExports, 3)
        XCTAssertLessThanOrEqual(peak, PhotoLibraryExport.concurrentExports)
        let started = await gauge.order
        XCTAssertEqual(Array(started.prefix(3)).sorted(), ["photo0", "photo1", "photo2"], "the first ones chosen start first")
    }

    /// A finished photo takes its name, or the next free one; it never replaces another file.
    func testFinishedFilesNeverReplaceAnother() throws {
        let folder = try temporaryDirectory()
        let first = folder.appending(path: ".a.partial"), second = folder.appending(path: ".b.partial")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let kept = try XCTUnwrap(OutgoingFiles.moveIntoPlace(first, named: "Stamp FullSizeRender.heic", in: folder))
        let other = try XCTUnwrap(OutgoingFiles.moveIntoPlace(second, named: "Stamp FullSizeRender.heic", in: folder))
        XCTAssertEqual(kept.lastPathComponent, "Stamp FullSizeRender.heic")
        XCTAssertEqual(other.lastPathComponent, "Stamp FullSizeRender 2.heic")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "second")
        XCTAssertNil(OutgoingFiles.moveIntoPlace(folder.appending(path: ".gone.partial"), named: "x.heic", in: folder))
    }

    /// The Photos grid's selection keeps the order chosen, and a video's length reads as in Photos.
    @MainActor func testPhotoLibrarySelectionOrderAndDurations() {
        let model = PhotoLibraryModel()
        XCTAssertTrue(model.selectedIDs.isEmpty)
        model.toggle("b"); model.toggle("a"); model.toggle("c")
        XCTAssertEqual(model.selectedIDs, ["b", "a", "c"])
        XCTAssertTrue(model.isSelected("a"))
        model.toggle("a")
        XCTAssertEqual(model.selectedIDs, ["b", "c"])
        XCTAssertFalse(model.isSelected("a"))
        XCTAssertEqual(PhotoLibraryModel.duration(9), "0:09")
        XCTAssertEqual(PhotoLibraryModel.duration(754), "12:34")
        XCTAssertEqual(PhotoLibraryModel.duration(3725), "1:02:05")
    }

    /// Preheating covers a bounded window around the visible cells, and moving it starts and
    /// stops only the difference.
    func testPhotoPreheatWindowIsBoundedAndMovesByDifference() {
        XCTAssertEqual(PhotoLibraryModel.preheatWindow(visible: 0...8, count: 50_000, margin: 18), 0..<27)
        XCTAssertEqual(PhotoLibraryModel.preheatWindow(visible: 300...320, count: 50_000, margin: 18), 282..<339)
        XCTAssertEqual(PhotoLibraryModel.preheatWindow(visible: 49_990...49_999, count: 50_000, margin: 18), 49_972..<50_000)
        XCTAssertEqual(PhotoLibraryModel.preheatWindow(visible: 0...3, count: 0, margin: 18), 0..<0)
        let moved = PhotoLibraryModel.difference(from: 0..<27, to: 9..<36)
        XCTAssertEqual(moved.added, [27..<36])
        XCTAssertEqual(moved.removed, [0..<9])
        let jumped = PhotoLibraryModel.difference(from: 0..<27, to: 300..<327)
        XCTAssertEqual(jumped.added, [300..<327])
        XCTAssertEqual(jumped.removed, [0..<27])
        let first = PhotoLibraryModel.difference(from: 0..<0, to: 0..<27)
        XCTAssertEqual(first.added, [0..<27])
        XCTAssertTrue(first.removed.isEmpty)
    }

    /// A conversation that is closed or replaced keeps the files waiting in its composer, as it
    /// keeps its text; a New Message tile's files go with it.
    @MainActor func testClosedOrReplacedConversationKeepsItsComposerFiles() throws {
        let directory = try temporaryDirectory()
        let plan = directory.appending(path: "plan.pdf"), note = directory.appending(path: "note.txt")
        try Data("plan".utf8).write(to: plan); try Data("note".utf8).write(to: note)
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let id = store.workspace.openIDs[0]
        store.attach([plan], to: id)
        store.workspace.drafts[id] = "See attached"
        store.close(id)
        XCTAssertEqual(store.outgoing[id]?.map(\.url?.path), [plan.path])
        store.open(id)
        XCTAssertEqual(store.outgoing[id]?.map(\.url?.path), [plan.path])
        XCTAssertEqual(store.workspace.drafts[id], "See attached")
        // Every other tile used since, then a fifth conversation opens in its place.
        for other in store.workspace.openIDs where other != id { store.open(other) }
        let fifth = try XCTUnwrap(store.conversations.map(\.id).first { !store.workspace.openIDs.contains($0) })
        store.open(fifth)
        XCTAssertFalse(store.workspace.openIDs.contains(id), "the tile used longest ago was replaced")
        XCTAssertEqual(store.outgoing[id]?.map(\.url?.path), [plan.path])
        store.open(id)
        XCTAssertEqual(store.outgoing[id]?.map(\.state), [.ready])
        // A New Message tile's files are let go with it (a chosen file itself stays where it is).
        let newID = try XCTUnwrap(store.beginNewChat())
        store.attach([note], to: newID)
        store.close(newID)
        XCTAssertNil(store.outgoing[newID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    }

    /// After a relaunch an unsent New Message is back with its recipients, text and files, a
    /// parked file that went missing is shown as missing and blocks its send, and nothing is sent.
    @MainActor func testUnsentDraftsComeBackAfterRelaunchWithoutSending() async throws {
        let directory = try temporaryDirectory()
        let kept = directory.appending(path: "kept.png"), gone = directory.appending(path: "gone.png")
        try pngData().write(to: kept); try pngData().write(to: gone)
        let defaults = UserDefaults(suiteName: "MosaicTest-\(UUID())")!
        defaults.set(false, forKey: "Mosaic.live")
        let first = WorkspaceStore(defaults: defaults)
        XCTAssertFalse(first.isLive)
        let conversation = first.workspace.openIDs[0]
        first.attach([gone], to: conversation)
        first.close(conversation)
        let newID = try XCTUnwrap(first.beginNewChat())
        first.composeDrafts[newID]?.recipients = [Recipient(address: "+15555550123", name: "Sam")]
        first.workspace.drafts[newID] = "Hi Sam"
        first.attach([kept], to: newID)
        first.persistNow()
        let before = first.conversations.map(\.messages.count)
        try FileManager.default.removeItem(at: gone)

        let second = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(second.workspace.openIDs.contains(newID))
        XCTAssertEqual(second.composeDrafts[newID]?.recipients.map(\.address), ["+15555550123"])
        XCTAssertEqual(second.composeDrafts[newID]?.recipients.map(\.name), ["Sam"])
        XCTAssertEqual(second.workspace.drafts[newID], "Hi Sam")
        XCTAssertEqual(second.outgoing[newID]?.map(\.url?.path), [kept.path])
        XCTAssertEqual(second.outgoing[newID]?.map(\.state), [.ready])
        let missing = try XCTUnwrap(second.outgoing[conversation]?.first)
        XCTAssertTrue(missing.isMissing)
        XCTAssertEqual(second.conversations.map(\.messages.count), before, "nothing is sent at launch")
        XCTAssertTrue(second.conversations.flatMap(\.messages).allSatisfy { $0.sendState == nil })
        // The missing file stops a send from that conversation until it is removed.
        second.open(conversation)
        second.workspace.drafts[conversation] = "Here"
        await second.send(conversation)
        XCTAssertEqual(second.sendErrors[conversation], "gone.png is no longer on this Mac. Remove it, then send.")
        second.removeAttachment(missing.id, from: conversation)
        XCTAssertNil(second.sendErrors[conversation])
    }

    /// Cleanup of Mosaic's outgoing folder leaves alone every file a saved draft points at.
    func testCleanupLeavesFilesASavedDraftPointsAt() throws {
        let directory = try temporaryDirectory()
        let referenced = directory.appending(path: "referenced.png"), stale = directory.appending(path: "stale.png")
        try pngData().write(to: referenced); try pngData().write(to: stale)
        OutgoingFiles.purge(directory, olderThan: 60, now: Date().addingTimeInterval(3600), keeping: [referenced.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// Staging copies off the main thread into a folder of its own, and a refused send's copy can
    /// be removed without touching the original.
    func testStagingCopiesInTheBackgroundAndLeavesTheOriginal() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appending(path: "clip.mov")
        try Data(repeating: 7, count: 4096).write(to: original)
        let staging = directory.appending(path: "staging")
        let staged = try await OutgoingFiles.stageInBackground(original, in: staging)
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: original))
        XCTAssertEqual(staged.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path, staging.standardizedFileURL.path)
        try FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let copy = directory.appending(path: "saved.mov")
        try await OutgoingFiles.copyInBackground(original, to: copy)
        try await OutgoingFiles.copyInBackground(original, to: copy, replacing: true)
        XCTAssertEqual(try Data(contentsOf: copy).count, 4096)
    }

    /// Saving a received picture to Downloads never overwrites: the name gets a number.
    func testSavedAttachmentNamesDoNotCollide() throws {
        let folder = try temporaryDirectory()
        XCTAssertEqual(SavedFiles.freeName(for: "IMG_1.jpg", in: folder).lastPathComponent, "IMG_1.jpg")
        try Data().write(to: folder.appending(path: "IMG_1.jpg"))
        XCTAssertEqual(SavedFiles.freeName(for: "IMG_1.jpg", in: folder).lastPathComponent, "IMG_1 2.jpg")
        try Data().write(to: folder.appending(path: "IMG_1 2.jpg"))
        XCTAssertEqual(SavedFiles.freeName(for: "IMG_1.jpg", in: folder).lastPathComponent, "IMG_1 3.jpg")
        try Data().write(to: folder.appending(path: "notes"))
        XCTAssertEqual(SavedFiles.freeName(for: "notes", in: folder).lastPathComponent, "notes 2")
    }
}

private actor ExportGauge {
    private var current = 0
    private(set) var peak = 0
    private(set) var order: [String] = []
    func enter(_ item: String) { order.append(item); current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
