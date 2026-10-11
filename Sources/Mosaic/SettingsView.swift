import SwiftUI
import AppKit
import CoreServices
import Photos
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// Mosaic › Settings: the connection to Messages; how conversations look; and what Mosaic may
/// use and keeps on this Mac. Opening any of it never asks for a permission.
struct SettingsView: View {
    var body: some View {
        TabView {
            SetupView().tabItem { Label("Connection", systemImage: "bubble.left.and.bubble.right") }
            AppearanceSettings().tabItem { Label("Appearance & Input", systemImage: "textformat.size") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            PrivacySettings().tabItem { Label("Privacy & Data", systemImage: "hand.raised") }
        }
    }
}

struct AppearanceSettings: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        Form {
            Section {
                Toggle("Animate new messages", isOn: Binding(get: { store.animateMessages }, set: { store.animateMessages = $0 }))
                Text("A new message settles into its thread with a short fade. With Reduce Motion on in System Settings, only the fade remains.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 220)
    }
}

/// Mosaic's own notifications, off until turned on: what they show, which conversations are
/// muted, and what macOS allows. Turning them on is the only place Mosaic asks for permission.
struct NotificationSettings: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var working = false

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new messages", isOn: Binding(get: { store.notificationsEnabled }, set: { on in
                    working = true
                    Task { await store.setNotificationsEnabled(on); working = false }
                }))
                .disabled(working)
                if store.notificationPermission == .denied {
                    HStack {
                        Text("Notifications are off for Mosaic in System Settings.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Notification Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Picker("Show", selection: Binding(get: { store.notificationPreview }, set: { store.notificationPreview = $0 })) {
                    ForEach(NotificationPreview.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!store.notificationsEnabled)
                Text("A message notifies once, unless you can already see its conversation in a tile. Reactions, your own messages and older history never notify.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Messages can notify you as well; to be told about each message once, turn off Messages' notifications in System Settings › Notifications.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Muted conversations") {
                let muted = store.mutedConversations
                if muted.isEmpty {
                    Text("None. Right-click a conversation to mute it here; Messages is not changed.").foregroundStyle(.secondary)
                } else {
                    ForEach(muted, id: \.id) { entry in
                        HStack {
                            Text(entry.name).lineLimit(1)
                            Spacer()
                            Text(entry.until == .distantFuture ? "Until unmuted" : "Until \(entry.until.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                            Button("Unmute") { store.unmute(entry.id) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 420)
        .task { await store.refreshNotificationPermission() }
    }
}

/// What Mosaic may use (each permission as macOS has it now — nothing is asked from here), whether
/// link previews are fetched, and what Mosaic keeps on this Mac, with ways to clear it.
struct PrivacySettings: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var automation = AutomationAccess.Status.unknown
    @State private var photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var reviewingDrafts = false
    @State private var clearedCache = false

    var body: some View {
        Form {
            Section("Permissions") {
                permission("Messages history", historyText, ok: store.isLive && store.connectionError == nil && !store.conversations.isEmpty) {
                    Button("Full Disk Access…") { store.openPrivacy("Privacy_AllFiles") }
                }
                permission("Sending", automationText, ok: automation == .allowed) {
                    Button("Automation…") { store.openPrivacy("Privacy_Automation") }
                }
                permission("Contacts", contactsText, ok: store.contactAuthorization == .authorized) {
                    Button("Contacts…") { store.openPrivacy("Privacy_Contacts") }
                }
                permission("Photos", photosText, ok: photos == .authorized || photos == .limited) {
                    Button("Photos…") { store.openPrivacy("Privacy_Photos") }
                }
                Text("macOS asks for each one the first time Mosaic needs it; these buttons only open System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Link previews") {
                Picker("Link previews", selection: Binding(get: { store.linkPreviews }, set: { store.linkPreviews = $0 })) {
                    ForEach(LinkPreviewPolicy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(linkPreviewText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("On this Mac") {
                Text("Drafts — unsent text, New Message recipients and the files waiting in composers — are kept in Mosaic's preferences. Pictures you paste or pick wait in ~/Library/Application Support/Mosaic/Outgoing until they are sent or discarded. Message history, pictures and previews are kept in memory only.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Unread, pins and hidden conversations are Mosaic's own: nothing is marked read or changed in Messages, and no read receipt is sent.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Adding a photo that is only in iCloud makes Photos download the original.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Review Drafts…") { reviewingDrafts = true }
                    Button(clearedCache ? "Media Cache Cleared" : "Clear Media Cache") {
                        store.clearMediaCaches()
                        clearedCache = true
                    }
                    .disabled(clearedCache)
                    .help("Lets go of the pictures, link previews and contact photos kept in memory; drafts and waiting files stay")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 560)
        .task {
            automation = await AutomationAccess.status()
            photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        .sheet(isPresented: $reviewingDrafts) { DraftReviewView().environment(store) }
    }

    private func permission<Actions: View>(_ title: String, _ detail: String, ok: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }

    private var historyText: String {
        if !store.isLive { return "Using the demo workspace; your conversations are not read." }
        if let error = store.connectionError { return "Can't read Messages: \(error)" }
        return store.conversations.isEmpty ? "Not read yet." : "Reading the conversations on this Mac (read-only)."
    }
    private var automationText: String {
        switch automation {
        case .allowed: return "Mosaic may hand messages to Messages."
        case .denied: return "Off: turn on Mosaic › Messages in Automation to send."
        case .notAsked: return "Asked the first time you send."
        case .unknown: return "Checked when you send (Messages isn't open now)."
        }
    }
    private var contactsText: String {
        switch store.contactAuthorization {
        case .authorized: return "Names come from Contacts and stay on this Mac."
        case .denied: return "Off: numbers and addresses show instead of names."
        case .restricted: return "Restricted on this Mac."
        default: return "Not asked yet: allow it from the Connection tab to see names."
        }
    }
    private var photosText: String {
        switch photos {
        case .authorized: return "The + button's Photos grid shows your library."
        case .limited: return "Only the photos you chose are shown."
        case .denied, .restricted: return "Off: choose files instead, or turn it on in System Settings."
        default: return "Asked the first time you open the Photos grid."
        }
    }
    private var linkPreviewText: String {
        switch store.linkPreviews {
        case .automatic: return "Each link's title and picture are fetched from its site as the conversation shows it."
        case .onClick: return "Links show their address; a preview is fetched from the site only when you press Show Preview."
        case .off: return "Nothing is fetched: links show their address and open in your browser."
        }
    }
}

/// The drafts Clear would remove, then Clear All (with Undo right after). A file you chose stays
/// where it is; pictures Mosaic made for a draft are removed once Undo has passed.
struct DraftReviewView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = store.draftRows
        VStack(alignment: .leading, spacing: 12) {
            Text("Drafts").font(.system(size: 17, weight: .semibold))
            Text("Clearing removes the unsent text, New Messages and files waiting in these composers. Files you chose stay where they are; pictures Mosaic made for a draft are removed. You can undo right after.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                Text("There are no drafts.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(store.draftSummaries[row.id]?.line ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(rows.count > 1 ? "Clear \(rows.count) Drafts" : "Clear Draft", role: .destructive) {
                    store.discardDrafts(rows.map(\.id))
                    dismiss()
                }
                .disabled(rows.isEmpty)
            }
        }
        .padding(24).frame(width: 440)
    }
}

/// Whether Mosaic may send Apple events to Messages, asked of macOS without prompting.
enum AutomationAccess {
    enum Status: Equatable { case allowed, denied, notAsked, unknown }
    static func status() async -> Status {
        await Task.detached(priority: .utility) { () -> Status in
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
            guard let descriptor = target.aeDesc else { return .unknown }
            let result = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false)
            switch result {
            case OSStatus(noErr): return .allowed
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
            default: return .unknown
            }
        }.value
    }
}
