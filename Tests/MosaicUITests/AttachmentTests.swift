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
