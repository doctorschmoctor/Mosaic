# Fix intermittent composer focus when opening a conversation

> Implemented (UX-12): `ComposerFocus` carries out the pending request described below; `FocusHandoffTests` hosts the workspace in a real window and checks the first responder. See docs/ARCHITECTURE.md. The investigation is kept for reference.

## Desired behavior

A single click on a conversation row, Return from the search field or keyboard-controlled list, and opening an already visible conversation must leave the insertion cursor in that conversation's composer. This also applies when a new conversation replaces the least recently used tile. A deliberate later click in search, the list, or another editor must keep the user's new focus.

## Diagnosis

The routing from the sidebar is now correct: `ConversationRow.activate` and `WorkspaceStore.activateSidebarSelection` call `openAndType`, which opens the tile and calls `requestComposerFocus`. The intermittent failure happens after that store-level request, at the AppKit focus handoff.

- `WorkspaceStore.requestComposerFocus` sets `focusTarget` and increments `focusToken` (`Sources/Mosaic/WorkspaceStore.swift`).
- `ConversationTile` passes that token to `ComposerEditor`. Its `makeNSView` / `updateNSView` records the token as handled and queues one `DispatchQueue.main.async` attempt (`Sources/Mosaic/ComposerEditor.swift`).
- `DraftTextView.requestFocus` calls `window.makeFirstResponder(self)` but ignores its Boolean result and does not check `window.firstResponder` afterward. It clears `pendingFocus` before the attempt. If the attempt fails, or if SwiftUI's row/button/search handling takes first responder later in the same opening cycle, nothing retries: the coordinator has already consumed the token.
- An editor that has not joined a window uses `pendingFocus` and retries once from `viewDidMoveToWindow`, but that callback is still fire-and-forget. A queued callback also does not check whether its token is still the latest request, so an older request can compete with a newer user action.

This explains why it usually works and sometimes leaves focus in the sidebar or elsewhere: success depends on the order of SwiftUI view installation, AppKit responder changes, and the deferred callback. The exact responder that wins a particular failed click needs a runtime trace; the lost-request path and missing verification are directly visible in the code.

The test added with the recent change, `testOpeningFromTheListPutsTheCursorInTheTile` in `Tests/MosaicUITests/WorkspaceInteractionTests.swift`, checks only `focusTarget` and `focusToken`. It cannot detect this issue because it never constructs an `NSWindow` or asserts its actual `firstResponder`.

## Implementation for Claude

1. Keep `openAndType` as the common entry point for row click, Return, context menu, and drop. Treat its focus token as a **pending request**, not proof that focus succeeded. Keep one current request identified by conversation ID and monotonically increasing token.
2. In the focus handoff, resolve the **current live** `DraftTextView` for that conversation after the tile has joined the intended `NSWindow`. Before every attempt, reject a request if the tile closed, the editor was replaced, the window differs, or a newer token exists. Do not let a closure holding an old editor act on a later request.
3. Request first responder outside `updateNSView` (the current deferral avoids a known layout crash). Check both `window.makeFirstResponder(editor)` and `window.firstResponder === editor`. Verify again after the opening event/view update has settled. A failed or displaced attempt must remain pending and retry when the editor attaches to a window or the window becomes key. Use lifecycle events plus a bounded next-run-loop retry if needed; do not use a fixed sleep as the correctness mechanism.
4. Mark the request complete only after the live editor is confirmed as first responder. Set the insertion point only then, preserving the current selection if this editor already owns focus. Cancel pending requests when the user deliberately focuses search, the list, another composer, or closes/replaces the target tile. A verification callback must check the token again so an old request cannot pull focus away from a newer choice.
5. Keep `focus(id)` (visual tile selection) distinct from successful keyboard focus. In particular, `DraftTextView.becomeFirstResponder` can continue to update the selected tile, but it should not itself create a new composer-focus request and loop.

## Validation

Add an AppKit/SwiftUI integration test that hosts `WorkspaceView` in a real `NSWindow`, invokes the same click and Return actions, drains the relevant event/layout turns, and asserts `window.firstResponder` is the **target `DraftTextView`** (and that its caret is editable). Cover a free slot, least-recently-used replacement, an already open tile, and switching rapidly between two rows. Add a case where search or another editor is deliberately focused immediately afterward and ensure a stale callback does not steal it. Run a repeated sequence to expose timing failures.

Keep the store test, but rename or describe it as a request-routing test; `focusTarget == id` does not establish cursor placement. A manual check should include mouse click and Return from both search and the keyboard-controlled list in Grid, Columns, and Focus layouts.

Useful temporary trace fields: request token/ID, `makeNSView`/`updateNSView`, `viewDidMoveToWindow`, `window.isKeyWindow`, `makeFirstResponder` result, and `window.firstResponder` immediately and on the next run loop. This will show which event wins on an observed failure.
