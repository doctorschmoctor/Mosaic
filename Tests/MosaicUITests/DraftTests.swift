import XCTest
import AppKit
import MosaicCore
@testable import Mosaic

/// Drafts are visible and recoverable: a row says when its composer holds something unsent, the
/// Drafts list holds every draft (closed New Messages included), closing a tile — the × or Esc —
/// keeps its work, reopening finds the same draft, Discard throws away one draft only (and can be
/// taken back), and all of it survives a relaunch without sending anything.
final class DraftTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MosaicDraftTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func defaults() -> UserDefaults {
        let name = "MosaicTest-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
    private func files(_ names: [String]) throws -> [URL] {
        let folder = try temporaryDirectory()
        return try names.map { name in
            let url = folder.appending(path: name)
            try Data(name.utf8).write(to: url)
            return url
        }
    }

    /// Closing a New Message keeps it: its recipients, text and files, in their order. It is in
    /// Drafts, and opening it from there brings back the same draft, not a copy.
    @MainActor func testAClosedNewMessageIsKeptAndReopensAsTheSameDraft() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        store.close(store.openIDs[0])
        let id = try XCTUnwrap(store.beginNewChat())
        store.addRecipient(Recipient(address: "sam@example.test", name: "Sam"), to: id)
        store.workspace.drafts[id] = "Hi Sam"
        let chosen = try files(["plan.pdf", "map.png"])
        store.attach(chosen, to: id)
        store.close(id)

        XCTAssertFalse(store.openIDs.contains(id), "the tile closed")
        XCTAssertEqual(store.composeDrafts[id]?.recipients.map(\.address), ["sam@example.test"])
        XCTAssertEqual(store.drafts[id], "Hi Sam")
        XCTAssertEqual(store.outgoing[id]?.map(\.url), chosen, "the files, in the order they were added")
        let summary = try XCTUnwrap(store.draftSummaries[id])
        XCTAssertEqual(summary.line, "To: Sam · Hi Sam")
        XCTAssertFalse(store.filteredConversations.contains { $0.id == id }, "All lists conversations only")
        store.sidebarFilter = .drafts
        XCTAssertEqual(store.filteredConversations.first?.id, id, "Drafts lists it, the newest first")
        XCTAssertEqual(store.filteredConversations.first?.isComposeDraft, true)
        XCTAssertGreaterThanOrEqual(store.draftCount, 1)

        let drafts = store.composeDrafts.count
        store.pressRow(id)
        XCTAssertTrue(store.openIDs.contains(id), "it opens again, as the same tile")
        XCTAssertEqual(store.composeDrafts.count, drafts, "no copy was made")
        XCTAssertEqual(store.composeDrafts[id]?.recipients.map(\.name), ["Sam"])
        XCTAssertEqual(store.drafts[id], "Hi Sam")
        XCTAssertEqual(store.outgoing[id]?.map(\.url), chosen)
        XCTAssertEqual(store.focusTarget, id, "with someone to send to, the cursor goes to the message")
    }

    /// The × and Esc share one path, and neither erases work: a New Message with anything in it
    /// stays a draft; one nobody touched goes at once.
    @MainActor func testClosingNeverErasesWorkAndAnUntouchedNewMessageGoes() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let untouched = try XCTUnwrap(store.beginNewChat())
        XCTAssertTrue(store.isUntouchedNewMessage(untouched))
        store.close(untouched)
        XCTAssertNil(store.composeDrafts[untouched], "an empty New Message leaves nothing behind")
        XCTAssertNil(store.draftSummaries[untouched])

        let typed = try XCTUnwrap(store.beginNewChat())
        store.workspace.drafts[typed] = "Note to self"
        store.close(typed) // what Esc in its field does
        XCTAssertNotNil(store.composeDrafts[typed])
        XCTAssertEqual(store.draftSummaries[typed]?.line, "No recipients yet · Note to self")

        let addressed = try XCTUnwrap(store.beginNewChat())
        store.addRecipient(Recipient(address: "+15555550199", name: "Riley"), to: addressed)
        store.close(addressed)
        XCTAssertNotNil(store.composeDrafts[addressed], "someone to write to is already work")

        // An ordinary conversation keeps its text and files too.
        let conversation = store.openIDs[0]
        store.workspace.drafts[conversation] = "Running late"
        store.attach(try files(["photo.jpg"]), to: conversation)
        store.close(conversation)
        XCTAssertEqual(store.drafts[conversation], "Running late")
        XCTAssertEqual(store.outgoing[conversation]?.count, 1)
        XCTAssertEqual(store.draftSummaries[conversation]?.line, "Running late")
        store.sidebarFilter = .drafts
        XCTAssertEqual(Set(store.filteredConversations.map(\.id)), [typed, addressed, conversation])
        XCTAssertEqual(store.filteredConversations.last?.id, conversation, "New Messages first, then conversations")
    }

    /// A row says "Draft" with what is waiting: the text's first line, else how many files.
    @MainActor func testRowsSayWhatTheDraftHolds() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let id = store.openIDs[1]
        XCTAssertNil(store.draftSummaries[id])
        store.attach(try files(["a.txt", "b.txt"]), to: id)
        store.updateDraftSummaries()
        XCTAssertEqual(store.draftSummaries[id]?.line, "2 attachments")
        store.workspace.drafts[id] = "First line\nsecond line"
        store.updateDraftSummaries()
        XCTAssertEqual(store.draftSummaries[id]?.line, "First line")
        // Files still on their way in count as a draft too.
        let other = store.openIDs[2]
        _ = store.beginImports(1, to: other)
        store.updateDraftSummaries()
        XCTAssertEqual(store.draftSummaries[other]?.line, "1 attachment")
        // Searching Drafts finds a draft by its own words.
        store.sidebarFilter = .drafts
        store.search = "second line"
        XCTAssertEqual(store.filteredConversations.map(\.id), [id])
    }

    /// Discard throws away one draft only — never a file you chose — and can be taken back for a
    /// few seconds; after that, the pictures Mosaic wrote for it are removed.
    @MainActor func testDiscardRemovesOneDraftAndCanBeUndone() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let a = store.openIDs[0], b = store.openIDs[1]
        let chosen = try files(["chosen.pdf"])[0]
        let written = try OutgoingFiles.store(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), type: .gif, in: store.services.outgoing.pending)
        XCTAssertTrue(store.services.outgoing.owns(written))
        store.workspace.drafts[a] = "Keep me?"
        store.attach([chosen, written], to: a)
        store.workspace.drafts[b] = "Not this one"

        store.discardDraft(a)
        XCTAssertNil(store.drafts[a]); XCTAssertNil(store.outgoing[a])
        XCTAssertNil(store.draftSummaries[a])
        XCTAssertTrue(store.openIDs.contains(a), "a conversation's tile stays open")
        XCTAssertEqual(store.drafts[b], "Not this one", "another draft is untouched")
        XCTAssertEqual(store.undoNote?.message, "Draft discarded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path), "kept while it can be undone")

        store.undoLast()
        XCTAssertNil(store.undoNote)
        XCTAssertEqual(store.drafts[a], "Keep me?")
        XCTAssertEqual(store.outgoing[a]?.map(\.url), [chosen, written])

        store.discardDraft(a)
        store.finishUndoWindow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path), "Mosaic's own copy goes once undo has passed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.path), "a file you chose is never removed")

        // A New Message is discarded whole: its tile closes and it leaves Drafts.
        let id = try XCTUnwrap(store.beginNewChat())
        store.workspace.drafts[id] = "Never mind"
        store.discardDraft(id)
        XCTAssertFalse(store.openIDs.contains(id))
        XCTAssertNil(store.composeDrafts[id])
        XCTAssertNil(store.drafts[id])
        XCTAssertEqual(store.undoNote?.message, "New Message discarded")
        store.undoLast()
        XCTAssertTrue(store.openIDs.contains(id), "undo brings it back where it was")
        XCTAssertEqual(store.drafts[id], "Never mind")
    }

    /// A photo still arriving when its tile closes never lands in another draft; its file is removed.
    @MainActor func testALateImportNeverLandsInAnotherDraft() throws {
        let store = WorkspaceStore(defaults: defaults(), forceDemo: true)
        let a = store.openIDs[0], b = store.openIDs[1]
        let slot = try XCTUnwrap(store.beginImports(1, to: a).first)
        store.close(a)
        XCTAssertNil(store.outgoing[a], "a place still waiting is let go with the tile")
        let late = try OutgoingFiles.store(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), type: .gif, in: store.services.outgoing.pending)
        store.completeImport(slot, url: late, in: b)
        store.completeImport(slot, url: late, in: a)
        XCTAssertNil(store.outgoing[b])
        XCTAssertNil(store.outgoing[a])
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path), "the late file is removed")
    }

    /// After a relaunch every unsent draft is back — a closed New Message with its recipients,
    /// text and files in order, still closed — and nothing was sent.
    @MainActor func testClosedDraftsComeBackAfterRelaunchWithoutSending() throws {
        let suite = defaults()
        suite.set(false, forKey: "Mosaic.live")
        let first = WorkspaceStore(defaults: suite)
        XCTAssertFalse(first.isLive)
        let id = try XCTUnwrap(first.beginNewChat())
        first.addRecipient(Recipient(address: "sam@example.test", name: "Sam"), to: id)
        first.workspace.drafts[id] = "See you at 6"
        let chosen = try files(["one.pdf", "two.pdf"])
        first.attach(chosen, to: id)
        first.close(id)
        let conversation = first.openIDs[0]
        first.workspace.drafts[conversation] = "Unsent"
        first.persistNow()
        let before = first.conversations.map(\.messages.count)

        let second = WorkspaceStore(defaults: suite)
        XCTAssertFalse(second.openIDs.contains(id), "a closed draft comes back closed")
        XCTAssertEqual(second.composeDrafts[id]?.recipients.map(\.name), ["Sam"])
        XCTAssertEqual(second.drafts[id], "See you at 6")
        XCTAssertEqual(second.outgoing[id]?.map(\.url), chosen)
        XCTAssertEqual(second.drafts[conversation], "Unsent")
        second.sidebarFilter = .drafts
        XCTAssertTrue(second.filteredConversations.contains { $0.id == id })
        XCTAssertTrue(second.filteredConversations.contains { $0.id == conversation })
        XCTAssertEqual(second.conversations.map(\.messages.count), before, "nothing is sent at launch")
        XCTAssertTrue(second.conversations.flatMap(\.messages).allSatisfy { $0.sendState == nil })
    }

    /// Records written before drafts had a creation date still load.
    func testOlderSavedDraftsStillDecode() throws {
        let json = #"{"version":1,"files":{"new-1":["/tmp/a.png"]},"newMessages":{"new-1":{"recipients":[{"address":"sam@example.test","name":"Sam"}]}}}"#
        let saved = try JSONDecoder().decode(SavedDrafts.self, from: Data(json.utf8))
        XCTAssertEqual(saved.newMessages["new-1"]?.recipients.map(\.name), ["Sam"])
        XCTAssertNil(saved.newMessages["new-1"]?.created)
        XCTAssertNil(saved.newMessages["new-1"]?.conversationID)
    }
}
