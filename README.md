# Mosaic

Several Messages conversations, side by side, in one native macOS window.

![Mosaic workspace](docs/workspace.png)

Mosaic reads the conversations already on your Mac and lets you keep up to four of them open at once, each with its own history, draft and composer. Replies go out through Apple Messages. Nothing leaves your Mac.

## Features

- **Tiles** — Open up to four conversations in Grid, Columns or Focus layout. Drag a header to rearrange, drag the gaps to resize, close with ×. Open tiles, layout and drafts are restored on relaunch.
- **New messages** — Address a new message to one person or several, from your contacts or any existing conversation. Mosaic finds the matching conversation or hands the new one to Messages.
- **Live** — New messages appear within a moment of arriving; your replies show at once and keep their place when Messages confirms them.
- **Media and links** — Photo and video thumbnails, file chips, and link previews, all sized before they load so nothing jumps.
- **Contact names** — Phone numbers and addresses become names with Contacts access. Names stay in memory.
- **Instant** — No animations anywhere. Tiles open, close, move and switch on the next frame.

## Install

Requires macOS 14 or later; Xcode 16 / Swift 6 to build. No dependencies.

```sh
git clone git@github.com:doctorschmoctor/Mosaic.git
cd Mosaic
./scripts/build-app.sh
ditto -x -k build/Mosaic.zip /Applications
open /Applications/Mosaic.app
```

Install from the ZIP into `/Applications` (or `~/Applications`) rather than running from a synced folder. The project also opens in Xcode (**Mosaic.xcodeproj**, scheme **Mosaic**) and builds with SwiftPM; use the packaged app for Messages permissions, as it carries the privacy descriptions and automation entitlement. The build is ad-hoc signed for local use.

## Connect Messages

Mosaic launches with an empty workspace. Press **Connect Messages** there (or open **Mosaic › Settings**) and follow the steps:

1. **Full Disk Access** — Add `Mosaic.app` in System Settings › Privacy & Security › Full Disk Access, then quit and reopen Mosaic. **Show Mosaic in Finder** reveals the exact app to add.
2. **Connect** — Mosaic reads the conversations synced to Messages on this Mac and follows the database for changes.
3. **Sending** — Your first send asks permission to control Messages. Allow it, or enable Mosaic › Messages under Privacy & Security › Automation.
4. **Contacts** (optional) — Allow Contacts access to see names instead of numbers.

Messages must already be signed in. SMS/RCS availability follows your Messages setup.

## Keyboard

| | |
|---|---|
| **⌘N** | New message |
| **⌘F** | Find a conversation — **Return** opens the first match, **↓** moves into the list, **Esc** clears |
| **⌘L** | Conversation list — **↑ ↓** move, **Return** opens or focuses, **⌫** closes the row's tile, **Esc** back to the composer |
| **Tab / ⇧Tab** | Next / previous tile |
| **Return** | Send · **⇧Return** inserts a line break |
| **Esc** | Close a New Message tile |
| **⌘⌥1 · ⌘⌥2 · ⌘⌥3** | Grid · Columns · Focus |
| **⌘⇧W** | Close the focused tile |
| **⌘R** | Refresh |
| **⌘,** | Settings |

In the New Message To field, **↑ ↓** move through suggestions, **Return** adds the highlighted person and **⌫** removes the last one.

## Mouse and trackpad

- Click a conversation to open it or focus its tile; double-click an open one to close the tile. A grid icon marks open conversations. One row is highlighted at a time — the one under the pointer, or the keyboard's.
- Swipe a row left (or right-click it) to delete the conversation from Mosaic. It stays in Messages and returns with its next message.
- Drag a tile's header to move it; neighbors show the new order as you drag. Drag the gaps between tiles to resize them.
- Click anywhere in a tile to type in its composer. The smiley button opens Emoji & Symbols.
- Click a photo or video to open it; right-click for Finder. Right-click a bubble to copy its text or open its links.
- **Load earlier messages** at the top of a tile extends its history, up to 1,000 messages.

## Scope

Mosaic covers existing conversations and text replies. It reads `~/Library/Messages/chat.db` over a read-only SQLite connection and sends through Messages' AppleScript dictionary; no private frameworks are used.

- The sidebar lists the 500 most recent conversations plus any open ones. Search covers names, participants and previews.
- Plain text and common rich bodies are shown; unknown formats offer **Open in Messages**. Edits, unsends, formatting and tapbacks are not rendered.
- Attachments come from the copies Messages keeps locally; one never downloaded to this Mac says so. Link previews use LinkPresentation and are kept in memory.
- Attachments, reactions, calls and brand-new groups are done in Messages; **Open Messages** takes you there.
- Messages from one sender within fifteen minutes form a run with a single time stamp. **Delivered** / **Read** appears under the latest sent message once Messages reports it. Sends are never retried automatically.
- Mosaic does not write to Apple's database. Unread indicators are local to the session.
- The database schema is Apple's and undocumented; a macOS release may require an update.

## Privacy

Message history, thumbnails, link previews and contact names stay in memory. Mosaic stores only workspace layout and drafts, locally, in UserDefaults. Fetching a link preview is the only network request it makes. There is no analytics, backend or upload code. The demo workspace uses fictional data.

## Development

```sh
./scripts/test.sh          # unit and UI tests
./scripts/build-app.sh     # signed app → build/Mosaic.zip
./scripts/render-preview.sh docs/workspace.png   # the README screenshot, from demo data
```

CI runs the tests, builds the app and renders the preview on every push. Launch with `--demo` for the fictional workspace. After adding source files, run `python3 scripts/generate-xcode-project.py`.

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the window, tiles, scrolling and database reading are built, and why.
- [docs/VALIDATION.md](docs/VALIDATION.md) — what the tests cover and what still needs a real account.
