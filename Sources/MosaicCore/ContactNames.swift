import Foundation

/// Resolves only unambiguous addresses. Numbers are read with the Mac's region by the same rules
/// that route a send (`HandleForm`): a national number matches its international form, and a
/// number whose country is not certain matches only the same digits.
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

    public init(entries: [Entry] = [], region: String = HandleForm.systemRegion) {
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
        switch HandleForm(address, region: region) {
        case .email(let value): return ["email:" + value]
        case .phone(let digits): return ["phone:+" + digits]
        case .local(let digits): return ["local:" + digits]
        case .other: return []
        }
    }
}
