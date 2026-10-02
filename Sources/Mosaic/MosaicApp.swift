import SwiftUI

@main struct MosaicApp: App {
    @StateObject private var store = WorkspaceStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Mosaic", id: "workspace") {
            WorkspaceView().environmentObject(store)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Find a Conversation") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Workspace") {
                Button("Grid Layout") { store.setLayout(.grid) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Column Layout") { store.setLayout(.columns) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Focus Layout") { store.setLayout(.focus) }.keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Close Focused Tile") { if let id = store.focused?.id { store.close(id) } }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Refresh Messages") { Task { await store.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button("Connect Messages…") { store.showSetup = true }
            }
        }
        Settings { SetupView().environmentObject(store) }
    }
}

extension Notification.Name { static let focusSearch = Notification.Name("Mosaic.focusSearch") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
