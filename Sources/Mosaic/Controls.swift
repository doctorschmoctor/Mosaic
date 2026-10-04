import SwiftUI
import AppKit

/// Mosaic has no motion: every workspace change takes effect on the next frame. This runs `changes`
/// in a transaction that suppresses any implicit SwiftUI animation that might otherwise apply.
@MainActor func instantly(_ changes: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    transaction.animation = nil
    withTransaction(transaction, changes)
}

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
