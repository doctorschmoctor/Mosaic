import SwiftUI
import AppKit

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Developer aid: launch with `--slow-motion` to inspect transitions frame by frame.
    static let speed: Double = ProcessInfo.processInfo.arguments.contains("--slow-motion") ? 6 : 1
    /// Developer comparison switch: interpolate every bubble during tile layout changes (off by default).
    static let animateMessageLayout = ProcessInfo.processInfo.arguments.contains("--animate-message-layout")
    static var layout: Animation { reduced ? .easeOut(duration: 0.12 * speed) : .smooth(duration: 0.5 * speed, extraBounce: 0.02) }
    static var close: Animation { reduced ? .easeOut(duration: 0.12 * speed) : .easeInOut(duration: 0.28 * speed) }
    static var message: Animation { reduced ? .easeOut(duration: 0.12 * speed) : .smooth(duration: 0.4 * speed) }
    static var control: Animation { .easeOut(duration: (reduced ? 0.1 : 0.18) * speed) }
}

struct TileControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !Motion.reduced ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Motion.control, value: configuration.isPressed)
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
