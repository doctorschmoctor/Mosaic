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
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("Cannot render preview") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode preview") }
        do { try png.write(to: URL(fileURLWithPath: output)); print("Rendered demo preview: \(output)") }
        catch { fatalError(error.localizedDescription) }
        exit(0)
    }
    app.run()
}
