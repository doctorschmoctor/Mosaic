import SwiftUI
import AppKit
import Quartz

/// Opens attachments in the system Quick Look panel — the same viewer as pressing Space in the
/// Finder — instead of handing them to their default app. The panel shows every attachment of the
/// conversation, so the arrow keys step through them; Esc or Space closes it.
@MainActor final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private(set) var items: [URL] = []
    private(set) var index = 0

    /// Shows `url`, with the rest of `siblings` (the conversation's attachments) a key press away.
    func show(_ url: URL, among siblings: [URL] = []) {
        var list = siblings.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !list.contains(url) { list = [url] + list }
        items = list
        index = list.firstIndex(of: url) ?? 0
        guard let panel = QLPreviewPanel.shared() else { NSWorkspace.shared.open(url); return }
        take(panel)
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
    }
    /// Takes the panel over (also called by the app delegate when the panel looks for a controller
    /// along the responder chain).
    func take(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }
    func release(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { items.indices.contains(index) ? items[index] as NSURL : nil }
    }
}

/// The conversation's attachment files, for Quick Look's next and previous.
private struct ThreadAttachmentsKey: EnvironmentKey { static let defaultValue: [URL] = [] }
extension EnvironmentValues {
    var threadAttachments: [URL] {
        get { self[ThreadAttachmentsKey.self] }
        set { self[ThreadAttachmentsKey.self] = newValue }
    }
}
