import Foundation

/// Finds web links in message text. Results are cached because every tile re-renders its history often.
public enum LinkDetector {
    public struct Match: Equatable, Sendable {
        public let range: NSRange
        public let url: URL
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 4000
        return cache
    }()
    private final class Box { let matches: [Match]; init(_ matches: [Match]) { self.matches = matches } }

    /// Web (http/https) links in the order they appear.
    public static func links(in text: String) -> [Match] {
        guard !text.isEmpty, text.count < 20_000 else { return [] }
        if let cached = cache.object(forKey: text as NSString) { return cached.matches }
        let range = NSRange(text.startIndex..., in: text)
        let matches = (detector?.matches(in: text, options: [], range: range) ?? []).compactMap { result -> Match? in
            guard var url = result.url else { return nil }
            if url.scheme == nil, let fixed = URL(string: "https://" + url.absoluteString) { url = fixed }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
            return Match(range: result.range, url: url)
        }
        cache.setObject(Box(matches), forKey: text as NSString)
        return matches
    }

    /// The link a preview card should show for this message, if any.
    public static func previewURL(in text: String) -> URL? { links(in: text).first?.url }

    /// True when the message consists of exactly one link (Messages shows only the preview card then).
    public static func isOnlyLink(_ text: String) -> Bool {
        let matches = links(in: text)
        guard matches.count == 1, let range = Range(matches[0].range, in: text) else { return false }
        var remainder = text
        remainder.removeSubrange(range)
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
