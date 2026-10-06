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
                Button("Cancel") { model.close(); onCancel() }.buttonStyle(PickerButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button(model.selectedIDs.count > 1 ? "Add \(model.selectedIDs.count)" : "Add") { let chosen = model.selectedAssets; model.close(); onAdd(chosen) }
                    .buttonStyle(PickerButtonStyle(prominent: true))
                    .disabled(model.selectedIDs.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task { await model.load() }
        .onDisappear { model.close() }
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
                                model.toggle(asset)
                            }
                            .onAppear { model.cellAppeared(index) }
                            .onDisappear { model.cellDisappeared(index) }
                        }
                    }
                    .padding(8)
                    // The slim scroller the rest of Mosaic has: it does not grow under the pointer.
                    // Its track runs from the top of the first row to the bottom of the last, inside
                    // the grid's margin, not from the card's edge.
                    .background(ThinScrollerInstaller(scrollerInsets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)))
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
    /// The asset the shown (or requested) picture belongs to: a cell given another asset after a
    /// library change drops the old picture, and a late callback for the old one is ignored.
    @State private var shownID: String?
    @State private var request: PHImageRequestID?

    var body: some View {
        ZStack {
            Rectangle().fill(Palette.incoming)
            if let image, shownID == asset.localIdentifier { Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill) }
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
        .onDisappear(perform: cancel)
        .onChange(of: asset.localIdentifier) { cancel(); image = nil; load() }
    }
    private func cancel() {
        if let request { manager.cancelImageRequest(request) }
        request = nil
    }
    /// Asks with the same size and options the model preheats with, so a preheated picture is
    /// served from the cache. A degraded picture shows first; the request ends with the final
    /// one, a cancellation or an error.
    private func load() {
        let id = asset.localIdentifier
        guard request == nil, image == nil || shownID != id else { return }
        shownID = id
        request = manager.requestImage(for: asset, targetSize: PhotoLibraryModel.thumbnailSize, contentMode: .aspectFill,
                                       options: PhotoLibraryModel.thumbnailOptions) { result, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
            let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
            let failed = info?[PHImageErrorKey] != nil
            Task { @MainActor in
                guard shownID == id else { return }
                if let result, !cancelled { image = result }
                if !degraded || cancelled || failed { request = nil }
            }
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
///
/// The selection is kept by identifier, with the chosen assets themselves, so adding three photos
/// from a large library never walks the library, and a picture added to Photos while the picker is
/// open does not shift what was chosen. Thumbnails near the visible cells are preheated with the
/// cells' own request parameters; preheating stops when the picker closes.
@Observable @MainActor final class PhotoLibraryModel {
    private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets: PHFetchResult<PHAsset>?
    private(set) var selectedIDs: [String] = []
    @ObservationIgnored private var chosen: [String: PHAsset] = [:]
    let manager = PHCachingImageManager()
    @ObservationIgnored private var visible = Set<Int>()
    @ObservationIgnored private var preheated: Range<Int> = 0..<0
    @ObservationIgnored private var observer: LibraryObserver?

    static let thumbnailSize = CGSize(width: PhotoLibraryPickerView.cellSize * 2, height: PhotoLibraryPickerView.cellSize * 2)
    static let thumbnailOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()
    /// Assets preheated on each side of the visible ones (a few rows of the grid).
    static let preheatMargin = PhotoLibraryPickerView.columns * 6

    var count: Int { assets?.count ?? 0 }
    func asset(at index: Int) -> PHAsset { assets!.object(at: index) }
    func isSelected(_ id: String) -> Bool { selectedSet.contains(id) }
    /// Observed: each cell reads it for its check and outline, so a click redraws the cells at
    /// once. (Ignored by observation, only the footer's count followed a click.)
    private var selectedSet = Set<String>()
    func toggle(_ asset: PHAsset) { toggle(asset.localIdentifier, asset: asset) }
    /// Chooses or unchooses one picture; the order chosen is the order sent.
    func toggle(_ id: String, asset: PHAsset? = nil) {
        if selectedSet.remove(id) != nil {
            selectedIDs.removeAll { $0 == id }
            chosen[id] = nil
        } else {
            selectedSet.insert(id)
            selectedIDs.append(id)
            chosen[id] = asset
        }
    }
    var selectedAssets: [PHAsset] { selectedIDs.compactMap { chosen[$0] } }

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
        if observer == nil {
            let observer = LibraryObserver { [weak self] change in self?.apply(change) }
            PHPhotoLibrary.shared().register(observer)
            self.observer = observer
        }
    }
    /// The library changed under the open picker: show the new contents, keep the selection
    /// (by identity), and forget chosen pictures that were deleted.
    private func apply(_ change: PHChange) {
        guard let assets, let details = change.changeDetails(for: assets) else { return }
        self.assets = details.fetchResultAfterChanges
        let removed = Set(details.removedObjects.map(\.localIdentifier))
        if !removed.isEmpty {
            selectedIDs.removeAll { removed.contains($0) }
            selectedSet.subtract(removed)
            for id in removed { chosen[id] = nil }
        }
        for asset in details.changedObjects where chosen[asset.localIdentifier] != nil { chosen[asset.localIdentifier] = asset }
        // Indices moved: preheat again from what is visible now.
        manager.stopCachingImagesForAllAssets()
        preheated = 0..<0
        updatePreheat()
    }

    func cellAppeared(_ index: Int) { visible.insert(index); updatePreheat() }
    func cellDisappeared(_ index: Int) { visible.remove(index) }
    /// Keeps a bounded window of thumbnails cached around the visible cells, starting and stopping
    /// only the difference when the window moves by at least a row.
    private func updatePreheat() {
        guard let assets, let low = visible.min(), let high = visible.max() else { return }
        let wanted = Self.preheatWindow(visible: low...high, count: assets.count, margin: Self.preheatMargin)
        guard abs(wanted.lowerBound - preheated.lowerBound) >= PhotoLibraryPickerView.columns
                || abs(wanted.upperBound - preheated.upperBound) >= PhotoLibraryPickerView.columns
                || preheated.isEmpty else { return }
        let (added, removed) = Self.difference(from: preheated, to: wanted)
        let start = added.flatMap { assets.objects(at: IndexSet(integersIn: $0)) }
        let stop = removed.flatMap { assets.objects(at: IndexSet(integersIn: $0)) }
        if !start.isEmpty {
            manager.startCachingImages(for: start, targetSize: Self.thumbnailSize, contentMode: .aspectFill, options: Self.thumbnailOptions)
        }
        if !stop.isEmpty {
            manager.stopCachingImages(for: stop, targetSize: Self.thumbnailSize, contentMode: .aspectFill, options: Self.thumbnailOptions)
        }
        preheated = wanted
    }
    /// The picker went away: stop preheating, drop the cache and stop observing the library.
    func close() {
        manager.stopCachingImagesForAllAssets()
        preheated = 0..<0
        visible.removeAll()
        if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        observer = nil
    }

    /// The visible span widened by `margin` on each side, within the library.
    nonisolated static func preheatWindow(visible: ClosedRange<Int>, count: Int, margin: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lower = max(0, visible.lowerBound - margin)
        let upper = min(count, visible.upperBound + 1 + margin)
        return lower < upper ? lower..<upper : 0..<0
    }
    /// What starts and what stops when the preheated window moves from `old` to `new`.
    nonisolated static func difference(from old: Range<Int>, to new: Range<Int>) -> (added: [Range<Int>], removed: [Range<Int>]) {
        func subtract(_ a: Range<Int>, _ b: Range<Int>) -> [Range<Int>] {
            guard !a.isEmpty else { return [] }
            guard a.overlaps(b) else { return [a] }
            var parts: [Range<Int>] = []
            if a.lowerBound < b.lowerBound { parts.append(a.lowerBound..<b.lowerBound) }
            if b.upperBound < a.upperBound { parts.append(b.upperBound..<a.upperBound) }
            return parts
        }
        return (subtract(new, old), subtract(old, new))
    }
}

/// Hands Photos library changes to the main actor.
private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @MainActor (PHChange) -> Void
    init(onChange: @escaping @MainActor (PHChange) -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.onChange(changeInstance) }
    }
}

/// Writes a chosen picture or video, as the file Photos holds (edited version when there is one),
/// into Mosaic's outgoing folder.
enum PhotoLibraryExport {
    /// How many items are written out at once. Photos may download each one from iCloud and
    /// writes it progressively, so a large selection all at once would contend for the disk and
    /// the network (and every item would arrive late).
    static let concurrentExports = 3

    /// Writes out chosen items, at most `limit` at a time, starting in the order chosen; each
    /// lands at its reserved place (`slots`, in the same order) as it finishes, nil when it could
    /// not be written.
    @MainActor static func export<Item>(_ items: [Item], slots: [String], limit: Int = concurrentExports,
                                        write: @escaping @Sendable (Item) async -> URL?,
                                        landed: (String, URL?) -> Void) async {
        var waiting = Array(zip(slots, items)).makeIterator()
        await withTaskGroup(of: (String, URL?).self) { group in
            var started = 0
            while started < max(1, limit), let next = waiting.next() {
                let slot = next.0, item = next.1
                group.addTask { (slot, await write(item)) }
                started += 1
            }
            while let finished = await group.next() {
                landed(finished.0, finished.1)
                if let next = waiting.next() {
                    let slot = next.0, item = next.1
                    group.addTask { (slot, await write(item)) }
                }
            }
        }
    }

    static func file(for asset: PHAsset, in directory: URL = OutgoingFiles.pendingDirectory) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = resource.originalFilename.isEmpty ? (asset.mediaType == .video ? "Video.mov" : "Photo.heic") : resource.originalFilename
        // Photos writes the file as the data comes, so it goes to a name of its own first and
        // takes its real name only once complete: a failed write removes only its own partial
        // file, never another photo's (two edited photos are both "FullSizeRender.heic").
        let partial = directory.appending(path: ".\(UUID().uuidString).partial")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: partial, options: options) { error in
                guard error == nil, let kept = OutgoingFiles.moveIntoPlace(partial, named: "\(OutgoingFiles.stamp()) \(name)", in: directory) else {
                    try? FileManager.default.removeItem(at: partial)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: kept)
            }
        }
    }
}
