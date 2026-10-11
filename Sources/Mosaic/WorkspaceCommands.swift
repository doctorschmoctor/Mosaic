import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// What the menu bar shows of the workspace: which items can be chosen now, the chosen sidebar
/// filter, the zoom. The menus read these values and never the store itself.
///
/// SwiftUI keeps an app's menus up to date at once, inside a change to what they read, before
/// the new value is stored, and it brings the window up to date in the same pass. When the menus
/// read the store's tiles, closing a tile updated the window while the tile was still open and
/// the window then missed the change: the tiles left stayed where they were. So the store copies
/// these values here once a change is done, on the next turn of the main queue, and the menus
/// follow from there (`WorkspaceStore.trackMenu`).
@MainActor @Observable final class MenuState {
    struct Values: Equatable {
        var canArrangeTiles = false
        var canReopenClosedTile = false
        var sidebarFilter: SidebarFilter = .all
        var canZoomIn = true
        var canZoomOut = true
        var isActualSize = true
        var zoomLabel = "100%"
    }
    private(set) var values = Values()
    /// One change when anything differs, none otherwise.
    func update(_ next: Values) {
        if values != next { values = next }
    }
}

/// Mosaic's menus: New Message, and the Workspace menu. Each item acts through the store; what an
/// item shows (available or not, checked or not) comes from `store.menu`.
struct WorkspaceCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        let menu = store.menu.values
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
            // The sidebar's filters, for the keyboard (and VoiceOver's menu search): ⌃⌘1–3.
            ForEach(Array(SidebarFilter.allCases.enumerated()), id: \.element) { index, filter in
                Toggle("Show \(filter.title)", isOn: Binding(get: { menu.sidebarFilter == filter },
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
            Button("Zoom In") { store.zoomIn() }.keyboardShortcut("=", modifiers: .command).disabled(!menu.canZoomIn)
            Button("Zoom Out") { store.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(!menu.canZoomOut)
            Button("Actual Size (\(menu.zoomLabel))") { store.resetZoom() }.keyboardShortcut("0", modifiers: .command).disabled(menu.isActualSize)
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
            .disabled(!menu.canArrangeTiles)
            Divider()
            Button("Close Focused Tile") { if let id = store.focused?.id { store.close(id) } }.keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Reopen Closed Tile") { store.reopenLastClosedTile() }.keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!menu.canReopenClosedTile)
            Button("Hidden Conversations…") { store.showHiddenConversations = true }
            Divider()
            Button("Go to Next Unread") { if !store.goToNextUnread() { NSSound.beep() } }.keyboardShortcut("u", modifiers: [.command, .option])
            Button("Refresh Messages") { Task { await store.refresh() } }.keyboardShortcut("r", modifiers: .command)
            Button("Connect Messages…") { store.showSetup = true }
        }
    }
}
