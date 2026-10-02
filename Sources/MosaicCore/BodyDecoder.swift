import Foundation

/// A bounded decoder for the NSString run used by Messages' legacy typedstream bodies.
/// Unknown archives get a visible fallback rather than unsafe object unarchiving.
public enum BodyDecoder {
    public static func decode(text: String?, attributedBody: Data?) -> String {
        if let text, !text.isEmpty { return text }
        guard let data = attributedBody, !data.isEmpty else { return "" }
        if data.starts(with: Data("bplist".utf8)),
           let value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            return value.string
        }
        let bytes = [UInt8](data)
        let marker = [UInt8]("NSString".utf8)
        guard bytes.count >= marker.count else { return "Rich text message · Open in Messages" }
        for index in 0...(bytes.count - marker.count) where Array(bytes[index..<(index + marker.count)]) == marker {
            let end = min(bytes.count - 1, index + 80)
            guard end > index + marker.count else { continue }
            for cursor in (index + marker.count)..<end where bytes[cursor] == 0x01 && bytes[cursor + 1] == 0x2b {
                var start = cursor + 2
                guard start < bytes.count else { continue }
                var length = Int(bytes[start]); start += 1
                if length == 0x81 {
                    guard start + 2 <= bytes.count else { continue }
                    length = Int(bytes[start]) | (Int(bytes[start + 1]) << 8); start += 2
                } else if length == 0x82 {
                    guard start + 4 <= bytes.count else { continue }
                    length = (0..<4).reduce(0) { $0 | (Int(bytes[start + $1]) << ($1 * 8)) }; start += 4
                } else if length >= 0x80 { continue }
                guard length > 0, length <= 1_000_000, start + length <= bytes.count,
                      let value = String(bytes: bytes[start..<(start + length)], encoding: .utf8) else { continue }
                return value.replacingOccurrences(of: "\u{fffc}", with: "")
            }
        }
        return "Rich text message · Open in Messages"
    }
}
