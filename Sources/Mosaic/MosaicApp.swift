import SwiftUI
import Quartz

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
                // The sidebar's filters, for the keyboard (and VoiceOver's menu search).
                ForEach(Array(SidebarFilter.allCases.enumerated()), id: \.element) { index, filter in
                    Toggle("Show \(filter.title)", isOn: Binding(get: { store.sidebarFilter == filter },
                                                                set: { if $0 { store.setSidebarFilter(filter) } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                }
                Divider()
                // Searches the focused tile's loaded messages (⌘F finds a conversation).
                Button("Find in Conversation") { store.beginFind() }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Conversation Details") { store.showDetails() }.keyboardShortcut("i", modifiers: .command)
                Divider()
                // The same single action path as the keys (KeyboardRouter consumes ⌘+/⌘−/⌘0 in the
                // workspace window, so a key press never triggers both the monitor and the menu).
                Button("Zoom In") { store.zoomIn() }.keyboardShortcut("=", modifiers: .command).disabled(!store.canZoomIn)
                Button("Zoom Out") { store.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(!store.canZoomOut)
                Button("Actual Size (\(store.zoomLabel))") { store.resetZoom() }.keyboardShortcut("0", modifiers: .command).disabled(store.zoom == 1)
                Divider()
                Button("Grid Layout") { store.setLayout(.grid) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Column Layout") { store.setLayout(.columns) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Focus Layout") { store.setLayout(.focus) }.keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                // The focused tile from the keyboard: its place, and its size (taken from the tile
                // beside it, as dragging the divider between them would).
                Group {
                    Button("Move Tile Left") { if !store.moveFocusedTile(by: -1) { NSSound.beep() } }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button("Move Tile Right") { if !store.moveFocusedTile(by: 1) { NSSound.beep() } }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Button("Make Tile Wider") { store.resizeFocusedTile(.wider) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .control])
                    Button("Make Tile Narrower") { store.resizeFocusedTile(.narrower) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .control])
                    Button("Make Tile Taller") { store.resizeFocusedTile(.taller) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option, .control])
                    Button("Make Tile Shorter") { store.resizeFocusedTile(.shorter) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option, .control])
                    Button("Equal Tile Sizes") { store.equalizeTiles() }
                }
                .disabled(!store.canArrangeTiles)
                Divider()
                Button("Close Focused Tile") { if let id = store.focused?.id { store.close(id) } }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Reopen Closed Tile") { store.reopenLastClosedTile() }.keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!store.canReopenClosedTile)
                Button("Hidden Conversations…") { store.showHiddenConversations = true }
                Divider()
                Button("Go to Next Unread") { if !store.goToNextUnread() { NSSound.beep() } }.keyboardShortcut("u", modifiers: [.command, .option])
                Button(store.focused.map { store.needsReply($0.id) } == true ? "Clear Needs Reply" : "Mark as Needs Reply") {
                    if let id = store.focused?.id { store.toggleNeedsReply(id) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.focused?.isComposeDraft != false)
                Button("Refresh Messages") { Task { await store.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button("Connect Messages…") { store.showSetup = true }
            }
        }
        Settings { SettingsView().environment(store) }
    }
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
    /// Messages still waiting to be handed to Messages would be lost by quitting now (their text
    /// and files already left the composer): ask, and offer to quit once they have gone.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let activity = SendActivity.shared
            guard activity.waiting > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = activity.waiting == 1 ? "A message is still being sent" : "\(activity.waiting) messages are still being sent"
            alert.informativeText = "Mosaic is handing them to Messages. Quit once they have gone, or quit now and they will not be sent."
            alert.addButton(withTitle: "Quit When Sent")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Now")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                activity.whenAllSent { NSApp.reply(toApplicationShouldTerminate: true) }
                return .terminateLater
            case .alertThirdButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }

    // The Quick Look panel looks along the responder chain for its controller; the app delegate
    // answers for Mosaic's attachments (QuickLook).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { QuickLook.shared.take(panel) } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { QuickLook.shared.release(panel) } }
}
