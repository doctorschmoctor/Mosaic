# Mosaic

Several Messages conversations, side by side, in one native macOS window.

![Mosaic workspace](docs/workspace.png)

Mosaic reads the conversations already on your Mac and lets you keep up to four of them open at once, each with its own history, draft and composer. Replies go out through Apple Messages. Nothing leaves your Mac.

## Features

- **Tiles** — Open up to four conversations in Grid, Columns or Focus layout. Opening a fifth takes the place of the tile you used longest ago (its draft and attached files are kept for next time). Drag a header to rearrange, drag the gaps to resize, close with ×. Open tiles, layout and drafts are restored on relaunch; nothing is sent at launch.
- **Drafts** — A conversation with something unsent says **Draft** in the sidebar, with its first line. Closing a tile (×, Esc or ⌘⇧W) never throws work away: a New Message you close keeps its recipients, text and files and waits under **Drafts** at the top of the sidebar, along with every conversation that has a draft; open it from there to carry on. **Discard Draft** (right-click a row or a tile's header) throws one draft away, and **Undo** (or ⌘Z) brings it back for a few seconds. A file you chose is never deleted.
- **Find in a conversation** — ⌥⌘F opens a find bar in the focused tile: the messages it has loaded are searched as you type (case and accents ignored), every match is marked, and Return / ⇧Return (or ⌘G / ⇧⌘G, or the arrows) move to the older or newer match. **Search older messages** looks further back, through the conversation's history on this Mac a couple of thousand messages at a time (**Search Further** goes on); choosing an older result shows the messages around it, and **Back to Latest** returns. It matches the words of messages — plain and rich text — not attachments or earlier versions of edited messages; nothing is indexed or saved, and nothing in an older window counts as read.
- **Conversation details** — ⌘I (or a tile header's menu › **Conversation Details**) shows the people in a conversation with the addresses Messages sends to, and the photos and videos, files and links in its loaded messages, newest first. Click one to preview it (or open a link); right-click for the usual actions or **Show in Conversation**. A tile that has reached its 1,000-message limit says so at the top, with **Search Older Messages**.
- **What needs attention** — The sidebar's **Unread**, **Needs Reply** (the flag) and **Drafts** filters list just those conversations, each with a count. **Mark as Needs Reply** (right-click a row or a tile's header, or ⌘⇧R) is your own reminder: reading the conversation keeps it until you clear it. **Go to Next Unread** (⌘⌥U) opens the next conversation with something unread. Focus chips show a blue dot for unread and an orange one for a draft. Unread is Mosaic's own: a message counts as read only once its tile shows it while Mosaic is in front and the tile is on screen; Messages is never told and no read receipt is sent.
- **Pins and protected tiles** — Right-click a conversation and choose **Pin to Top** to keep it at the top of Mosaic's sidebar (Messages' own pins are untouched; a pinned conversation is listed however old it is). Right-click a tile's header and choose **Protect from Replacement** to keep that tile open when a fifth conversation needs room; a lock marks it. When every tile is protected, Mosaic asks which one to close — showing which have drafts — or lets you cancel.
- **New messages** — Address a new message to one person or several, from your contacts or any existing conversation. Mosaic finds the matching conversation or hands the new one to Messages.
- **Pictures and files** — Paste or drop a picture into a composer, pick from your Photos library, or choose a file. They go out through Messages like anything else, and received pictures can be copied or saved with a right-click.
- **Live** — New messages appear within a moment of arriving; your replies show at once and keep their place when Messages confirms them. Tiles open on their messages at once: recent conversations are fetched ahead, and recently shown histories stay cached in memory.
- **Reactions, replies, edits** — Tapbacks others send (including custom emoji) show as badges on the message, with who reacted on click; replies show what they answer and jump to it; edited messages are marked and unsent ones become a note. Unread counts are counted per message.
- **Media and links** — Photo and video thumbnails, file chips, and link previews, all sized before they load so nothing jumps.
- **Contact names** — Phone numbers and addresses become names with Contacts access. Names stay in memory.
- **Zoom** — ⌘+ / ⌘− / ⌘0 scale every conversation together: text, bubbles, media and the composer, in all tiles at once. Tiles, sidebar and window keep their size.
- **Instant** — Tiles open, close, move, resize and switch on the next frame, with no animation. The one motion is a new message settling into its thread (a subtle fade; off in Settings or with Reduce Motion).

## Install

Requires macOS 14 or later on Apple silicon.

1. Download the disk image from the [latest release](https://github.com/doctorschmoctor/Mosaic/releases/latest) and open it.
2. Drag **Mosaic** onto the **Applications** folder beside it.
3. Open Mosaic from Applications. macOS will say it can't verify the app the first time, because the build is signed locally rather than notarized with Apple. Allow it once: on macOS 15, close the warning, open **System Settings › Privacy & Security**, scroll down and press **Open Anyway**; on macOS 14, right-click Mosaic in Applications and choose **Open**.

Or with [Homebrew](https://brew.sh):

```sh
brew install --cask doctorschmoctor/mosaic/mosaic
brew upgrade --cask mosaic      # later versions
```

### Build it yourself

Xcode 16 / Swift 6; no dependencies.

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
5. **Photos** (optional) — The first time you open the + button's Photos grid, macOS asks to let Mosaic see your library.

Messages must already be signed in. SMS/RCS availability follows your Messages setup.

## Keyboard

| | |
|---|---|
| **⌘N** | New message |
| **⌘F** | Find a conversation — **Return** opens the first match, **↓** moves into the list, **Esc** clears |
| **⌥⌘F** | Find in the focused conversation — **Return / ⇧Return** older / newer match, **Esc** closes |
| **⌘G / ⇧⌘G** | Older / newer match in the open find bar |
| **⌘I** | Details of the focused conversation: people, photos and videos, files, links |
| **⌘L** | Conversation list — **↑ ↓** move the highlight, **Return** opens or focuses, **⌫** closes the row's tile, **Esc** back to the composer |
| **Tab / ⇧Tab** | Next / previous tile |
| **Return** | Send · **⇧Return** inserts a line break |
| **Esc** | Close a New Message tile (it is kept in Drafts) |
| **⌘+ / ⌘− / ⌘0** | Zoom the conversations in · out · back to 100% (all tiles together) |
| **⌘⌥1 · ⌘⌥2 · ⌘⌥3** | Grid · Columns · Focus |
| **⌥⌘← / ⌥⌘→** | Move the focused tile one place earlier / later |
| **⌃⌥⌘← → ↑ ↓** | Make the focused tile narrower · wider · shorter · taller (**Workspace › Equal Tile Sizes** evens them out) |
| **⌃⌘1 – ⌃⌘4** | Sidebar: All · Unread · Needs Reply · Drafts |
| **⌘⇧W** | Close the focused tile |
| **⌘⇧T** | Reopen the tile closed last, with its draft |
| **⌘⌥U** | Go to the next conversation with something unread |
| **⌘⇧R** | Mark the focused conversation as Needs Reply, or clear it |
| **⌘Z** | Undo hiding a conversation or discarding a draft (while the sidebar offers it) |
| **⌘R** | Refresh |
| **⌘,** | Settings |

In the New Message To field, **↑ ↓** move through suggestions, **Return** adds the highlighted person and **⌫** removes the last one; **Esc** clears what you were typing first, then closes the tile (keeping it in Drafts). While an input method is composing (Japanese, Chinese, a held-down accent), every key — Tab, Esc, the arrows, ⌘F — goes to the composition.

With VoiceOver, a message reads who wrote it, and its actions (VO-⌘-Space) are **Copy**, **Open** for each link and **Try Again** for one Messages refused; a reply's quote offers **Show Original**. Focus chips, tile buttons and the sidebar's filters are buttons with their full names, even when a narrow window cuts a chip's name (its tooltip shows it too).

## Mouse and trackpad

- Click a conversation to open it or focus its tile; double-click an open one to close the tile. With four tiles open, the one you used longest ago — opened, focused, typed in or sent from — makes room, in its own place. A grid icon marks open conversations. Rows are highlighted only while the keyboard is on the list (⌘L); the pointer highlights nothing.
- Swipe a row left (or right-click it) and choose **Hide** to take the conversation out of Mosaic's sidebar. Nothing changes in Messages; **Undo** brings it back at once, **Workspace › Hidden Conversations…** (or the eye button at the top of the sidebar) restores it later, and its next message brings it back by itself. Closing a tile is different: the conversation stays in the sidebar, and **⌘⇧T** reopens it.
- Drag a tile's header to move it; neighbors show the new order as you drag. Drag the gaps between tiles to resize them.
- Click anywhere in a tile to type in its composer. The smiley button opens Emoji & Symbols.
- The **+** button at the left of the composer opens a grid of your Photos library (newest first; click to choose, **Add** to attach) or a file chooser; you can also paste a picture (⌘V) or drop pictures and files on the field. They appear above the text, with a remove badge, and go out with the next Return — each file as its own message, before the text. Click one to preview it in Quick Look (the arrow keys step through the others in order). A photo still arriving shows how much has come when it is downloading from iCloud, and its badge stops it; one that could not be added says why and, if Photos still has it, offers **Retry**.
- Click a photo, video or file to preview it in Quick Look (arrow keys step through the conversation's attachments; Esc closes); right-click to open it in its app, copy it, save it to Downloads or elsewhere, or show it in Finder. Right-click a bubble to copy its text or open its links.
- Click a reply's quote line to jump to the original; click a reaction badge to see who reacted. While you read older messages, new ones are counted on the **N new** button and marked with a New Messages line.
- Scrolling near the top of a tile loads earlier messages by themselves, up to 1,000.

## Scope

Mosaic covers existing conversations and text replies. It reads `~/Library/Messages/chat.db` over a read-only SQLite connection and sends through Messages' AppleScript dictionary; no private frameworks are used.

- The sidebar lists the 500 most recent conversations plus any open ones. Search covers names, participants and previews.
- Plain text and common rich bodies are shown; unknown formats offer **Open in Messages**. Formatting is not rendered. Reactions are shown on the whole message (not the exact part of a multi-part message); an edit shows the current text with an Edited mark, not the history.
- Attachments come from the copies Messages keeps locally; one never downloaded to this Mac says so. Link previews use LinkPresentation and are kept in memory for recent links; a preview that could not load is tried again later.
- Sending reactions, threaded replies, edits and unsends, calls and brand-new groups is done in Messages — its scripting dictionary sends only text and files; **Reply in Messages** and **Open Messages** take you there.
- Photos' own search (people, places, things) is not available to other apps, so the Photos grid is a plain library view.
- Messages from one sender within fifteen minutes form a run with a single time stamp. **Delivered** / **Read** appears under the latest sent message once Messages reports it. Sends are never retried automatically.
- Mosaic does not write to Apple's database or send read receipts. Its unread counts are its own: incoming messages after the newest one you had in view — counted as seen only while Mosaic is the active app, its window is on screen, and the tile is in view (in Columns, scrolled into the window; in Focus, the one shown).
- The database schema is Apple's and undocumented; a macOS release may require an update.

## Privacy

Message history, thumbnails, link previews and contact names stay in memory. Mosaic stores only workspace layout and drafts (text, New Message recipients, and the paths of files waiting in a composer), locally, in UserDefaults. Pictures you paste or pick wait in `~/Library/Application Support/Mosaic/Outgoing` until sent or discarded; at send time each file is copied briefly into `~/Library/Messages/.mosaic-outgoing`, the only place Messages' sandbox reads attachments from, and removed again a few minutes later. Fetching link previews is the only network request Mosaic makes itself — **Settings › Privacy & Data › Link previews** sets it to Automatic (the default), On Click (a link shows its address until you press Show Preview) or Off (nothing is fetched); Photos may download an iCloud original when you add one that is not on this Mac. The same pane shows what each permission is set to (without asking for any), clears the in-memory media cache, and lists your drafts with **Clear** (Undo right after; a file you chose is never deleted). There is no analytics, backend or upload code. The demo workspace uses fictional data.

## Development

```sh
./scripts/test.sh          # unit and UI tests (a fixture run: no Contacts, no real files, no sending)
./scripts/build-app.sh     # signed app → build/Mosaic.zip
./scripts/render-preview.sh docs/workspace.png   # the README screenshot, from demo data
```

CI runs the tests, builds the app and renders the preview on every push. Launch with `--demo` for the fictional workspace. Tests, the preview renderer and `--demo` / `--isolated` launches (or `MOSAIC_ISOLATED=1`) are fixture runs: they never read the Mac's Contacts or ask for a permission, never read the signed-in Messages database unless given one, keep outgoing files and preferences apart from the installed app's, and cannot send. `scripts/test.sh` stops a run that goes `MOSAIC_TEST_STALL_SECONDS` (300) without output and names the test it stalled in. After adding source files, run `python3 scripts/generate-xcode-project.py`.

To publish a release: set the version in `Resources/Info.plist` (`CFBundleShortVersionString`, and raise `CFBundleVersion`), commit and push, then either press **Run workflow** on the *macOS build and tests* workflow in GitHub Actions (it tags the commit `v<version>`) or tag the commit `v<version>` yourself and push the tag. CI builds and tests as usual, packages the app as a disk image (`scripts/make-dmg.sh`, which mounts the image and verifies the signature inside), and publishes a GitHub Release with the `.dmg` and `.zip`; the notes come from `docs/releases/<version>.md` when that file exists, else from the commit subjects since the previous release. Running the workflow again on a released commit replaces that release's notes and files; from a later commit, choose **republish** to replace the release with that commit (its tag moves). The same run updates the Homebrew cask in [doctorschmoctor/homebrew-mosaic](https://github.com/doctorschmoctor/homebrew-mosaic) (`scripts/write-cask.sh`: version and the disk image's checksum), using the `HOMEBREW_TAP_TOKEN` secret — a fine-grained token with Contents read and write on that repository; without the secret the release is published and the tap is left as it was. The build is ad-hoc signed; to ship without the Gatekeeper warning, sign with a Developer ID (`MOSAIC_SIGNING_IDENTITY` in `build-app.sh`) and notarize.

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the window, tiles, scrolling and database reading are built, and why.
- [docs/VALIDATION.md](docs/VALIDATION.md) — what the tests cover and what still needs a real account.
