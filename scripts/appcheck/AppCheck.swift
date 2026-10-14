import AppKit
import SwiftUI
import QuartzCore
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
    @State private var store: WorkspaceStore = {
        // Parts of each message switched off, to see what scrolling costs with them (the app check script compares).
        if CommandLine.arguments.contains("--no-row-geometry") { ThreadRenderingProbe.rowGeometry = false }
        if CommandLine.arguments.contains("--no-context-menus") { ThreadRenderingProbe.contextMenus = false }
        return Harness.makeStore()
    }()
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

    /// Prints what the tile area does (TileTrace) from now until `untrace`, with the time since.
    static func trace(_ label: String) {
        let start = Date()
        print("  trace: \(label)")
        TileTrace.sink = { message in print("    +\(Int(Date().timeIntervalSince(start) * 1000)) ms \(message)") }
    }
    static func untrace() { TileTrace.sink = nil }

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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await pause(0.3)
        print("App check: app active \(NSApp.isActive), window key \(window.isKeyWindow), main \(window.isMainWindow)")
        guard store.openIDs.count == 4 else { return finish("four tiles expected, \(store.openIDs.count) open") }
        let longest = store.tiles.map(\.messages.count).max() ?? 0
        print("App check (\(Harness.mode)): \(store.openIDs.count) tiles open (up to \(longest) messages loaded), \(store.conversations.count) conversations, a \(Int(window.frame.width))×\(Int(window.frame.height)) window")
        await expectInPlace(store, window, "at launch")

        // A fast scroll up a long thread, measured (live only: the demo's threads are short).
        if Harness.live && !CommandLine.arguments.contains("--store-menus") {
            await ScrollBenchmark.run(store, window)
            if CommandLine.arguments.contains("--scroll-only") { return finish(nil) }
        }

        // A fast drag around the grid, measured.
        if !CommandLine.arguments.contains("--store-menus") {
            await DragBenchmark.run(store, window)
            await expectInPlace(store, window, "after the drag")
        }

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
            trace("opening a conversation from the sidebar")
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
                untrace()
                print("App check: \(store.openIDs.count) tiles in place \(label) after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                return
            }
            await pause(0.01)
        }
        untrace()
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
        trace("pressing a tile's close button")
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
                trace("choosing \(title)")
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


/// The display's frames and the main thread's busy stretches while something runs: a display
/// link's callbacks come on the main thread, so a frame the main thread was too busy for shows
/// up as a gap between two callbacks.
@MainActor final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private(set) var stamps: [CFTimeInterval] = []
    /// When the main thread woke and when it went back to waiting.
    private(set) var busy: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var woke: CFTimeInterval = 0

    func start(in view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { self.woke = now } else if self.woke > 0 { self.busy.append((self.woke, now)); self.woke = 0 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }
    @objc private func tick(_ link: CADisplayLink) { stamps.append(link.timestamp) }
    func stop() {
        link?.invalidate(); link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
    /// The usual time between frames, the frames missed (a gap of n frames misses n − 1), and the
    /// longest gap, from `since` on.
    func frames(from start: CFTimeInterval = 0, to end: CFTimeInterval = .infinity) -> (interval: Double, count: Int, missed: Int, longest: Double) {
        let stamps = self.stamps.filter { $0 >= start && $0 <= end }
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }.filter { $0 > 0 }
        guard !gaps.isEmpty else { return (0, 0, 0, 0) }
        let interval = gaps.sorted()[gaps.count / 2]
        let missed = gaps.reduce(0) { $0 + max(0, Int(($1 / interval).rounded()) - 1) }
        return (interval, gaps.count + 1, missed, gaps.max() ?? 0)
    }
}

/// Drags measured: the top-left tile is picked up by its header and carried — first in small
/// circles inside its own place (only the held tile moves), then fast around the grid, over each
/// of the other tiles and back, a quarter of a second for each stretch (the others make way) —
/// with the pointer moving at 120 Hz, then let go. Prints how the frames kept up, what was
/// redone, and what the main thread was doing in its longest stretches.
@MainActor enum DragBenchmark {
    static func run(_ store: WorkspaceStore, _ window: NSWindow) async {
        let headers = Check.handles(in: window.contentView).map { ($0, $0.convert($0.bounds, to: nil)) }
            .sorted { (-$0.1.maxY.rounded(), $0.1.minX.rounded()) < (-$1.1.maxY.rounded(), $1.1.minX.rounded()) }
        guard headers.count == 4 else { print("Drag benchmark: four tile headers expected, found \(headers.count)"); return }
        // Where the pointer goes: the middle of each header (left of the close button), top-left first.
        func spot(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.minX + frame.width * 0.4, y: frame.midY) }
        let tl = spot(headers[0].1), tr = spot(headers[1].1), bl = spot(headers[2].1), br = spot(headers[3].1)
        // Circles of 24 points around a spot a little inside the tile, never reaching another tile.
        let circle = (0...24).map { step -> CGPoint in
            let angle = Double(step) / 24 * 2 * .pi
            return CGPoint(x: tl.x + 30 + 24 * cos(angle), y: tl.y - 40 + 24 * sin(angle))
        }
        await measure(store, window, headers[0].0, label: "held tile only", path: [tl] + circle + circle, leg: 0.03)
        await Check.pause(0.5)
        let fresh = Check.handles(in: window.contentView).map { ($0, $0.convert($0.bounds, to: nil)) }
            .sorted { (-$0.1.maxY.rounded(), $0.1.minX.rounded()) < (-$1.1.maxY.rounded(), $1.1.minX.rounded()) }
        await measure(store, window, fresh[0].0, label: "around the grid", path: [tl, tr, br, bl, tl, br, tr, bl, tl], leg: 0.25)
    }

    static func measure(_ store: WorkspaceStore, _ window: NSWindow, _ handle: TileHeaderHandle.HandleView,
                        label: String, path: [CGPoint], leg: Double) async {
        guard let content = window.contentView else { return }
        let total = leg * Double(path.count - 1)
        func position(_ t: Double) -> CGPoint {
            let index = min(Int(t / leg), path.count - 2)
            let f = min(1, (t - Double(index) * leg) / leg)
            let a = path[index], b = path[index + 1]
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let kinds = ["workspace plans", "canvas places", "tile body", "motion body", "held order changes", "refresh applies", "drag begins", "drag ends", "picture taken", "move"]
        var notes: [(time: CFTimeInterval, kind: String)] = []
        TileTrace.sink = { message in
            if message.hasPrefix("picture taken") { print("  " + message) }
            notes.append((CACurrentMediaTime(), kinds.first { message.hasPrefix($0) } ?? "other"))
        }
        let recorder = FrameRecorder()
        recorder.start(in: content)
        await Check.pause(0.3)
        handle.mouseDown(with: event(.leftMouseDown, path[0]))
        let moves = MoveTimes()
        let begin = CACurrentMediaTime()
        // The pointer, as the window server delivers it: one move per 1/120 s, or the latest one
        // when the main thread could not keep up.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(0))
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    let t = CACurrentMediaTime() - begin
                    guard t < total else { timer.cancel(); done.resume(); return }
                    let start = CACurrentMediaTime()
                    notes.append((start, "move"))
                    handle.mouseDragged(with: event(.leftMouseDragged, position(t)))
                    moves.add(CACurrentMediaTime() - start)
                }
            }
            timer.resume()
        }
        let end = CACurrentMediaTime()
        handle.mouseUp(with: event(.leftMouseUp, position(total)))
        await Check.pause(1.0)
        recorder.stop()
        TileTrace.sink = nil
        let dragged = recorder.frames(from: begin, to: end)
        let all = recorder.frames(from: begin)
        let frame = dragged.interval
        let stretches = recorder.busy.filter { $0.end >= begin && $0.end - $0.start > frame * 1.05 }
        let duringDrag = recorder.busy.filter { $0.start >= begin && $0.end <= end }
        let busyShare = duringDrag.reduce(0) { $0 + ($1.end - $1.start) } / max(end - begin, 0.001)
        func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }
        let orderChanges = notes.filter { $0.kind == "held order changes" && $0.time <= end }.count
        print("Drag benchmark (\(Harness.mode), \(label)): \(moves.count) pointer moves in \(String(format: "%.2f", end - begin)) s, \(orderChanges) order changes; each move took \(ms(moves.average)) on average, \(ms(moves.longest)) at most")
        print("  while dragging: \(dragged.count) frames of \(ms(frame)), \(dragged.missed) missed, longest gap \(ms(dragged.longest)); the main thread was busy \(Int(busyShare * 100))% of the time, longer than a frame \(stretches.filter { $0.start <= end }.count) times")
        print("  with the drop's settling: \(all.count) frames, \(all.missed) missed, longest gap \(ms(all.longest))")
        func tally(_ from: CFTimeInterval, _ to: CFTimeInterval) -> String {
            var counts: [String: Int] = [:]
            for note in notes where note.time >= from && note.time <= to { counts[note.kind, default: 0] += 1 }
            return kinds.compactMap { kind in counts[kind].map { "\(kind) \($0)" } }.joined(separator: ", ")
        }
        print("  redone: " + tally(begin, .infinity))
        for stretch in stretches.sorted(by: { $0.end - $0.start > $1.end - $1.start }).prefix(8) {
            let phase = stretch.start > end ? "after the drop" : "dragging"
            print("  stretch of \(ms(stretch.end - stretch.start)) at +\(Int((stretch.start - begin) * 1000)) ms (\(phase)): " + tally(stretch.start, stretch.end))
        }
        if store.heldTile != nil { Check.failures.append("a tile is still held after the drag (\(label))") }
        guard label == "around the grid" else { return }
        print("  order now \(store.openIDs == store.displayOrder ? "committed" : "not committed")")
        // What a picture of one tile costs to make (for dragging a picture instead of the tile).
        if let plan = store.tilePlanner?(store.displayOrder), let id = store.displayOrder.first, let tile = plan.frames[id],
           let header = Check.handles(in: content).map({ $0.convert($0.bounds, to: content) }).min(by: { ($0.minY.rounded(), $0.minX.rounded()) < ($1.minY.rounded(), $1.minX.rounded()) }) {
            let rect = CGRect(x: header.minX, y: content.isFlipped ? header.minY : header.maxY - tile.height, width: tile.width, height: tile.height)
            var times: [String] = []
            for _ in 0..<3 {
                let start = CACurrentMediaTime()
                if let rep = content.bitmapImageRepForCachingDisplay(in: rect) { content.cacheDisplay(in: rect, to: rep) }
                times.append(ms(CACurrentMediaTime() - start))
            }
            print("  a picture of a \(Int(tile.width))×\(Int(tile.height)) tile: " + times.joined(separator: ", "))
        }
    }
}

/// How long each pointer move took to handle.
@MainActor final class MoveTimes {
    private(set) var count = 0
    private var total: Double = 0
    private(set) var longest: Double = 0
    func add(_ seconds: Double) { count += 1; total += seconds; longest = max(longest, seconds) }
    var average: Double { count == 0 ? 0 : total / Double(count) }
}


/// A fast scroll up the first long thread — 24 points every 1/120 s, about 2,900 points a second,
/// for five seconds, from the newest message up through what is loaded and the pages that load
/// above it. Prints how the frames kept up, how often more rows were laid out or read, and how
/// long the thread sat at the top of what was loaded with the reader still scrolling up (the
/// wait for older history).
@MainActor enum ScrollBenchmark {
    static func threads(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView, let document = scroll.documentView, !(document is NSTableView),
           scroll.frame.height > 100, document.frame.height > scroll.frame.height + 500 {
            found.append(scroll)
        }
        return found + view.subviews.flatMap { threads(in: $0) }
    }

    static func run(_ store: WorkspaceStore, _ window: NSWindow) async {
        guard let scroll = threads(in: window.contentView).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView, let content = window.contentView else { print("Scroll benchmark: no long thread found"); return }
        let clip = scroll.contentView
        let variant = CommandLine.arguments.contains("--no-row-geometry") ? ", rows not reporting their frames"
            : CommandLine.arguments.contains("--no-context-menus") ? ", no context menus" : ""
        let loadedBefore = store.tiles.map(\.messages.count).reduce(0, +)
        let kinds = ["thread window grows", "older page asked", "older page arrives", "refresh applies", "tile body"]
        var notes: [(time: CFTimeInterval, kind: String)] = []
        TileTrace.sink = { message in notes.append((CACurrentMediaTime(), kinds.first { message.hasPrefix($0) } ?? "other")) }
        let recorder = FrameRecorder()
        recorder.start(in: content)
        await Check.pause(0.3)
        let total = 5.0
        let begin = CACurrentMediaTime()
        var stuck: Double = 0
        var last = begin
        var travelled: CGFloat = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(0))
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    defer { last = now }
                    guard now - begin < total else { timer.cancel(); done.resume(); return }
                    let y = clip.bounds.origin.y
                    let maximum = max(0, document.frame.height - clip.bounds.height)
                    // Up the thread: toward the start of the document (its top).
                    let atTop = document.isFlipped ? y <= 0.5 : y >= maximum - 0.5
                    if atTop { stuck += now - last }
                    let target = document.isFlipped ? max(0, y - 24) : min(maximum, y + 24)
                    travelled += abs(target - y)
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                    scroll.reflectScrolledClipView(clip)
                }
            }
            timer.resume()
        }
        let end = CACurrentMediaTime()
        await Check.pause(0.5)
        recorder.stop()
        TileTrace.sink = nil
        let frames = recorder.frames(from: begin, to: end)
        let stretches = recorder.busy.filter { $0.start >= begin && $0.end <= end && $0.end - $0.start > frames.interval * 1.05 }
        let busy = recorder.busy.filter { $0.start >= begin && $0.end <= end }.reduce(0) { $0 + ($1.end - $1.start) } / (end - begin)
        func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }
        var counts: [String: Int] = [:]
        for note in notes where note.time >= begin && note.time <= end { counts[note.kind, default: 0] += 1 }
        let loadedAfter = store.tiles.map(\.messages.count).reduce(0, +)
        print("Scroll benchmark (\(Harness.mode)\(variant)): \(Int(travelled)) points in \(String(format: "%.1f", end - begin)) s; at the top of what was loaded, still scrolling, for \(ms(stuck))")
        print("  frames: \(frames.count) of \(ms(frames.interval)), \(frames.missed) missed, longest gap \(ms(frames.longest)); the main thread was busy \(Int(busy * 100))% of the time, longer than a frame \(stretches.count) times")
        print("  " + kinds.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ") + "; messages loaded in the tiles \(loadedBefore) → \(loadedAfter)")
        func tally(_ from: CFTimeInterval, _ to: CFTimeInterval) -> String {
            var counts: [String: Int] = [:]
            for note in notes where note.time >= from && note.time <= to { counts[note.kind, default: 0] += 1 }
            return kinds.compactMap { kind in counts[kind].map { "\(kind) \($0)" } }.joined(separator: ", ")
        }
        for stretch in stretches.sorted(by: { $0.end - $0.start > $1.end - $1.start }).prefix(6) {
            print("  stretch of \(ms(stretch.end - stretch.start)) at +\(Int((stretch.start - begin) * 1000)) ms: " + tally(stretch.start, stretch.end))
        }
        // Back to the newest message for what follows.
        let maximum = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? maximum : 0))
        scroll.reflectScrolledClipView(clip)
        await Check.pause(0.5)
    }
}
