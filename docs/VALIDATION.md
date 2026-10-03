# Validation

Validated locally with Swift 6.0.2 / Xcode 16.1 on Apple Silicon.

- SwiftPM debug compilation: passed.
- XCTest suite: 34 tests (22 core tests and 12 UI/bridge tests), including contact matching and address-only chats, immediate contact updates during refresh, tile resizing and minimum sizes, drag previews, draft preservation, stable bubble identities during confirmation, AppKit title-bar chrome, header close/focus/drag hit testing, focus-chip selection, rapid open/close churn, and keyboard traversal. Run `./scripts/test.sh`; CI runs it on every push.
- Release archive packaging and ad-hoc signature verification: passed (verified before archiving and again after extracting outside the synced Desktop).
- Native Xcode project: build verified separately.
- Native demo view rendered and inspected at 1320 × 860 points in light and dark appearances, including floating Grid/Columns tiles and a synthetic SMS conversation to verify green outgoing bubbles.
- No animations: workspace changes are applied in transactions that disable animation, and the view tree disables implicit animation at its root. The former offscreen motion sequence was removed with the motion.
- Crash fix (0.2.1): five crash reports from 2026-10-02 showed `NSInternalInconsistencyException` raised from `-[NSWindow _postWindowNeedsUpdateConstraints]` during `NSHostingView.updateConstraints` (a nested hosting view five levels inside the title bar) while histories loaded and while tiles opened and closed quickly. The SwiftUI toolbar item was replaced by an empty AppKit toolbar, all `NSViewRepresentable`s now size from the layout proposal, focus requests are deferred out of SwiftUI updates, and `NSApplicationCrashOnExceptions` is off so a repeat would be logged, not fatal.
- Return, Shift–Return, independent demo sends, and AppleScript compilation tested without sending any real messages.

Tests use a synthetic SQLite database and fictional contacts. Real Contacts permissions and records, Messages history, transport behavior, and sending are not exercised by automated tests. Complete Full Disk Access, Contacts, and Automation setup, then test a conversation you choose before relying on the live bridge. Never use automated tests to send unsolicited messages.
