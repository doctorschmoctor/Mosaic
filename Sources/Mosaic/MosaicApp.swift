import SwiftUI

@main struct MosaicApp: App {
    @State private var store = WorkspaceStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Mosaic", id: "workspace") {
            WorkspaceView().environment(store)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        // With the (empty, invisible) toolbar WorkspaceView declares, this gives the title bar Messages'
        // height, which brings the window controls in from the corner.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { store.beginNewChat() }.keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Workspace") {
                // KeyboardRouter takes ⌘F and ⌘L in the workspace window itself, ahead of the menu
                // bar, so the Edit menu's text Find never claims ⌘F; these items name the keys.
                Button("Find a Conversation") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Go to Conversations") { NotificationCenter.default.post(name: .focusConversationList, object: nil) }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Grid Layout") { store.setLayout(.grid) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Column Layout") { store.setLayout(.columns) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Focus Layout") { store.setLayout(.focus) }.keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Close Focused Tile") { if let id = store.focused?.id { store.close(id) } }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Refresh Messages") { Task { await store.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button("Connect Messages…") { store.showSetup = true }
            }
        }
        Settings { SetupView().environment(store) }
    }
}

extension Notification.Name {
    /// Puts the keyboard in the sidebar's search field (⌘F).
    static let focusSearch = Notification.Name("Mosaic.focusSearch")
    /// Gives the conversation list the keyboard (⌘L); see `SidebarKeyboard`.
    static let focusConversationList = Notification.Name("Mosaic.focusConversationList")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI apps abort on any Objective-C exception that reaches the run loop. Mosaic's crashes
        // were AppKit layout exceptions in a display cycle; an aborted cycle is recoverable, so such an
        // exception is logged (see Console) and the app keeps running. The causes are fixed too.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "NSApplicationCrashOnExceptions")
        defaults.register(defaults: ["NSApplicationCrashOnExceptions": false, "NSApplicationShowExceptions": true])
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
