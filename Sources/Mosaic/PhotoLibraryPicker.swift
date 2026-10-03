import SwiftUI
import AppKit
import Photos

/// Mosaic's own Photos picker: a plain grid of the library's pictures and videos, newest first,
/// with a Cancel/Add footer and nothing else. (The system picker's card carries a selection
/// label, a location notice and option buttons that cannot be removed, and its scroll bar grows
/// under the pointer.) Needs Photos access, asked for the first time the picker opens.
struct PhotoLibraryPickerView: View {
    static let size = NSSize(width: 356, height: 560)
    static let columns = 3
    static let cellSize: CGFloat = 110
    let onCancel: () -> Void
    let onAdd: ([PHAsset]) -> Void
    @State private var model = PhotoLibraryModel()

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if model.status == .limited {
                    Text("Only the photos chosen for Mosaic in Privacy & Security are shown.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(PickerButtonStyle(prominent: false))
                Button(model.selectedIDs.count > 1 ? "Add \(model.selectedIDs.count)" : "Add") { onAdd(model.selectedAssets) }
                    .buttonStyle(PickerButtonStyle(prominent: true))
                    .disabled(model.selectedIDs.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.status {
        case .authorized, .limited:
            if model.count == 0 {
                Text("No photos yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellSize), spacing: 4), count: Self.columns), spacing: 4) {
                        ForEach(0..<model.count, id: \.self) { index in
                            let asset = model.asset(at: index)
                            PhotoCell(asset: asset, manager: model.manager, selected: model.isSelected(asset.localIdentifier)) {
                                model.toggle(asset.localIdentifier)
                            }
                        }
                    }
                    .padding(8)
                    // The slim scroller the rest of Mosaic has: it does not grow under the pointer.
                    .background(ThinScrollerInstaller())
                }
                .scrollIndicators(.automatic)
            }
        case .notDetermined:
            ProgressView().controlSize(.small)
        default:
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Text("Mosaic can't see your photos").font(.headline)
                Text("Turn on Mosaic in System Settings › Privacy & Security › Photos, then open this again.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Photos Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            }.padding(24)
        }
    }
}

/// One square of the grid: the thumbnail, a check when chosen, a duration for a video.
private struct PhotoCell: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let selected: Bool
    let onTap: () -> Void
    @State private var image: NSImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        ZStack {
            Rectangle().fill(Palette.incoming)
            if let image { Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill) }
        }
        .frame(width: PhotoLibraryPickerView.cellSize, height: PhotoLibraryPickerView.cellSize)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if asset.mediaType == .video {
                Text(PhotoLibraryModel.duration(asset.duration)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .shadow(radius: 2).padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Palette.accent).padding(4)
            }
        }
        .overlay { if selected { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.accent, lineWidth: 2) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .onAppear(perform: load)
        .onDisappear { if let request { manager.cancelImageRequest(request); self.request = nil } }
    }
    private func load() {
        guard image == nil, request == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let pixels = PhotoLibraryPickerView.cellSize * 2
        request = manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill, options: options) { result, _ in
            guard let result else { return }
            Task { @MainActor in image = result }
        }
    }
}

/// The footer's buttons: a light fill, lighter still when disabled.
struct PickerButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(minWidth: 72).frame(height: 28)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    private func fill(pressed: Bool) -> Color {
        if prominent { return Palette.accent.opacity(!isEnabled ? 0.3 : pressed ? 0.75 : 0.9) }
        return Color.primary.opacity(pressed ? 0.14 : 0.08)
    }
}

/// The library behind the picker: access, the assets newest first, and the selection.
@Observable @MainActor final class PhotoLibraryModel {
    private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets: PHFetchResult<PHAsset>?
    private(set) var selectedIDs: [String] = []
    let manager = PHCachingImageManager()

    var count: Int { assets?.count ?? 0 }
    func asset(at index: Int) -> PHAsset { assets!.object(at: index) }
    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }
    /// Chooses or unchooses one picture; the order chosen is the order sent.
    func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: index) } else { selectedIDs.append(id) }
    }
    var selectedAssets: [PHAsset] {
        guard let assets else { return [] }
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in if self.selectedIDs.contains(asset.localIdentifier) { byID[asset.localIdentifier] = asset } }
        return selectedIDs.compactMap { byID[$0] }
    }
    /// A video's length as Photos shows it: m:ss, or h:mm:ss from an hour.
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
    func load() async {
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        assets = PHAsset.fetchAssets(with: options)
    }
}

/// Writes a chosen picture or video, as the file Photos holds (edited version when there is one),
/// into Mosaic's outgoing folder.
enum PhotoLibraryExport {
    static func file(for asset: PHAsset, in directory: URL = OutgoingFiles.pendingDirectory) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = resource.originalFilename.isEmpty ? (asset.mediaType == .video ? "Video.mov" : "Photo.heic") : resource.originalFilename
        let url = directory.appending(path: "\(OutgoingFiles.stamp()) \(name)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil ? url : nil)
            }
        }
    }
}
