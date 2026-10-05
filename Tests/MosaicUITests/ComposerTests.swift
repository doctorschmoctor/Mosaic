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
    /// The script is compiled once and reused: a second preparation returns the same object and
    /// does not compile again. (Nothing is executed, so no message can be sent.)
    @MainActor func testMessagesScriptIsCompiledOnce() throws {
        let first = try MessagesBridge.prepareScript()
        let count = MessagesBridge.compileCount
        let second = try MessagesBridge.prepareScript()
        XCTAssertTrue(first === second)
        XCTAssertEqual(MessagesBridge.compileCount, count)
        XCTAssertEqual(count, 1)
    }
    /// The helper's script is compiled to a file once, out of process; a second request reuses
    /// it. (Nothing is executed, so no message can be sent.)
    @MainActor func testHelperScriptIsCompiledToAFileOnce() async throws {
        let first = try await MessagesBridge.compiledScriptFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let count = MessagesBridge.fileCompileCount
        let second = try await MessagesBridge.compiledScriptFile()
        XCTAssertEqual(first, second)
        XCTAssertEqual(MessagesBridge.fileCompileCount, count)
    }
    /// What a send hands the helper reaches the script as it was typed — a text starting with a
    /// dash, accents, emoji and line breaks — and a refusal comes back with its error number.
    /// A harmless script stands in for Messages' here: it only returns its arguments.
    @MainActor func testHelperPassesArgumentsExactlyAndReportsRefusals() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MosaicHelperTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let echo = folder.appending(path: "echo.scpt")
        let script = ["on run argv", "if item 1 of argv is \"refuse\" then error \"Not allowed.\" number -1743",
                      "return (item 1 of argv) & \"|\" & (item 2 of argv)", "end run"]
        let compiled = try await MessagesBridge.runTool(MessagesBridge.osacompile, ["-o", echo.path] + script.flatMap { ["-e", $0] })
        XCTAssertEqual(compiled.status, 0, compiled.errors)
        let text = "-e café 🙂\nsecond line"
        let ran = try await MessagesBridge.runTool(MessagesBridge.osascript, ["--", echo.path, "sendMessage", text])
        XCTAssertEqual(ran.status, 0, ran.errors)
        XCTAssertEqual(ran.output.trimmingCharacters(in: .newlines), "sendMessage|" + text)
        let refused = try await MessagesBridge.runTool(MessagesBridge.osascript, ["--", echo.path, "refuse", "x"])
        XCTAssertNotEqual(refused.status, 0)
        let reported = MessagesBridge.parseError(refused.errors)
        XCTAssertEqual(reported.number, -1743)
        XCTAssertEqual(reported.message, "Not allowed.")
        XCTAssertTrue(MessagesBridge.failure(message: reported.message, number: reported.number).message.contains("Automation"))
        XCTAssertEqual(MessagesBridge.failure(message: "Can’t get chat id \"x\".", number: -1728).message,
                       "Can’t get chat id \"x\". Your draft has been kept.")
    }
    /// Waiting for the helper leaves the main thread free: work on it keeps running meanwhile.
    @MainActor func testWaitingForTheHelperLeavesTheMainThreadFree() async throws {
        let ticks = MainThreadTicks()
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks.count += 1; try? await Task.sleep(for: .milliseconds(10)) }
        }
        let run = try await MessagesBridge.runTool(URL(fileURLWithPath: "/bin/sleep"), ["0.5"])
        ticker.cancel()
        XCTAssertEqual(run.status, 0)
        XCTAssertGreaterThan(ticks.count, 10, "the main actor ran while the tool was waited for")
    }
    func testHelperErrorTextIsParsed() {
        let parsed = MessagesBridge.parseError("/tmp/Send Messages.scpt: execution error: Messages got an error: Can’t get chat id \"abc\". (-1728)\n")
        XCTAssertEqual(parsed.message, "Messages got an error: Can’t get chat id \"abc\".")
        XCTAssertEqual(parsed.number, -1728)
        XCTAssertEqual(MessagesBridge.parseError("something else").message, "something else")
        XCTAssertNil(MessagesBridge.parseError("something else").number)
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

@MainActor private final class MainThreadTicks { var count = 0 }
