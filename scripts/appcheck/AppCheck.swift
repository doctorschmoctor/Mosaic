import AppKit
import SwiftUI
import CSQLite

// Mosaic as the app runs it — its window and its menus, which SwiftUI keeps up to date through
// the app itself (a test's NSHostingView has no menus). Tiles are closed and opened the reader's
// ways: a header's close button (the pointer over it first), the Workspace menu's Close Focused
// Tile and Reopen Closed Tile, a conversation opened from the sidebar. After each, the tiles drawn
// must be the tiles open, where the layout puts them, within a second and a half. Prints what it
// saw; exits 0 when every step held, 1 when one did not. Fictional conversations only.
//
// Usage: MosaicAppCheck --demo                  the demo workspace
//        MosaicAppCheck --isolated --live       a synthetic Messages database of 200 conversations,
//                                               four with 600 messages, and new messages arriving
//                                               all the while (the store polls and refreshes)
//        add --store-menus                      the Workspace menu as it was before MenuState,
//                                               reading the store's tiles directly

@main enum AppCheckMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--store-menus") { StoreMenusApp.main() } else { CheckApp.main() }
    }
}

@MainActor enum Harness {
    static let suite = "MosaicAppCheck-\(UUID())"
    static let live = CommandLine.arguments.contains("--live")
    static var mode: String {
        (live ? "live" : "demo") + (CommandLine.arguments.contains("--store-menus") ? ", menus that read the store" : "")
    }
    static func makeStore() -> WorkspaceStore {
        let defaults = UserDefaults(suiteName: suite)!
        guard live else { return WorkspaceStore(defaults: defaults, forceDemo: true) }
        return WorkspaceStore(defaults: defaults, database: MessagesDatabase(path: SyntheticMessages.create()))
    }
}

struct CheckApp: App {
    @State private var store = Harness.makeStore()
    @NSApplicationDelegateAdaptor(CheckDelegate.self) private var delegate

    var body: some Scene {
        Window("Mosaic", id: "workspace") {
            WorkspaceView().environment(store)
                .frame(minWidth: 940, minHeight: 620)
                .task { await Check.run(store) }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { WorkspaceCommands(store: store) }
    }
}

/// The app with the Workspace menu as it was before MenuState: its items' states read from the
/// store itself, in the app's body.
struct StoreMenusApp: App {
    @State private var store = Harness.makeStore()
    @NSApplicationDelegateAdaptor(CheckDelegate.self) private var delegate

    var body: some Scene {
        Window("Mosaic", id: "workspace") {
            WorkspaceView().environment(store)
                .frame(minWidth: 940, minHeight: 620)
                .task { await Check.run(store) }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { store.beginNewChat() }.keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Workspace") {
                ForEach(Array(SidebarFilter.allCases.enumerated()), id: \.element) { index, filter in
                    Toggle("Show \(filter.title)", isOn: Binding(get: { store.sidebarFilter == filter },
                                                                set: { if $0 { store.setSidebarFilter(filter) } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                }
                Divider()
                Button("Zoom In") { store.zoomIn() }.keyboardShortcut("=", modifiers: .command).disabled(!store.canZoomIn)
                Button("Zoom Out") { store.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(!store.canZoomOut)
                Button("Actual Size (\(store.zoomLabel))") { store.resetZoom() }.keyboardShortcut("0", modifiers: .command).disabled(store.zoom == 1)
                Divider()
                Group {
                    Button("Move Tile Left") { if !store.moveFocusedTile(by: -1) { NSSound.beep() } }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button("Move Tile Right") { if !store.moveFocusedTile(by: 1) { NSSound.beep() } }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Button("Equal Tile Sizes") { store.equalizeTiles() }
                }
                .disabled(!store.canArrangeTiles)
                Divider()
                Button("Close Focused Tile") { if let id = store.focused?.id { store.close(id) } }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Reopen Closed Tile") { store.reopenLastClosedTile() }.keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!store.canReopenClosedTile)
            }
        }
    }
}

final class CheckDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Never holds up a CI job.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("App check (\(MainActor.assumeIsolated { Harness.mode })): timed out"); exit(2) }
    }
}

/// A Messages database of fictional conversations, and new messages arriving in it.
enum SyntheticMessages {
    static let people = 200
    static let longThreads = 4
    nonisolated(unsafe) static var path = ""
    nonisolated(unsafe) static var arrivals = 0

    static func create() -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MosaicAppCheck-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appending(path: "chat.db").path
        var statements = ["""
        PRAGMA journal_mode=WAL;
        CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT, service_name TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
          is_delivered INTEGER DEFAULT 0, is_read INTEGER DEFAULT 1, error INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0,
          associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT, item_type INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0);
        BEGIN;
        """]
        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        var row = 0
        for person in 1...people {
            statements.append("INSERT INTO handle VALUES ('person\(person)@example.test');")
            statements.append("INSERT INTO chat VALUES ('iMessage;-;person\(person)@example.test', '', 'person\(person)@example.test', 'iMessage');")
            statements.append("INSERT INTO chat_handle_join VALUES (\(person), \(person));")
            let count = person <= longThreads ? 600 : 3
            for index in 0..<count {
                row += 1
                // The long threads are the most recent conversations, so they lead the sidebar.
                let date = now - Int64(person) * 86_400_000_000_000 - Int64(count - index) * 60_000_000_000
                let fromMe = index % 3 == 0
                statements.append("INSERT INTO message (guid, text, date, is_from_me, handle_id) VALUES ('G\(row)', 'Message \(index) in conversation \(person): a few words that wrap across the bubble when the tile is narrow', \(date), \(fromMe ? 1 : 0), \(fromMe ? 0 : person));")
                statements.append("INSERT INTO chat_message_join VALUES (\(person), \(row));")
            }
        }
        statements.append("COMMIT;")
        execute(statements.joined(separator: "\n"))
        return path
    }

    /// A new message from someone whose conversation is not open, as a live account has all the time.
    static func arrive() {
        arrivals += 1
        let person = longThreads + 1 + arrivals % (people - longThreads)
        let date = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        execute("""
        INSERT INTO message (guid, text, date, is_from_me, handle_id, is_read) VALUES ('A\(arrivals)', 'New message \(arrivals)', \(date), 0, \(person), 0);
        INSERT INTO chat_message_join VALUES (\(person), last_insert_rowid());
        """)
    }

    static func execute(_ sql: String) {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { print("App check: database: " + String(cString: sqlite3_errmsg(db))) }
    }
}

@MainActor enum Check {
    static var failures: [String] = []

    static func run(_ store: WorkspaceStore) async {
        if Harness.live {
            // The conversations load; four open, as tiles.
            for _ in 0..<200 where store.conversations.count < SyntheticMessages.people { await pause(0.05) }
            guard store.conversations.count >= SyntheticMessages.people else { return finish("the conversations did not load (\(store.conversations.count))") }
            for person in 1...SyntheticMessages.longThreads {
                if let id = store.conversations.first(where: { $0.participants.contains("person\(person)@example.test") })?.id { store.open(id) }
            }
            // Messages keep arriving in other conversations.
            Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in SyntheticMessages.arrive() }
        }
        await pause(2)
        store.setLayout(.grid)
        await pause(0.8)
        guard let window = NSApp.windows.first(where: { !handles(in: $0.contentView).isEmpty }) else { return finish("no workspace window") }
        guard store.openIDs.count == 4 else { return finish("four tiles expected, \(store.openIDs.count) open") }
        let longest = store.tiles.map(\.messages.count).max() ?? 0
        print("App check (\(Harness.mode)): \(store.openIDs.count) tiles open (up to \(longest) messages loaded), \(store.conversations.count) conversations, a \(Int(window.frame.width))×\(Int(window.frame.height)) window")
        await expectInPlace(store, window, "at launch")

        // A header's close button, the pointer over it first (the top-left tile).
        let first = store.displayOrder[0]
        guard await pressCloseOfTopLeftTile(in: window) else { return finish("no tile header to press") }
        if store.openIDs.contains(first) { failures.append("the close button did not close its tile") }
        await expectInPlace(store, window, "after a tile's close button")

        // The Workspace menu: Close Focused Tile, then Reopen Closed Tile.
        if let focused = store.focused?.id {
            if await perform("Close Focused Tile") {
                if store.openIDs.contains(focused) { failures.append("Close Focused Tile did not close it") }
                await expectInPlace(store, window, "after Close Focused Tile")
            }
            await pause(0.3)
            if await perform("Reopen Closed Tile") {
                if !store.openIDs.contains(focused) { failures.append("Reopen Closed Tile did not reopen it") }
                await expectInPlace(store, window, "after Reopen Closed Tile")
            }
        } else {
            failures.append("no focused tile")
        }

        // A conversation from the sidebar (a row's press opens it and puts the cursor in it).
        await pause(0.3)
        if let other = store.conversations.first(where: { !store.openIDs.contains($0.id) })?.id {
            store.openAndType(other)
            await expectInPlace(store, window, "after opening a conversation from the sidebar")
        }
        // And closing tiles until one is left.
        while store.openIDs.count > 1 {
            await pause(0.3)
            let count = store.openIDs.count
            guard await pressCloseOfTopLeftTile(in: window) else { break }
            await expectInPlace(store, window, "after closing down to \(count - 1)")
        }
        finish(nil)
    }

    static func finish(_ problem: String?) {
        if let problem { failures.append(problem) }
        UserDefaults.standard.removePersistentDomain(forName: Harness.suite)
        if !SyntheticMessages.path.isEmpty { try? FileManager.default.removeItem(atPath: (SyntheticMessages.path as NSString).deletingLastPathComponent) }
        if failures.isEmpty {
            print("App check (\(Harness.mode)): passed")
            exit(0)
        }
        print("App check (\(Harness.mode)): FAILED — " + failures.joined(separator: "; "))
        exit(1)
    }

    static func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    static func handles(in view: NSView?) -> [TileHeaderHandle.HandleView] {
        guard let view else { return [] }
        return (view as? TileHeaderHandle.HandleView).map { [$0] } ?? view.subviews.flatMap { handles(in: $0) }
    }

    /// The tiles drawn are the open tiles, each where the layout puts it: their headers' frames
    /// match the plan's, apart from one offset common to all.
    static func inPlace(_ store: WorkspaceStore, _ window: NSWindow) -> Bool {
        guard let plan = store.tilePlanner?(store.displayOrder) else { return false }
        let planned = store.displayOrder.compactMap { plan.frames[$0] }
            .sorted { ($0.minY.rounded(), $0.minX.rounded()) < ($1.minY.rounded(), $1.minX.rounded()) }
        let drawn = handles(in: window.contentView).map { $0.convert($0.bounds, to: nil) }
            .sorted { (-$0.maxY.rounded(), $0.minX.rounded()) < (-$1.maxY.rounded(), $1.minX.rounded()) }
        guard planned.count == store.openIDs.count, drawn.count == planned.count, let p0 = planned.first, let d0 = drawn.first else { return false }
        for (p, d) in zip(planned, drawn) {
            // Window coordinates grow upward; the plan's grow downward.
            if abs((d.minX - d0.minX) - (p.minX - p0.minX)) > 2 { return false }
            if abs((d.maxY - d0.maxY) + (p.minY - p0.minY)) > 2 { return false }
            if abs((d.width - d0.width) - (p.width - p0.width)) > 2 { return false }
        }
        return true
    }

    static func expectInPlace(_ store: WorkspaceStore, _ window: NSWindow, _ label: String) async {
        let start = Date()
        while Date().timeIntervalSince(start) < 1.5 {
            if inPlace(store, window) {
                print("App check: \(store.openIDs.count) tiles in place \(label) after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                return
            }
            await pause(0.01)
        }
        let drawn = handles(in: window.contentView).map { $0.convert($0.bounds, to: nil) }
        let plan = store.tilePlanner?(store.displayOrder)
        print("App check: tiles NOT in place \(label): \(store.openIDs.count) open, \(drawn.count) drawn")
        print("  drawn headers: " + drawn.map { "(\(Int($0.minX)),\(Int($0.maxY)) \(Int($0.width))w)" }.joined(separator: " "))
        print("  planned: " + store.displayOrder.compactMap { plan?.frames[$0] }.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))w)" }.joined(separator: " "))
        failures.append("tiles not in place \(label)")
        // Whether they get there later, and when.
        while Date().timeIntervalSince(start) < 6 {
            if inPlace(store, window) {
                print("  …in place after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                return
            }
            await pause(0.05)
        }
        print("  …still not in place after 6 s")
    }

    /// The pointer goes over the close button of the top-left tile's header (it shows its hover
    /// state), then presses and releases it, as the reader does.
    static func pressCloseOfTopLeftTile(in window: NSWindow) async -> Bool {
        let all = handles(in: window.contentView)
        guard let handle = all.min(by: { a, b in
            let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
            return (-fa.maxY.rounded(), fa.minX.rounded()) < (-fb.maxY.rounded(), fb.minX.rounded())
        }) else { return false }
        let point = handle.convert(NSPoint(x: handle.closeRect.midX, y: handle.closeRect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .mouseMoved ? 0 : 1)
        }
        guard let moved = event(.mouseMoved), let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        handle.mouseEntered(with: moved)
        await pause(0.15)
        handle.mouseDown(with: down)
        await pause(0.05)
        handle.mouseUp(with: up)
        return true
    }

    /// Chooses a menu bar item by its title, as a click on it would (the menu is brought up to
    /// date first, as opening it does); false when it is missing or stays unavailable.
    static func perform(_ title: String) async -> Bool {
        func find(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.title == title { return (menu, index) }
                if let submenu = item.submenu, let hit = find(in: submenu) { return hit }
            }
            return nil
        }
        let start = Date()
        while true {
            guard let main = NSApp.mainMenu, let (menu, index) = find(in: main) else {
                failures.append("no menu item \(title)")
                return false
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            if menu.items[index].isEnabled {
                print("App check: \(title) available after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                menu.performActionForItem(at: index)
                return true
            }
            if Date().timeIntervalSince(start) > 1.5 {
                print("App check: \(title) unavailable in the menu bar")
                failures.append("\(title) is unavailable")
                return false
            }
            await pause(0.05)
        }
    }
}
