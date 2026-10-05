import AppKit
import SwiftUI

// Focus check: the demo workspace in a real, key window. Opens conversations the ways a person
// does (clicks on list rows, the keyboard in the list, Return in search) and records which view
// holds the keyboard every 20 ms afterwards. Fictional data only; nothing is sent.

@MainActor func describe(_ responder: NSResponder?) -> String {
    switch responder {
    case nil: return "nil"
    case let editor as DraftTextView: return "composer(\(editor.conversationID.prefix(14)))"
    case is NSTableView: return "table"
    case let view as NSView where String(describing: type(of: view)).contains("CatcherView"): return "list-keyboard"
    case let text as NSTextView where text.isFieldEditor: return "search"
    case is NSWindow: return "window"
    default: return String(describing: type(of: responder!))
    }
}

@MainActor final class Tally { var count = 0 }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let store = WorkspaceStore(defaults: UserDefaults(suiteName: "FocusCheck-\(UUID())")!, forceDemo: true)
    let hosting = NSHostingView(rootView: WorkspaceView().environment(store))
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1320, height: 860),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    @MainActor func table() -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(hosting)
    }
    @MainActor func post(_ event: NSEvent?) { if let event { NSApp.postEvent(event, atStart: false) } }
    @MainActor func clickRow(of id: String) -> Bool {
        guard let table = table(), let row = store.filteredConversations.firstIndex(where: { $0.id == id }) else { return false }
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        post(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        post(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.05, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        return true
    }
    @MainActor func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
        let time = ProcessInfo.processInfo.systemUptime
        post(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: time, windowNumber: window.windowNumber,
                              context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        post(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: time, windowNumber: window.windowNumber,
                              context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    /// Which view holds the keyboard over the next `duration`, sampled every 20 ms.
    @MainActor func watch(_ duration: Double = 0.8) async -> [String] {
        var seen: [String] = []
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            let now = describe(window.firstResponder)
            if seen.last != now { seen.append(now) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return seen
    }
    let failures = Tally()
    @MainActor func report(_ name: String, expected: String, _ trace: [String]) {
        let ok = trace.last == "composer(\(expected.prefix(14)))"
        if !ok { failures.count += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name): \(trace.joined(separator: " → "))  [expected composer(\(expected.prefix(14)))]")
        fflush(stdout)
    }

    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        print("key window: \(window.isKeyWindow), active: \(NSApp.isActive), table: \(table() != nil)")
        let all = store.conversations.map(\.id)
        for round in 1...3 {
            print("== round \(round)")
            // A. An open row, nothing focused.
            window.makeFirstResponder(nil)
            var open = store.workspace.openIDs
            _ = clickRow(of: open[1]); report("click open row", expected: open[1], await watch())
            // B. A closed row with free space.
            store.close(open[3]); try? await Task.sleep(for: .milliseconds(200))
            var closed = all.filter { !store.workspace.openIDs.contains($0) }
            _ = clickRow(of: closed[0]); report("click closed row, free space", expected: closed[0], await watch())
            // C. A closed row with every tile taken: it replaces the tile used longest ago.
            open = store.workspace.openIDs
            closed = all.filter { !store.workspace.openIDs.contains($0) }
            _ = clickRow(of: closed[0]); report("click closed row, replacing", expected: closed[0], await watch())
            // D. Typing in one tile, then a closed row.
            store.requestComposerFocus(store.workspace.openIDs[0]); _ = await watch(0.3)
            closed = all.filter { !store.workspace.openIDs.contains($0) }
            _ = clickRow(of: closed[0]); report("click closed row from a composer", expected: closed[0], await watch())
            // E. The list keyboard: ⌘L, ↓ to a closed row, Return.
            NotificationCenter.default.post(name: .focusConversationList, object: nil); _ = await watch(0.3)
            closed = all.filter { !store.workspace.openIDs.contains($0) }
            store.selectSidebarRow(closed[0]); _ = await watch(0.2)
            key(36, "\r"); report("Return on a closed row in the list", expected: closed[0], await watch())
            // F. Return on an open row in the list.
            NotificationCenter.default.post(name: .focusConversationList, object: nil); _ = await watch(0.3)
            let target = store.workspace.openIDs[2]
            store.selectSidebarRow(target); _ = await watch(0.2)
            key(36, "\r"); report("Return on an open row in the list", expected: target, await watch())
            // G. Search, Return.
            NotificationCenter.default.post(name: .focusSearch, object: nil); _ = await watch(0.3)
            let name = store.conversations.first { !store.workspace.openIDs.contains($0.id) }!
            store.search = String(name.name.prefix(5)); _ = await watch(0.3)
            let first = store.filteredConversations.first!.id
            key(36, "\r"); report("Return in search", expected: first, await watch())
            store.search = ""
        }
        print("FAILURES \(failures.count)")
        exit(failures.count == 0 ? 0 : 1)
    }
    app.run()
}
