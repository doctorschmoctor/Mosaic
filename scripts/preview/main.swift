import AppKit
import SwiftUI

// Render the app's own view with fictional demo data. This captures the NSHostingView,
// never the user's desktop, real conversations, or another application.
extension Notification.Name { static let focusSearch = Notification.Name("Mosaic.focusSearch") }

MainActor.assumeIsolated {
    let output = CommandLine.arguments.dropFirst().first ?? "docs/workspace.png"
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
    let store = WorkspaceStore(defaults: UserDefaults(suiteName: "MosaicPreview-\(UUID())")!)
    if CommandLine.arguments.contains("--columns") { store.workspace.layout = .columns }
    if CommandLine.arguments.contains("--focus") { store.workspace.layout = .focus }
    if CommandLine.arguments.contains("--sms"), let chat = store.conversations.first {
        store.conversations[0] = Conversation(id: chat.id, databaseID: chat.databaseID, name: chat.name,
            participants: chat.participants, service: "SMS", preview: chat.preview, lastActivity: chat.lastActivity,
            unreadCount: chat.unreadCount, messages: chat.messages)
    }
    let view = WorkspaceView().environmentObject(store).frame(width: 1320, height: 860)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1320, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFront(nil)
    @MainActor func capture(_ path: String) {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        let bitmap = CommandLine.arguments.contains("--motion")
            ? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 860, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            : hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        guard let bitmap else { fatalError("Cannot render preview") }
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode preview") }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { fatalError(error.localizedDescription) }
    }
    if CommandLine.arguments.contains("--motion") {
        try! FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let ids = store.workspace.openIDs
        let last = ids.last!, first = ids.first!
        // Force root invalidation for this offscreen window; macOS normally defers
        // ObservableObject rendering while a window is completely occluded.
        @MainActor func invalidate() { withAnimation(Motion.layout) { hosting.rootView = view } }
        @MainActor func frame(_ index: Int) {
            switch index {
            case 6: store.close(last); invalidate()
            case 24: store.open(last, from: CGPoint(x: 128, y: 360)); invalidate()
            case 42:
                store.workspace.drafts[first] = "A smoother reply."
                Task { await store.send(first); withAnimation(Motion.message) { hosting.rootView = view } }
            case 60:
                let plan = TileLayout.plan(order: store.workspace.openIDs, viewport: CGSize(width: 1031, height: 828), layout: .grid)
                let a = plan.frames[first]!, b = plan.frames[last]!
                store.dragTile(first, translation: CGSize(width: b.midX - a.midX - 40, height: b.midY - a.midY - 20), plan: plan)
                invalidate()
            case 73: store.finishTileDrag(); invalidate()
            default: break
            }
            capture(URL(fileURLWithPath: output).appendingPathComponent(String(format: "frame-%03d.png", index)).path)
            if index == 90 { print("Rendered motion sequence: \(output)"); exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 18) { frame(index + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { frame(0) }
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hosting.rootView = view }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { capture(output); print("Rendered demo preview: \(output)"); exit(0) }
    }
    app.run()
}
