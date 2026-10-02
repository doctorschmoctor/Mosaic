import Foundation

/// Resolves only unambiguous addresses. National-number aliases use the Mac's region.
public struct ContactNames: Sendable {
    public struct Entry: Sendable {
        public let id: String
        public let name: String
        public let addresses: [String]
        public init(id: String, name: String, addresses: [String]) {
            self.id = id; self.name = name; self.addresses = addresses
        }
    }
    private struct Match: Sendable { let id: String; let name: String }
    private var matches: [String: Match] = [:]
    private var ambiguous = Set<String>()
    private let region: String
    public let contactCount: Int

    public init(entries: [Entry] = [], region: String = Locale.current.region?.identifier ?? "US") {
        self.region = region.uppercased()
        contactCount = entries.count
        for entry in entries where !entry.name.isEmpty {
            for address in entry.addresses {
                for key in keys(for: address) {
                    if let existing = matches[key], existing.id != entry.id {
                        ambiguous.insert(key)
                    } else { matches[key] = Match(id: entry.id, name: entry.name) }
                }
            }
        }
    }
    public func name(for address: String) -> String? {
        for key in keys(for: address) where !ambiguous.contains(key) {
            if let match = matches[key] { return match.name }
        }
        return nil
    }
    public func title(for conversation: Conversation) -> String {
        if conversation.participants.isEmpty { return name(for: conversation.name) ?? conversation.name }
        if conversation.participants.count == 1, let address = conversation.participants.first {
            return name(for: address) ?? conversation.name
        }
        // Preserve explicitly named group conversations.
        guard conversation.name == conversation.participants.joined(separator: ", ") else { return conversation.name }
        return conversation.participants.map { name(for: $0) ?? $0 }.joined(separator: ", ")
    }
    private func keys(for address: String) -> [String] {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["mailto:", "tel:", "imessage:"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.contains("@") { return ["email:" + value] }
        guard !value.contains(where: \.isLetter) else { return [] }
        var digits = String(value.compactMap { character -> Character? in
            guard let number = character.wholeNumberValue, (0...9).contains(number) else { return nil }
            return Character(String(number))
        })
        guard !digits.isEmpty else { return [] }
        let international = value.hasPrefix("+") || value.hasPrefix("00")
        if value.hasPrefix("00") { digits.removeFirst(2) }
        var result = ["phone:" + digits]
        if ["US", "CA"].contains(region) {
            if digits.count == 10, !international { result.append("phone:1" + digits) }
            else if digits.count == 11, digits.hasPrefix("1") { result.append("phone:" + digits.dropFirst()) }
        } else {
            // National trunk prefixes differ by country; never match arbitrary suffixes.
            let dialingCodes = ["GB": "44", "AU": "61", "NZ": "64", "FR": "33", "DE": "49", "IE": "353"]
            if let code = dialingCodes[region] {
                if !international, digits.hasPrefix("0") { result.append("phone:" + code + digits.dropFirst()) }
                else if international, digits.hasPrefix(code) { result.append("phone:0" + digits.dropFirst(code.count)) }
            }
        }
        return result
    }
}
