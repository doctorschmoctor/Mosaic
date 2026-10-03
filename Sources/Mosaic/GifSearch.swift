import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// GIF search through Tenor's API, with the user's own key (free from Google; set in Settings).
/// Only the search and the chosen GIF's download leave the Mac, and only when the search is used.
struct TenorClient {
    struct Gif: Identifiable, Equatable {
        let id: String
        let description: String
        /// A small animated preview for the grid.
        let previewURL: URL
        let previewSize: CGSize
        /// The GIF that is sent.
        let fullURL: URL
    }
    static let endpoint = URL(string: "https://tenor.googleapis.com/v2")!
    static let keyHelpURL = URL(string: "https://developers.google.com/tenor/guides/quickstart")!
    let apiKey: String
    var session = URLSession.shared

    /// The current featured GIFs (shown before a search).
    func featured(limit: Int = 30) async throws -> [Gif] {
        try await fetch("featured", query: [URLQueryItem(name: "limit", value: String(limit))])
    }
    func search(_ text: String, limit: Int = 30) async throws -> [Gif] {
        try await fetch("search", query: [URLQueryItem(name: "q", value: text), URLQueryItem(name: "limit", value: String(limit))])
    }
    private func fetch(_ path: String, query: [URLQueryItem]) async throws -> [Gif] {
        var components = URLComponents(url: Self.endpoint.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query + [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "client_key", value: "mosaic"),
                                         URLQueryItem(name: "media_filter", value: "tinygif,gif"), URLQueryItem(name: "contentfilter", value: "medium")]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TenorError(http.statusCode == 400 || http.statusCode == 403 ? "Tenor rejected this API key." : "Tenor returned an error (\(http.statusCode)).")
        }
        return try Self.parse(data)
    }
    /// Decodes a Tenor v2 response: `results[].media_formats.{tinygif,gif}.url`.
    static func parse(_ data: Data) throws -> [Gif] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.results.compactMap { result in
            guard let preview = result.media_formats["tinygif"] ?? result.media_formats["gif"],
                  let full = result.media_formats["gif"] ?? result.media_formats["tinygif"] else { return nil }
            let dims = preview.dims ?? []
            let size = dims.count == 2 && dims[0] > 0 && dims[1] > 0 ? CGSize(width: dims[0], height: dims[1]) : CGSize(width: 1, height: 1)
            return Gif(id: result.id, description: result.content_description ?? "GIF", previewURL: preview.url, previewSize: size, fullURL: full.url)
        }
    }
    /// Downloads a GIF into Mosaic's outgoing folder, ready to attach.
    func download(_ gif: Gif) async throws -> URL {
        let (data, _) = try await session.data(from: gif.fullURL)
        return try OutgoingFiles.store(data, type: .gif)
    }

    private struct Response: Decodable { let results: [Result] }
    private struct Result: Decodable {
        let id: String
        let content_description: String?
        let media_formats: [String: Media]
    }
    private struct Media: Decodable {
        let url: URL
        let dims: [Int]?
    }
    struct TenorError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// The GIF popover: a search field and a grid of animated previews; clicking one attaches it.
struct GifSearchView: View {
    let apiKey: String
    let onPick: (URL) -> Void
    let onOpenSettings: () -> Void
    @State private var query = ""
    @State private var gifs: [TenorClient.Gif] = []
    @State private var status: String?
    @State private var downloading: String?
    @FocusState private var searchFocused: Bool

    private var client: TenorClient { TenorClient(apiKey: apiKey) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find GIFs", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            .padding(12)
            if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                needsKey
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(gifs) { gif in
                            AnimatedImageView(url: gif.previewURL)
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay { if downloading == gif.id { ProgressView().controlSize(.small) } }
                                .contentShape(Rectangle())
                                .onTapGesture { pick(gif) }
                                .hoverCursor(.pointingHand)
                                .help(gif.description)
                                .accessibilityLabel(gif.description)
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                    if let status {
                        Text(status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20)
                    }
                }
                .scrollIndicators(.never)
                HStack {
                    Spacer()
                    Text("Powered by Tenor").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .frame(width: 380, height: 460)
        .task(id: query) {
            guard !apiKey.isEmpty else { return }
            let text = query.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            do {
                let found = try await (text.isEmpty ? client.featured() : client.search(text))
                guard !Task.isCancelled else { return }
                gifs = found
                status = found.isEmpty ? "No GIFs found." : nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                gifs = []
                status = error.localizedDescription
            }
        }
        .onAppear { searchFocused = true }
    }

    private var needsKey: some View {
        VStack(spacing: 12) {
            Image(systemName: "key").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text("GIF search needs a Tenor API key").font(.headline)
            Text("Tenor keys are free from Google. Paste yours in Mosaic › Settings; searches then go to Tenor only while this panel is open.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Link("Get a key", destination: TenorClient.keyHelpURL)
                Button("Open Settings") { onOpenSettings() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pick(_ gif: TenorClient.Gif) {
        guard downloading == nil else { return }
        downloading = gif.id
        Task {
            defer { downloading = nil }
            do { onPick(try await client.download(gif)) }
            catch { status = error.localizedDescription }
        }
    }
}

/// An NSImageView that animates GIF data; SwiftUI's Image shows only a GIF's first frame.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoadingImageView { let view = LoadingImageView(); view.load(url); return view }
    func updateNSView(_ view: LoadingImageView, context: Context) { view.load(url) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LoadingImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: proposal.height ?? 100)
    }

    final class LoadingImageView: NSImageView {
        private var current: URL?
        private var task: Task<Void, Never>?
        override init(frame: NSRect) {
            super.init(frame: frame)
            animates = true
            imageScaling = .scaleProportionallyUpOrDown
            imageAlignment = .alignCenter
            wantsLayer = true
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        func load(_ url: URL) {
            guard current != url else { return }
            current = url
            image = nil
            task?.cancel()
            task = Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
                let image = NSImage(data: data)
                await MainActor.run { if self?.current == url { self?.image = image } }
            }
        }
        deinit { task?.cancel() }
    }
}
