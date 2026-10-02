# Validation

Validated locally with Swift 6.0.2 / Xcode 16.1 on Apple Silicon.

- SwiftPM debug compilation: passed.
- XCTest suite: 14 tests passed (10 core tests and 4 composer/bridge tests).
- Release app packaging and ad-hoc signature verification: passed.
- Native Xcode project: build verified separately.
- Native demo view rendered and inspected at 1320 × 860 points.
- Return, Shift–Return, independent demo sends, and AppleScript compilation tested without sending any real messages.

Tests use a synthetic SQLite database and fictional contacts. Real Messages history, transport behavior, and sending are not exercised by automated tests. Complete Full Disk Access and Automation setup, then test a conversation you choose before relying on the live bridge. Never use automated tests to send unsolicited messages.
