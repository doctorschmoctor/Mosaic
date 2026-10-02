import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 32)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect your Messages").font(.system(size: 23, weight: .semibold))
                    Text("The chats on your Mac, with room to breathe.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Close connection settings")
            }
            Text("Mosaic uses the Messages account already signed in on this Mac. History stays on your computer. Apple Messages handles delivery.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            step("1", "Give Mosaic access to history", "In Full Disk Access, press + and add this Mosaic.app. Enable it, then quit and reopen Mosaic.") {
                HStack { Button("Open Full Disk Access") { store.openPrivacy("Privacy_AllFiles") }; Button("Show Mosaic in Finder") { store.revealApp() } }
            }
            step("2", "Connect to Messages", "Read the conversations already synced to this Mac. Refreshes every three seconds while Mosaic is running.") {
                HStack {
                    Button(store.isLive ? "Refresh connection" : "Connect Messages") {
                        if store.isLive { Task { await store.refresh() } } else { store.setMode(live: true) }
                    }.buttonStyle(.borderedProminent).tint(Palette.accent)
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                }
            }
            step("3", "Allow sending when prompted", "Your first send asks permission to control Messages. Allow it to send from a tile. You can manage it in Automation settings.") {
                HStack { Button("Open Automation") { store.openPrivacy("Privacy_Automation") }; Button("Open Messages") { store.openMessages() } }
            }
            step("+", "Use contact names (optional)", "Allow Contacts access to show names instead of phone numbers. Names are kept in memory for this session.") {
                Button("Load contact names") { Task { await store.loadContacts() } }
            }
            if let error = store.connectionError { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button("Use demo workspace") { store.setMode(live: false); dismiss() }
                Spacer()
                Text("Text replies · Existing chats").font(.caption).foregroundStyle(.tertiary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 590).tint(Palette.accent)
    }
    private func step<Content: View>(_ number: String, _ title: String, _ description: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 26, height: 26).background(Palette.accent.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content().controlSize(.small)
            }
        }
    }
}
