import AppKit
import SwiftUI

// Mosaic as the app runs it — its window and its menus, which SwiftUI keeps up to date through
// the app itself (a test's NSHostingView has no menus) — with the fictional demo workspace. Tiles
// are closed and opened the reader's ways: a header's close button, the Workspace menu's Close
// Focused Tile and Reopen Closed Tile, a conversation opened from the sidebar. After each, the
// tiles drawn must be the tiles open, where the layout puts them, within a second and a half.
// Prints what it saw; exits 0 when every step held, 1 when one did not.
// Usage: MosaicAppCheck --demo [--store-menus]
//   --store-menus adds a menu whose items read the store's tiles directly, as the Workspace
//   menu's did before MenuState: a check that the harness sees the failure it guards against.

@main struct AppCheck: App {
    static let suite = "MosaicAppCheck-\(UUID())"
    @State private var store = WorkspaceStore(defaults: UserDefaults(suiteName: AppCheck.suite)!, forceDemo: true)
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
            WorkspaceCommands(store: store)
            StoreMenus(store: store, readsStore: CommandLine.arguments.contains("--store-menus"))
        }
    }
}

/// Items whose state is read from the store itself (only with --store-menus).
struct StoreMenus: Commands {
    let store: WorkspaceStore
    let readsStore: Bool
    var body: some Commands {
        CommandMenu("Check") {
            Button("Arrange") {}.disabled(readsStore && !store.canArrangeTiles)
            Button("Reopen") {}.disabled(readsStore && !store.canReopenClosedTile)
        }
    }
}

final class CheckDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Never holds up a CI job.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("App check: timed out"); exit(2) }
    }
}

@MainActor enum Check {
    static var failures: [String] = []

    static func run(_ store: WorkspaceStore) async {
        let mode = CommandLine.arguments.contains("--store-menus") ? " (menus that read the store)" : ""
        menuValues = { store.menu.values }
        await pause(2)
        store.setLayout(.grid)
        await pause(0.8)
        guard let window = NSApp.windows.first(where: { !handles(in: $0.contentView).isEmpty }) else { return finish("no workspace window") }
        guard store.openIDs.count == 4 else { return finish("four demo tiles expected, \(store.openIDs.count) open") }
        print("App check\(mode): \(store.openIDs.count) tiles open in a \(Int(window.frame.width))×\(Int(window.frame.height)) window")
        await expectInPlace(store, window, "at launch")

        // A header's close button, pressed and released (the top-left tile).
        let first = store.displayOrder[0]
        guard pressCloseOfTopLeftTile(in: window) else { return finish("no tile header to press") }
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
            guard pressCloseOfTopLeftTile(in: window) else { break }
            await expectInPlace(store, window, "after closing down to \(count - 1)")
        }
        finish(nil)
    }

    static func finish(_ problem: String?) {
        if let problem { failures.append(problem) }
        UserDefaults.standard.removePersistentDomain(forName: AppCheck.suite)
        let mode = CommandLine.arguments.contains("--store-menus") ? " (menus that read the store)" : ""
        if failures.isEmpty {
            print("App check\(mode): passed")
            exit(0)
        }
        print("App check\(mode): FAILED — " + failures.joined(separator: "; "))
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
    }

    /// Presses and releases the close button of the top-left tile's header, as the reader does.
    static func pressCloseOfTopLeftTile(in window: NSWindow) -> Bool {
        let all = handles(in: window.contentView)
        guard let handle = all.min(by: { a, b in
            let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
            return (-fa.maxY.rounded(), fa.minX.rounded()) < (-fb.maxY.rounded(), fb.minX.rounded())
        }) else { return false }
        let point = handle.convert(NSPoint(x: handle.closeRect.midX, y: handle.closeRect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        handle.mouseDown(with: down)
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
                print("App check: \(title) unavailable in the menu bar; the menu's values: \(String(describing: menuValues?()))")
                failures.append("\(title) is unavailable")
                return false
            }
            await pause(0.05)
        }
    }
    static var menuValues: (() -> Any)?
}
