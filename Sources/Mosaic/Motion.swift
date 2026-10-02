import SwiftUI
import AppKit

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var layout: Animation { reduced ? .easeOut(duration: 0.12) : .smooth(duration: 0.58, extraBounce: 0.04) }
    static var close: Animation { reduced ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.3) }
    static var message: Animation { reduced ? .easeOut(duration: 0.12) : .smooth(duration: 0.4) }
    static var control: Animation { .easeOut(duration: reduced ? 0.1 : 0.18) }
}

struct TileControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !Motion.reduced ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Motion.control, value: configuration.isPressed)
    }
}
