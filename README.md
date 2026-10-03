# Mosaic

A native macOS SwiftUI workspace for keeping several Messages conversations open in one window.

![Mosaic demo workspace](docs/workspace.png)

Open a conversation from the sidebar to give it a tile; double-click it to close that tile again. Closing a tile gives its space to the remaining cards. Keep up to four chats open, resize the invisible gaps, drag a header to move the whole card, and reply from each tile's own composer. Neighboring cards show the new order while you drag and the card lands there on release. **Tab** and **Shift–Tab** move between tiles. Grid, Columns, and Focus layouts are available. Open tiles, layout mode, and independent drafts survive reopening the app; divider sizes are adjusted within the current session.

The tile area fills the right side of the window, with search directly above the conversation list and no conversation-count or workspace-status labels. Tiles float over a solid background; invisible divider handles keep them resizable. Switch layouts with **⌘⌥1 / ⌘⌥2 / ⌘⌥3**. The interface follows the system's light/dark appearance with blue (`#218AFF`) iMessage bubbles, green SMS/RCS bubbles, and gray incoming messages. The original four-chat icon is green (`#39FF5A`).

Photos and videos sent in a conversation appear as thumbnails in the bubble; click one to open it, or use its context menu to show it in Finder. Other files show as a chip that opens the file. Web links are clickable and get a preview card with the page's title and image, like Messages. Thumbnails and previews are sized before they load, so the conversation never jumps while they arrive.

Replies appear in the conversation at once and retain their bubble identity when Messages confirms them. The input is labeled with the conversation's service, keeps text 8pt from its left, top and right edges, grows with a draft up to a few lines, and has no metadata footer or send button; its smiley button opens the system Emoji & Symbols palette for that field. Scroll bars inside tiles stay slim while you drag them. Mosaic has no animations: tiles open, close, move and resize on the next frame, and Focus mode switches conversations instantly.

## Run

Requires macOS 14 or later and Xcode 16 / Swift 6 or later to build. No third-party dependencies or package installs.

```sh
git clone git@github.com:doctorschmoctor/Mosaic.git
cd Mosaic
./scripts/build-app.sh
mkdir -p "$HOME/Applications"
ditto -x -k build/Mosaic.zip "$HOME/Applications"
open "$HOME/Applications/Mosaic.app"
```

The build verifies the signed app in a temporary directory and creates `build/Mosaic.zip`. Install from this ZIP into `~/Applications` (or `/Applications`) rather than running from a synced Desktop folder: iCloud/file-provider metadata can interfere with app signature checks. A convenience `.app` copy is also placed in `build/`.

Or open **Mosaic.xcodeproj**, select the **Mosaic** scheme, and press Run. The project defaults to local ad-hoc signing; no paid developer account is required. SwiftPM is also supported through `Package.swift`. Use the packaged `.app` for Messages permissions because it contains the privacy descriptions and automation entitlement.

The app starts with fictional demo conversations. Sending in demo mode adds a local bubble only. To force a fresh demo without touching your saved workspaces:

```sh
open "$HOME/Applications/Mosaic.app" --args --demo
```

## Connect real conversations

1. Mosaic opens its connection settings when it launches until Messages is connected. Later, open them from **Mosaic › Settings** (⌘,) or **Workspace › Connect Messages…**.
2. Open **Full Disk Access**, add the built `Mosaic.app`, enable it, then quit and reopen Mosaic. The **Show Mosaic in Finder** button reveals the exact app to add. Grant access to the same app copy you will run regularly.
3. Click **Connect Messages**. Mosaic reads conversations already synced to Apple Messages on this Mac and refreshes every three seconds.
4. Send a text from a tile. macOS asks to let Mosaic control Messages; allow it. If denied, enable **Mosaic → Messages** in **Privacy & Security → Automation**. Failed submissions retain the draft.
5. Allow Contacts access when Mosaic asks (it asks once, the first time it connects), or click **Allow Contacts access** in the connection settings. Names apply immediately, with loaded-contact and matched-conversation counts shown in settings. Once permission is granted, names reload after relaunch, when Contacts changes, and when you return from turning Mosaic on in **Privacy & Security → Contacts**. Contact names remain in memory; they are not copied into app storage. Matching handles phone punctuation, country-code differences in the Mac's region, and email casing, while ambiguous addresses remain unresolved. Named groups keep their group names.

Apple Messages must already be signed in. SMS/RCS availability depends on your existing Mac/iPhone Messages setup and the transport Apple exposes to automation. Mosaic never requests your Apple ID password.

## Workspace controls

- Click a sidebar conversation to add it or focus an existing tile; double-click an open one to close its tile.
- Click anywhere in a tile to type in its composer. Only the header drags the tile.
- Drag a tile header to move its whole card; neighboring cards preview the new order before you release it. Text selection and message scrolling remain available inside the card.
- **Tab** moves to the next tile's composer and **Shift–Tab** to the previous one, in the order the tiles appear, counted from the highlighted tile.
- Drag the invisible gaps to resize. The grid always fits the window, so rows get shorter as more tiles open; Columns scroll horizontally when they exceed the window width.
- Close a tile with ×; its draft remains available when reopened.
- **Return** sends from the active composer; **Shift–Return** inserts a line break. The smiley button opens Emoji & Symbols.
- **⌘K** focuses search; **⌘R** refreshes.
- **⌘⌥1**, **⌘⌥2**, **⌘⌥3** switch Grid, Columns, and Focus.
- **⌘⇧W** closes the focused tile.

## Current scope and limitations

This is a first working implementation for **existing conversations and text replies**, not a full replacement for every Messages feature. Apple provides no general Messages history API. Mosaic reads the local `~/Library/Messages/chat.db` with a **read-only SQLite connection**, including its live WAL, and submits sends through Messages' AppleScript dictionary. No private Apple frameworks are linked.

- The sidebar loads the 500 most recent conversations plus any open conversations, and holds nothing but the search field and the list. Search covers their names, participants, and latest previews.
- Each open tile initially loads 100 messages; **Load earlier messages** increases this up to 1,000.
- Plain text and common legacy typedstream bodies are displayed. Unknown rich-body formats are labeled with an **Open in Messages** fallback. Edits, unsends, rich formatting, and tapbacks are not rendered.
- Attachments are shown from the copies Messages keeps in `~/Library/Messages/Attachments`. One that was never downloaded to this Mac shows as **Not downloaded**; open it in Messages. Link previews are fetched from the web by LinkPresentation, the same framework Messages uses, and are kept only in memory.
- Use Apple Messages to send attachments or reactions, make calls, add new recipients, or create groups. **Open Messages** opens the direct recipient when available; for groups, it opens the app and you select the group there.
- A sent bubble shows only its time; **Delivered** or **Read** appears under the most recent sent message only, once Messages reports it. Automation accepting a send is not delivery. Sends are never retried automatically.
- Mosaic does not write read flags to Apple's database or synchronize unread state. Its new-activity indicators are local to the running session.
- The integration depends on Apple's undocumented database schema and may need updates after a macOS release. Live reading/sending needs validation on your own Messages account after granting permissions.
- The local build is ad-hoc signed, not notarized or intended for App Store submission. For distributing to other Macs, use your own Developer ID and notarization. Rebuilding or moving an ad-hoc signed app may require renewing its permissions.

## Privacy

Message history, attachment thumbnails, link previews, and contact names remain in memory. Mosaic persists only workspace metadata and drafts in local UserDefaults (drafts are plaintext local app data). Link previews are the only network requests Mosaic makes: fetching a preview contacts the linked site. Demo and live workspaces are separate. There is no analytics, cloud backend, credential collection, or upload code. The repository contains only source, original icon artwork, tests with synthetic data, and a demo screenshot; the demo's two sample pictures are drawn by the app at launch.

## Development

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The core test suite covers independent drafts and restoration, tile capacity and ordering, read-only history isolation, WAL visibility, pinned conversations outside the recent limit, date formats, Unicode, long typedstream messages, malformed bodies, and permission errors. CI runs the tests and builds the app on macOS.

Composer tests also verify per-editor Return routing, Shift–Return line breaks, isolated demo sends, and compilation of the Messages automation script without executing it. Chrome and handle tests cover the AppKit title bar, close-versus-focus clicks and drags on tile headers, focus-chip hit testing and selection, rapid open/close/layout churn, and keyboard traversal. `./scripts/render-preview.sh` renders the native view using fictional data for visual inspection.

Additional tests cover contact matching and immediate updates during refresh, tile layouts and resize minimums, drag previews and draft preservation, and stable message identities during confirmation.

`Sources/Mosaic` contains the UI, workspace state, Contacts integration, attachment and link-preview views, and exact-chat AppleScript sender. The window's tall title bar is an empty AppKit toolbar (`WindowChrome`), not a SwiftUI toolbar item: the SwiftUI item put a nested hosting view in the title bar whose constraint updates could loop until AppKit raised an exception and the app aborted while histories loaded or tiles opened and closed quickly. Tile headers handle their own mouse events in AppKit (`TileHeaderHandle`; the × glyph is drawn by SwiftUI, its clicks are detected by the handle, and a header drag is followed with a local event monitor so it keeps going when SwiftUI re-inserts the raised tile's views) and the Focus-mode conversation chips are one AppKit view (`FocusChipBar`), so dragging, clicking, closing and switching work even where they sit on the window's title bar strip. AppKit's automatic title-bar dragging is off (`NSWindow.isMovable = false`), because in that region macOS moves the window on any press regardless of the view under the pointer; the empty parts of the strip move the window through `WindowDragRegion` instead (`performDrag`, falling back to moving the frame directly), and a double-click there follows the System Settings title-bar action. Every `NSViewRepresentable` reports its size from the layout proposal instead of Auto Layout, and no state changes during a SwiftUI update. `WorkspaceStore` is `@Observable`, so a view re-renders only when something it read changes (typing a draft no longer re-renders every row and tile), and bubbles use cached date and link formatting. The tile canvas has the same view structure in every layout, so switching layouts resizes tiles instead of rebuilding them, and each conversation's scroll position is kept in AppKit by `ScrollPinner`: the distance from the newest message is preserved through resizes, layout switches and new messages, and a list the reader scrolled up stays on the same rows while older messages load. The Messages database is read only when a cheap fingerprint of it changed, and a watcher on `chat.db` and its write-ahead log refreshes within a moment of Messages writing, with the 3-second poll as a fallback. As a safety net the app also turns off `NSApplicationCrashOnExceptions`: an AppKit exception in a display cycle is logged to Console instead of ending the app. `Sources/MosaicCore` contains models, link detection, and the read-only database reader. `Sources/CSQLite` exposes the system SQLite library. The Xcode target compiles the same sources directly; SwiftPM keeps the core separate for tests.

After adding source files, regenerate the Xcode project with `python3 scripts/generate-xcode-project.py`. To regenerate the original icon, run `swift scripts/make-icon.swift` followed by `iconutil -c icns .build/Mosaic.iconset -o Resources/Mosaic.icns`.

Apple references: [NSAppleScript](https://developer.apple.com/documentation/foundation/nsapplescript), [automation privacy description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription), [macOS file access protections](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web).
