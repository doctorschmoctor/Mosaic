# Architecture

Mosaic is a SwiftUI app with AppKit where SwiftUI gets in the way of precise input, scrolling or window behavior. `Sources/Mosaic` holds the UI, workspace state, Contacts integration, media views and the AppleScript sender; `Sources/MosaicCore` holds the models, link detection and the read-only database reader (tested separately through SwiftPM); `Sources/CSQLite` exposes the system SQLite library. The Xcode target compiles the same sources.

## Zoom and motion

One persisted zoom (⌘+ / ⌘− / ⌘0, 80–160% in 10% steps) scales conversation content only: message and label fonts, bubble padding and corners, media and link-card dimensions, and the composer's font, insets and height bounds — the composer's `NSTextView` is updated in place, keeping text, selection, undo and marked text. Tile frames, the sidebar and the window chrome never scale. The `KeyboardRouter` consumes the zoom keys in the workspace window (so a press never fires both the monitor and the menu equivalent); the Workspace menu carries the same single action path.

There is no blanket animation suppression: every store mutation runs in a transaction without animation (`instantly`), which keeps tiles, layouts and dividers on-the-next-frame, and the one declared motion is `NewMessageEffect` — a row appended at the thread's tail settles in once (classified by presentation identity, never by `onAppear`, so initial loads, older pages, reconnects and confirmations stay still). The offset is visual, not layout, so scroll pinning is untouched; Reduce Motion drops the movement and keeps a short fade; a Settings toggle turns it off.

## State

`WorkspaceStore` is `@Observable`, with the workspace split into separate fields so a view re-renders only when something it read changes — typing a draft re-renders one composer, not every row and tile. Each tile's last use (opened, focused, typed in, sent from) is counted, and a fifth conversation replaces the tile used longest ago in that tile's place, so the layout keeps its shape; an unsent New Message is never the one replaced while a conversation can be. Open tiles, layout and drafts persist in UserDefaults; message history, thumbnails, previews and contact names stay in memory. Sends are held as pending bubbles until the database reports them, then reconciled by text and time so a bubble keeps its identity. Nothing is retried automatically.

## Window chrome

The tall title bar is an empty AppKit toolbar (`WindowChrome`), not a SwiftUI toolbar item: the SwiftUI item put a nested hosting view in the title bar whose constraint updates could loop until AppKit raised an exception, which ended the app while histories loaded or tiles churned. AppKit's automatic title-bar dragging is off (`isMovable = false`), because in that region macOS moves the window on any press regardless of the view under the pointer; `WindowDragRegion` moves the window from the empty parts of the strip instead (`performDrag`, falling back to moving the frame), and a double-click there follows the System Settings title-bar action. As a safety net, `NSApplicationCrashOnExceptions` is off: an AppKit exception in a display cycle is logged, not fatal.

## Tiles

`TileLayout` plans every frame; `TileCanvas` places tiles through layout rather than offsets, so hit testing, carets and cursors line up with what is drawn. The canvas has the same view structure in every layout, so switching layouts resizes tiles instead of rebuilding them. Tile headers handle their own mouse events in AppKit (`TileHeaderHandle`): the × glyph is drawn by SwiftUI, its clicks are detected by the handle, and a header drag is followed with a local event monitor so it continues when SwiftUI re-inserts the raised tile's views. The Focus-layout chips are one AppKit view (`FocusChipBar`). Every `NSViewRepresentable` reports its size from the layout proposal, never through Auto Layout, and no state changes during a SwiftUI update.

## Scrolling

`ScrollPinner` keeps each conversation's scroll position in AppKit, synchronously with size changes, in two modes. Near the bottom it follows the newest message through everything. Scrolled up, the reader is reading: SwiftUI hands the pinner a descriptor of the coming content (first/last row identity) before AppKit lays it out, so an append below moves nothing, a prepend above keeps the same rows, and a viewport resize keeps the row at the top of the view. For reflows (width or zoom changes) each row reports its frame in the thread's own scroll-invariant coordinate space into a `ThreadRowRegistry` (a plain class — no view invalidation), and the pinner puts the remembered message back at its remembered offset one turn later, once layout has reported the new frames. `ThinScroller` draws the same slim knob whether idle, hovered or dragged, redraws when its clip view moves, and — in the sidebar — classifies each trackpad gesture once (sideways swipe or scroll) so the knob never flashes for a swipe and the swiped row knows to drop its highlight. Bubbles are drawn text rather than selectable text views; each selectable `Text` on macOS is a full text view, and hundreds of them made opening and resizing slow.

## Sidebar

The list is a SwiftUI `List` for its swipe actions. Rows are highlighted only by the keyboard; the pointer highlights nothing, so a swipe never sits against a hover highlight, and the keyboard's highlight is hidden while a swipe is under way. `SidebarKeyboard` gives the list the keyboard (⌘L): an invisible AppKit view becomes first responder, so the highlight follows real keyboard focus and clears when anything else is clicked. `KeyboardRouter` takes ⌘F, ⌘L, Tab and the search field's arrow keys in a local event monitor, ahead of the menu bar.

## Opening tiles

A tile opens on its messages without waiting for a full load. The store keeps the histories it recently showed or fetched in memory (`historyCache`, sixteen conversations, least recently used dropped first; never written to disk), fetches the eight most recent conversations after the first load and any conversation whose row the pointer rests on, and fetches a single conversation's page (`MessagesReader.page(forChat:)`) when a tile opens on one it does not have. The full load that follows brings the history up to date.

## Messages database

`MessagesDatabase` opens `chat.db` read-only with the WAL visible. A poll loads only when a cheap fingerprint of the database changed, and `FileChangeWatcher` on `chat.db` and its write-ahead log refreshes within a moment of Messages writing, with the three-second poll as a fallback. Participants, attachments and typedstream bodies are decoded in `MosaicCore`.

## Reactions, replies, edits, unread

The reader keeps reaction rows (`associated_message_type` 2000–3999) out of the history page and loads those pointing at the page's GUIDs separately; `Reactions.reduce` rebuilds the current state from whatever rows exist — per actor and part the latest row decides, a removal clears only the same actor's matching kind — so a deleted row simply disappears. Replies carry `thread_originator_guid`/part; originals above the page are fetched by GUID within the same chat (at most fifty), so a quote never needs the history above it and never shows another chat's message. Unsent rows keep their place with all content dropped at read time (so nothing stale can be copied, quoted or previewed). Unread counts are counted by the reader from a per-conversation seen boundary (a row id), incoming ordinary messages only; the boundary moves when a thread's newest message is in view or the reader sends, never on open or focus alone.

Mosaic shows reactions and replies but does not send them: Messages' scripting dictionary sends only text and files (`TransportCapabilities.nativeReply` and `.nativeReaction` are false), and Mosaic does not imitate either with ordinary text.

## Composing

`ComposeDraft` and `Recipient` address a new message; handles are normalized so a contact's phone number matches the conversation's. Sending to an existing conversation uses the chat's identifier in AppleScript; a new person goes through the iMessage account's participant; a brand-new group is handed to Messages through an `imessage:` URL, since Messages offers no automation for creating one.

Pictures and files (`OutgoingAttachment`) wait in the composer and go out before the text, each as its own message. Pasted pictures are written to Mosaic's folder in Application Support; at send time every file is copied into `~/Library/Messages/.mosaic-outgoing/<id>/`, because Messages' sandbox reads attachments only from its own folders — a file handed over from anywhere else is accepted by AppleScript and then fails to send. The staged copy is removed a few minutes later, once Messages has copied it into its Attachments folder. A pending bubble with an empty text and the file as its attachment stands in until the database reports the sent message, which is how Messages records a picture. The + button is an AppKit view so the Photos grid can open in a popover card from it. The grid is Mosaic's own (`PhotoLibraryPicker`, on PhotoKit, with Photos access asked once): the system picker's card carries a selection label, a location notice and option buttons that cannot be removed, and its scroll bar grows under the pointer. Thumbnails come from `PHCachingImageManager`; chosen items are written out concurrently by `PHAssetResourceManager` (the edited rendition when there is one) into Mosaic's folder, each appearing behind a placeholder as it lands; a Return pressed meanwhile waits for them. The strip's thumbnails come from a camera file's embedded preview when it has one.
