# Architecture

Mosaic is a SwiftUI app with AppKit where SwiftUI gets in the way of precise input, scrolling or window behavior. `Sources/Mosaic` holds the UI, workspace state, Contacts integration, media views and the AppleScript sender; `Sources/MosaicCore` holds the models, link detection and the read-only database reader (tested separately through SwiftPM); `Sources/CSQLite` exposes the system SQLite library. The Xcode target compiles the same sources.

## State

`WorkspaceStore` is `@Observable`, with the workspace split into separate fields so a view re-renders only when something it read changes — typing a draft re-renders one composer, not every row and tile. Open tiles, layout and drafts persist in UserDefaults; message history, thumbnails, previews and contact names stay in memory. Sends are held as pending bubbles until the database reports them, then reconciled by text and time so a bubble keeps its identity. Nothing is retried automatically.

## Window chrome

The tall title bar is an empty AppKit toolbar (`WindowChrome`), not a SwiftUI toolbar item: the SwiftUI item put a nested hosting view in the title bar whose constraint updates could loop until AppKit raised an exception, which ended the app while histories loaded or tiles churned. AppKit's automatic title-bar dragging is off (`isMovable = false`), because in that region macOS moves the window on any press regardless of the view under the pointer; `WindowDragRegion` moves the window from the empty parts of the strip instead (`performDrag`, falling back to moving the frame), and a double-click there follows the System Settings title-bar action. As a safety net, `NSApplicationCrashOnExceptions` is off: an AppKit exception in a display cycle is logged, not fatal.

## Tiles

`TileLayout` plans every frame; `TileCanvas` places tiles through layout rather than offsets, so hit testing, carets and cursors line up with what is drawn. The canvas has the same view structure in every layout, so switching layouts resizes tiles instead of rebuilding them. Tile headers handle their own mouse events in AppKit (`TileHeaderHandle`): the × glyph is drawn by SwiftUI, its clicks are detected by the handle, and a header drag is followed with a local event monitor so it continues when SwiftUI re-inserts the raised tile's views. The Focus-layout chips are one AppKit view (`FocusChipBar`). Every `NSViewRepresentable` reports its size from the layout proposal, never through Auto Layout, and no state changes during a SwiftUI update.

## Scrolling

`ScrollPinner` keeps each conversation's scroll position in AppKit, synchronously with size changes: the distance from the newest message survives resizes, layout switches and new messages, and a list the reader scrolled up stays on the same rows while older messages load above. `ThinScroller` draws the same slim knob whether idle, hovered or dragged, redraws when its clip view moves, and — in the sidebar — classifies each trackpad gesture once (sideways swipe or scroll) so the knob never flashes for a swipe and the swiped row knows to drop its highlight. Bubbles are drawn text rather than selectable text views; each selectable `Text` on macOS is a full text view, and hundreds of them made opening and resizing slow.

## Sidebar

The list is a SwiftUI `List` for its swipe actions. Rows are highlighted only by the keyboard; the pointer highlights nothing, so a swipe never sits against a hover highlight, and the keyboard's highlight is hidden while a swipe is under way. `SidebarKeyboard` gives the list the keyboard (⌘L): an invisible AppKit view becomes first responder, so the highlight follows real keyboard focus and clears when anything else is clicked. `KeyboardRouter` takes ⌘F, ⌘L, Tab and the search field's arrow keys in a local event monitor, ahead of the menu bar.

## Messages database

`MessagesDatabase` opens `chat.db` read-only with the WAL visible. A poll loads only when a cheap fingerprint of the database changed, and `FileChangeWatcher` on `chat.db` and its write-ahead log refreshes within a moment of Messages writing, with the three-second poll as a fallback. Participants, attachments and typedstream bodies are decoded in `MosaicCore`.

## Composing

`ComposeDraft` and `Recipient` address a new message; handles are normalized so a contact's phone number matches the conversation's. Sending to an existing conversation uses the chat's identifier in AppleScript; a new person goes through the iMessage account's participant; a brand-new group is handed to Messages through an `imessage:` URL, since Messages offers no automation for creating one.

Pictures and files (`OutgoingAttachment`) wait in the composer and go out before the text, each as its own message. Pasted pictures are written to Mosaic's folder in Application Support; at send time every file is copied into `~/Library/Messages/.mosaic-outgoing/<id>/`, because Messages' sandbox reads attachments only from its own folders — a file handed over from anywhere else is accepted by AppleScript and then fails to send. The staged copy is removed a few minutes later, once Messages has copied it into its Attachments folder. A pending bubble with an empty text and the file as its attachment stands in until the database reports the sent message, which is how Messages records a picture. The + button is an AppKit view so the Photos picker (`PHPickerViewController`, out of process, no library permission) can open in a popover card from it; the picker sits in a host controller of a fixed size, since on its own the popover shrank to the remote view's minimal fitting size.
