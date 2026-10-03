import AppKit
import SwiftUI

// Render the app's own view with fictional demo data. This captures the NSHostingView,
// never the user's desktop, real conversations, or another application.
// Usage: MosaicPreview [output.png] --demo [--dark] [--columns|--focus] [--sms] [--scale N] [--settle SECONDS]

MainActor.assumeIsolated {
    let output = CommandLine.arguments.dropFirst().first ?? "docs/workspace.png"
    func option(_ name: String, default fallback: Double) -> Double {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1),
              let value = Double(CommandLine.arguments[index + 1]) else { return fallback }
        return value
    }
    let scale = CGFloat(option("--scale", default: 2))
    // Link previews and thumbnails load asynchronously; the capture waits for them to settle.
    let settle = option("--settle", default: 6)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
    let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicPreview-\(UUID())")!)
    if CommandLine.arguments.contains("--columns") { store.layout = .columns }
    if CommandLine.arguments.contains("--focus") { store.layout = .focus }
    if CommandLine.arguments.contains("--sms"), let chat = store.conversations.first {
        store.conversations[0] = Conversation(id: chat.id, databaseID: chat.databaseID, name: chat.name,
            participants: chat.participants, service: "SMS", preview: chat.preview, lastActivity: chat.lastActivity,
            unreadCount: chat.unreadCount, messages: chat.messages)
    }
    let view = WorkspaceView().environment(store).frame(width: 1320, height: 860)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1320, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFront(nil)
    @MainActor func capture(_ path: String) {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        // A bitmap at the requested scale (2x by default, a Retina screenshot) whatever display
        // the renderer runs on; cacheDisplay draws at the bitmap's resolution.
        let bounds = hosting.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Cannot render preview") }
        bitmap.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode preview") }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { fatalError(error.localizedDescription) }
    }
    do {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hosting.rootView = view }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { capture(output); print("Rendered demo preview: \(output)"); exit(0) }
    }
    app.run()
}
