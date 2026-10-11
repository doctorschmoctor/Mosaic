import SwiftUI
import AppKit
import os

/// Mosaic has no motion: every workspace change takes effect on the next frame. This runs `changes`
/// in a transaction that suppresses any implicit SwiftUI animation that might otherwise apply.
///
/// One action's changes belong in one transaction. SwiftUI applies what is waiting at once, in
/// the middle of the next change, when that change comes in a different transaction — so an
/// action that changed some things outside `instantly` and others inside it made SwiftUI update
/// the window halfway through. A call inside another runs in the outer one's transaction.
@MainActor func instantly(_ changes: () -> Void) {
    guard instantlyDepth == 0 else { changes(); return }
    instantlyDepth += 1
    defer { instantlyDepth -= 1 }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    transaction.animation = nil
    withTransaction(transaction, changes)
}
@MainActor private var instantlyDepth = 0

struct TileControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Shows a cursor while the pointer is over the view. Push/pop keeps AppKit's cursor stack balanced, so
/// leaving a resize handle never overrides the I-beam that a neighboring text field set.
struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    var enabled = true
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in inside && enabled ? push() : pop() }
            .onChange(of: enabled) { _, isEnabled in if !isEnabled { pop() } }
            .onDisappear { pop() }
    }
    private func push() { guard !pushed else { return }; cursor.push(); pushed = true }
    private func pop() { guard pushed else { return }; NSCursor.pop(); pushed = false }
}

extension View {
    func hoverCursor(_ cursor: NSCursor, enabled: Bool = true) -> some View { modifier(HoverCursor(cursor: cursor, enabled: enabled)) }
}

/// The shared conversation-content scale (⌘+ / ⌘− / ⌘0). Tiles' frames, the sidebar and the
/// window chrome keep their size; what a conversation shows — text, bubbles, media, the composer
/// — reads its metrics through this.
private struct ZoomScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var zoomScale: CGFloat {
        get { self[ZoomScaleKey.self] }
        set { self[ZoomScaleKey.self] = newValue }
    }
}

/// What the tile area does, for diagnosing layout problems: closes, the workspace's plan, the
/// canvas placing its tiles, headers joining and leaving the window, refreshes. Counts and frames
/// only — never a conversation, a name or an address. Silent unless debug messages of the
/// "tiles" category are being collected:
///   log stream --level debug --predicate 'subsystem == "com.doctorschmoctor.Mosaic" && category == "tiles"'
/// The app check (scripts/appcheck) prints them through `sink`.
enum TileTrace {
    static let log = OSLog(subsystem: "com.doctorschmoctor.Mosaic", category: "tiles")
    nonisolated(unsafe) static var sink: ((String) -> Void)?
    static func note(_ message: @autoclosure () -> String) {
        if let sink { sink(message()) }
        guard log.isEnabled(type: .debug) else { return }
        os_log(.debug, log: log, "%{public}@", message())
    }
    static func frames(_ frames: [CGRect]) -> String {
        frames.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" }.joined(separator: " ")
    }
}
