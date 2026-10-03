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

    /// Photos from the picker arrive behind placeholders; a Return pressed while one is still on
    /// its way waits for it, so the message goes out with the photo rather than without.
    @MainActor func testArrivingPhotosShowPlaceholdersAndSendWaitsForThem() async throws {
        let directory = try temporaryDirectory()
        let photo = directory.appending(path: "photo.png")
        try pngData().write(to: photo)
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let id = store.workspace.openIDs[0]
        let before = store.conversations[0].messages.count
        store.beginAddingAttachments(2, to: id)
        XCTAssertEqual(store.outgoingLoading[id], 2)
        store.finishAddingAttachment(nil, to: id)
        XCTAssertEqual(store.outgoingLoading[id], 1, "one that could not be read just goes away")
        XCTAssertNil(store.outgoing[id])
        Task { try? await Task.sleep(for: .milliseconds(150)); store.finishAddingAttachment(photo, to: id) }
        store.workspace.drafts[id] = "Here it is"
        await store.send(id)
        XCTAssertNil(store.outgoingLoading[id])
        let messages = store.conversations[0].messages
        XCTAssertEqual(messages.count, before + 2)
        XCTAssertEqual(messages[before].attachments.first?.path, photo.path, "the late photo went out first")
        XCTAssertEqual(messages[before + 1].text, "Here it is")
        XCTAssertNil(store.outgoing[id])
        store.beginAddingAttachments(1, to: "not-open")
        XCTAssertNil(store.outgoingLoading["not-open"])
    }
}
