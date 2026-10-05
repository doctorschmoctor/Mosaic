import XCTest
import AppKit
import SwiftUI
import MosaicCore
@testable import Mosaic

/// The workspace hosted in a real window: a press on a tile's message field reaches the field and
/// gives it the keyboard, and typing lands in it — after a conversation opens, after a tile is
/// chosen (a chip, in Focus), in every layout and in every row.
final class FocusLayoutTests: XCTestCase {
    @MainActor private struct Host {
        let store: WorkspaceStore
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
    }

    @MainActor private func makeHost(layout: WorkspaceLayout) -> Host {
        _ = NSApplication.shared
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicTest-\(UUID())")!, forceDemo: true)
        store.setLayout(layout)
        let hosting = NSHostingView(rootView: AnyView(WorkspaceView().environment(store).frame(width: 1320, height: 860)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return Host(store: store, window: window, hosting: hosting)
    }
    @MainActor private func tearDown(_ host: Host) {
        host.hosting.rootView = AnyView(EmptyView())
        host.window.close()
    }
    /// Lets SwiftUI, AppKit and the deferred focus requests run.
    @MainActor private func settle(_ host: Host, for seconds: Double = 1.0) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            host.hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor private func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        guard let view = responder as? NSView else { return String(describing: type(of: responder)) }
        let id = (view as? DraftTextView).map { " for \($0.conversationID)" } ?? ""
        return "\(type(of: view))\(id) at \(view.convert(view.bounds, to: nil).integral) in window \(view.window?.windowNumber ?? -1)"
    }
    /// The view a press at the field's center reaches: what the window hands a click to.
    @MainActor private func viewUnderPress(on editor: DraftTextView, in host: Host) -> NSView? {
        let center = editor.convert(NSPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: nil)
        return host.hosting.superview.flatMap { host.hosting.hitTest($0.convert(center, from: nil)) }
    }
    @MainActor private func typeKeys(_ text: String, in host: Host) {
        for character in text {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: host.window.windowNumber, context: nil, characters: String(character),
                                         charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)!
            host.window.sendEvent(event)
        }
    }
    /// The tile's field is in the window and a press on it reaches it (in a test window no press
    /// can take the keyboard — the window is never key — so the keyboard is checked where it is
    /// given by the app itself).
    @MainActor private func assertFieldTakesPresses(for id: String, in host: Host, _ note: String) async throws -> DraftTextView {
        let editor = try XCTUnwrap(DraftTextView.editor(for: id), "\(note): the tile has a message field")
        XCTAssertTrue(editor.window === host.window, "\(note): the field is in the window")
        let hit = viewUnderPress(on: editor, in: host)
        XCTAssertTrue(hit === editor, "\(note): a press on the field reaches it — it reached \(describe(hit)); the field is \(describe(editor))")
        return editor
    }

    @MainActor private func check(layout: WorkspaceLayout) async throws {
        let host = makeHost(layout: layout)
        defer { tearDown(host) }
        try await settle(host, for: 1.5)
        let store = host.store
        // A conversation that is not open takes the place of the tile used longest ago; the
        // keyboard goes to its field by itself, a press reaches the field, and typing lands in it.
        let closed = try XCTUnwrap(store.conversations.map(\.id).first { !store.openIDs.contains($0) })
        store.openAndType(closed)
        try await settle(host, for: 1.5)
        XCTAssertEqual(store.focused?.id, closed)
        let opened = try await assertFieldTakesPresses(for: closed, in: host, "[\(layout)] the opened conversation")
        XCTAssertTrue(host.window.firstResponder === opened, "[\(layout)] opening a conversation puts the keyboard in its field; it is in \(describe(host.window.firstResponder))")
        typeKeys("hi", in: host)
        try await settle(host, for: 0.2)
        XCTAssertEqual(store.drafts[closed], "hi", "[\(layout)] typing lands in the opened conversation's field")
        // Another open tile, chosen as a chip chooses it in Focus: in Grid the last tile is in the
        // bottom row, where the canvas ends; in Columns the second one is within the window.
        let other = try XCTUnwrap(layout == .columns ? store.openIDs.dropFirst().first : store.openIDs.last { $0 != closed })
        store.focus(other)
        try await settle(host, for: 1.0)
        XCTAssertEqual(store.focused?.id, other)
        _ = try await assertFieldTakesPresses(for: other, in: host, "[\(layout)] the chosen tile")
    }

    @MainActor func testFocusLayoutFieldsTakePressesAndTheKeyboard() async throws { try await check(layout: .focus) }
    @MainActor func testGridLayoutFieldsTakePressesAndTheKeyboard() async throws { try await check(layout: .grid) }
    @MainActor func testColumnsLayoutFieldsTakePressesAndTheKeyboard() async throws { try await check(layout: .columns) }
}
