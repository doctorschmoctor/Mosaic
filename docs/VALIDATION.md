# Validation

Validated locally with Swift 6.0.2 / Xcode 16.1 on Apple Silicon.

- SwiftPM debug compilation: passed.
- XCTest suite: 28 tests passed (22 core tests and 6 UI/bridge tests), including contact matching and address-only chats, immediate contact updates during refresh, tile resizing and minimum sizes, drag previews, draft preservation, and stable bubble identities during confirmation.
- Release archive packaging and ad-hoc signature verification: passed (verified before archiving and again after extracting outside the synced Desktop).
- Native Xcode project: build verified separately.
- Native demo view rendered and inspected at 1320 × 860 points in light and dark appearances, including floating Grid/Columns tiles and a synthetic SMS conversation to verify green outgoing bubbles.
- Offscreen native motion sequence inspected for closing in place, expanding neighboring cards, growing/moving new cards, outgoing bubble insertion, drag previews, and settling into the new grid order. The sequence uses fictional demo data and drives the same workspace actions as the UI.
- Return, Shift–Return, independent demo sends, and AppleScript compilation tested without sending any real messages.

Tests use a synthetic SQLite database and fictional contacts. Real Contacts permissions and records, Messages history, transport behavior, and sending are not exercised by automated tests. Complete Full Disk Access, Contacts, and Automation setup, then test a conversation you choose before relying on the live bridge. Never use automated tests to send unsolicited messages.
