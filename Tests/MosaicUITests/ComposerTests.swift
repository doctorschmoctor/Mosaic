import XCTest
import AppKit
import MosaicCore
@testable import Mosaic

final class ComposerTests: XCTestCase {
    @MainActor func testReturnRoutesOnlyToItsOwnEditor() throws {
        let first = DraftTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        let second = DraftTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        var sentTo: [String] = []
        first.onSend = { sentTo.append("first") }
        second.onSend = { sentTo.append("second") }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        second.keyDown(with: event)
        XCTAssertEqual(sentTo, ["second"])
        first.keyDown(with: event)
        XCTAssertEqual(sentTo, ["second", "first"])
        let repeatEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36))
        first.keyDown(with: repeatEvent)
        XCTAssertEqual(sentTo, ["second", "first"])
    }
    @MainActor func testShiftReturnInsertsNewlineWithoutSending() throws {
        _ = NSApplication.shared
        let editor = DraftTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        editor.isRichText = false
        var sent = false
        editor.onSend = { sent = true }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        XCTAssertFalse(sent)
        XCTAssertEqual(editor.string, "\n")
    }
    @MainActor func testDemoSendKeepsOtherDraftAndHistoryIntact() async throws {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        let first = store.conversations[0].id
        let second = store.conversations[1].id
        let secondHistory = store.conversations[1].messages
        store.workspace.drafts[first] = "First reply"
        store.workspace.drafts[second] = "Second draft"
        await store.send(first)
        XCTAssertEqual(store.conversations[0].messages.last?.text, "First reply")
        XCTAssertEqual(store.conversations[1].messages, secondHistory)
        XCTAssertEqual(store.workspace.drafts[second], "Second draft")
        XCTAssertEqual(store.workspace.drafts[first], "")
        store.close(second); store.open(second)
        XCTAssertEqual(store.workspace.drafts[second], "Second draft")
    }
    @MainActor func testMessagesSenderScriptCompilesWithoutExecuting() throws {
        _ = try MessagesBridge.prepareScript()
    }
    /// Esc closes a New Message tile and does nothing in any other composer. (The default
    /// NSResponder implementation does not exist; calling it raised an exception.)
    @MainActor func testEscapeOnlyActsWhereTheComposerHasACancelAction() {
        let editor = DraftTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        editor.cancelOperation(nil)
        var cancelled = 0
        editor.onCancel = { cancelled += 1 }
        editor.cancelOperation(nil)
        XCTAssertEqual(cancelled, 1)
    }
}
