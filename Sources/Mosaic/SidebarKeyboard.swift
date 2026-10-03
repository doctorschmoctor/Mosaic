import SwiftUI
import AppKit

/// Keyboard access to the conversation list. ⌘L (or an arrow key from the search field) gives the
/// list the keyboard: an invisible AppKit view (`SidebarKeyFocus`) becomes the window's first
/// responder, the store marks the row the keyboard is on, and that view handles the keys:
///
/// - ↑ / ↓ move between rows (Home and End jump to the first and last)
/// - Return opens the row in a tile, or focuses its tile when it is already open
/// - Delete (⌫) closes the row's tile; the conversation stays in the list
/// - Esc hands the keyboard back to the focused tile's composer
/// - Tab moves on to the tiles (`KeyboardRouter`)
///
/// The highlight is tied to real keyboard focus: clicking anywhere else (a composer, the search
/// field) makes that view the first responder, so the list's highlight clears by itself.
@MainActor final class SidebarKeyboard {
    weak var view: SidebarKeyFocus.CatcherView?

    /// Where the keyboard lands when the list takes it.
    enum Entry { case current, first, last }

    /// Gives the conversation list the keyboard. Returns false when the list is not in a window.
    @discardableResult func focusList(_ entry: Entry = .current) -> Bool {
        guard let view, let window = view.window else { return false }
        view.pendingEntry = entry
        guard window.makeFirstResponder(view) else { view.pendingEntry = nil; return false }
        // Already the first responder: becomeFirstResponder was not called again.
        if let entry = view.pendingEntry { view.pendingEntry = nil; view.enter(entry) }
        return true
    }
    var hasKeyboard: Bool { view.map { $0.window?.firstResponder === $0 } ?? false }
}

/// The invisible view that holds the keyboard for the conversation list (see `SidebarKeyboard`).
struct SidebarKeyFocus: NSViewRepresentable {
    let keyboard: SidebarKeyboard
    let store: WorkspaceStore

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.store = store
        keyboard.view = view
        return view
    }
    func updateNSView(_ view: CatcherView, context: Context) { view.store = store; keyboard.view = view }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CatcherView, context: Context) -> CGSize? { .zero }

    final class CatcherView: NSView {
        weak var store: WorkspaceStore?
        var pendingEntry: SidebarKeyboard.Entry?

        override var acceptsFirstResponder: Bool { true }
        // Not part of the Tab key loop: Tab is tile traversal (KeyboardRouter).
        override var canBecomeKeyView: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            let entry = pendingEntry ?? .current
            pendingEntry = nil
            enter(entry)
            return true
        }
        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            if let store, store.sidebarSelection != nil { instantly { store.sidebarSelection = nil } }
            return true
        }
        func enter(_ entry: SidebarKeyboard.Entry) {
            guard let store else { return }
            switch entry {
            case .current: store.selectSidebarRow(store.sidebarSelection)
            case .first: store.sidebarSelection = nil; store.moveSidebarSelection(by: 1)
            case .last: store.sidebarSelection = nil; store.moveSidebarSelection(by: -1)
            }
        }

        override func keyDown(with event: NSEvent) {
            guard let store, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                super.keyDown(with: event); return
            }
            switch event.keyCode {
            case 125: store.moveSidebarSelection(by: 1)                   // ↓
            case 126: store.moveSidebarSelection(by: -1)                  // ↑
            case 115: store.sidebarSelection = nil; store.moveSidebarSelection(by: 1)   // Home
            case 119: store.sidebarSelection = nil; store.moveSidebarSelection(by: -1)  // End
            case 36, 76: store.activateSidebarSelection()                 // Return, Enter
            case 51, 117: store.untileSidebarSelection()                  // Delete, Forward Delete
            case 53: leave()                                              // Esc
            default: super.keyDown(with: event)
            }
        }
        /// Hands the keyboard to the focused tile's composer, or to nobody.
        func leave() {
            guard let window else { return }
            if let store, let focused = store.focused {
                store.requestComposerFocus(focused.id)
            } else {
                window.makeFirstResponder(nil)
            }
        }
    }
}
