import Foundation

/// How Mosaic reads a handle — a phone number or an email address — both for comparing it with
/// other handles (`Recipient.key`, `ContactNames`) and for handing it to Messages
/// (`Recipient.handle`). One set of rules for both, so what is matched is what is sent.
///
/// A phone number is taken as international (E.164) only when that is certain: written with "+"
/// or an international prefix ("00", "011" in the US and Canada), or written the way the Mac's
/// region writes its own numbers (a national trunk 0, a ten-digit US or Canadian number, the
/// region's own calling code without the "+"). Anything else is left as written: it is compared
/// only with the same digits written the same way, and handed to Messages as typed, for Messages
/// to read with the same region. A number is never moved into another country, and numbers are
/// never matched by their last digits.
public enum HandleForm: Equatable, Hashable, Sendable {
    /// An email address, lowercased.
    case email(String)
    /// A phone number in international form: its digits with the country code, no "+".
    case phone(String)
    /// Digits whose country is not certain (a short code, a number written for another region).
    case local(String)
    /// Anything else (a business or service identifier), lowercased.
    case other(String)

    /// The Mac's region, which national numbers are read in.
    public static let systemRegion = (Locale.current.region?.identifier ?? "US").uppercased()

    public init(_ address: String, region: String = HandleForm.systemRegion) {
        let region = region.uppercased()
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["mailto:", "tel:", "imessage:", "sms:"] where value.lowercased().hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if value.contains("@") { self = .email(value.lowercased()); return }
        guard !value.contains(where: \.isLetter) else { self = .other(value.lowercased()); return }
        // Any script's digits (full-width ones included) as ASCII.
        let digits = String(value.compactMap { character -> Character? in
            guard let number = character.wholeNumberValue, (0...9).contains(number) else { return nil }
            return Character(String(number))
        })
        guard !digits.isEmpty else { self = .other(value.lowercased()); return }
        self = Self.phone(digits: digits, plus: value.hasPrefix("+"), region: region)
    }

    /// What two handles are compared by: equal keys are the same person on any service.
    public var key: String {
        switch self {
        case .email(let value), .other(let value): return value
        case .phone(let digits): return "+" + digits
        case .local(let digits): return digits
        }
    }
    /// The handle in the form Messages is given for a new conversation: international when that
    /// is certain, otherwise the digits as written (Messages reads them with the Mac's region).
    public var messagesHandle: String {
        switch self {
        case .email(let value), .other(let value): return value
        case .phone(let digits): return "+" + digits
        case .local(let digits): return digits
        }
    }
    public var isPhone: Bool {
        switch self { case .phone, .local: return true; default: return false }
    }

    // MARK: Numbering plans

    /// Regions sharing the North American Numbering Plan (+1).
    static let northAmerican: Set<String> = ["US", "CA", "PR", "VI", "GU", "AS", "MP", "AG", "AI", "BB", "BM", "BS", "DM",
                                             "DO", "GD", "JM", "KN", "KY", "LC", "MS", "SX", "TC", "TT", "VC", "VG"]
    struct Plan {
        let callingCode: String
        /// National numbers start with a 0 that the international form drops.
        var trunkZero = false
        /// A national number's length, for a region without a trunk prefix (where the length is
        /// what tells a national number from one written with its country code).
        var nationalLength: Int? = nil
        /// International prefixes besides "00".
        var exits: [String] = []
    }
    /// The regions whose national form Mosaic reads. Elsewhere a number without "+" or an
    /// international prefix is left as written.
    static let plans: [String: Plan] = [
        "GB": Plan(callingCode: "44", trunkZero: true), "IE": Plan(callingCode: "353", trunkZero: true),
        "AU": Plan(callingCode: "61", trunkZero: true, exits: ["0011"]), "NZ": Plan(callingCode: "64", trunkZero: true),
        "FR": Plan(callingCode: "33", trunkZero: true), "DE": Plan(callingCode: "49", trunkZero: true),
        "NL": Plan(callingCode: "31", trunkZero: true), "BE": Plan(callingCode: "32", trunkZero: true),
        "CH": Plan(callingCode: "41", trunkZero: true), "AT": Plan(callingCode: "43", trunkZero: true),
        "SE": Plan(callingCode: "46", trunkZero: true), "FI": Plan(callingCode: "358", trunkZero: true),
        "IN": Plan(callingCode: "91", trunkZero: true), "JP": Plan(callingCode: "81", trunkZero: true, exits: ["010"]),
        "ZA": Plan(callingCode: "27", trunkZero: true), "IL": Plan(callingCode: "972", trunkZero: true),
        "TR": Plan(callingCode: "90", trunkZero: true),
        "NO": Plan(callingCode: "47", nationalLength: 8), "DK": Plan(callingCode: "45", nationalLength: 8),
        "ES": Plan(callingCode: "34", nationalLength: 9), "PT": Plan(callingCode: "351", nationalLength: 9),
        "PL": Plan(callingCode: "48", nationalLength: 9),
    ]
    /// The shortest and longest an international number's digits can be (E.164 allows 15).
    static let internationalLengths = 7...15

    private static func phone(digits: String, plus: Bool, region: String) -> HandleForm {
        if plus { return internationalLengths.contains(digits.count) ? .phone(digits) : .local(digits) }
        let plan = plans[region]
        // An international prefix: the region's own first (AU's 0011 before 00), then 00 — which
        // no national number in these plans starts with — and 011 in North America.
        let exits = (plan?.exits ?? []) + (northAmerican.contains(region) ? ["011"] : []) + ["00"]
        if let exit = exits.first(where: { digits.hasPrefix($0) }) {
            let rest = String(digits.dropFirst(exit.count))
            return internationalLengths.contains(rest.count) && !rest.hasPrefix("0") ? .phone(rest) : .local(digits)
        }
        if northAmerican.contains(region) {
            // NXX-NXX-XXXX: area code and exchange start with 2–9; with or without the leading 1.
            func isNorthAmerican(_ number: Substring) -> Bool {
                number.count == 10 && "23456789".contains(number.first!) && "23456789".contains(number[number.index(number.startIndex, offsetBy: 3)])
            }
            if isNorthAmerican(Substring(digits)) { return .phone("1" + digits) }
            if digits.count == 11, digits.hasPrefix("1"), isNorthAmerican(digits.dropFirst()) { return .phone(digits) }
            return .local(digits)
        }
        guard let plan else { return .local(digits) }
        let code = plan.callingCode
        if plan.trunkZero {
            // 020 7946 0123 → +44 20 7946 0123.
            if digits.hasPrefix("0") {
                let national = digits.dropFirst()
                return national.count >= 6 && !national.hasPrefix("0") && internationalLengths.contains(code.count + national.count)
                    ? .phone(code + national) : .local(digits)
            }
            // The region's own calling code, written without "+": 44 20 7946 0123.
            if digits.hasPrefix(code), !digits.dropFirst(code.count).hasPrefix("0"), digits.count >= code.count + 7,
               internationalLengths.contains(digits.count) {
                return .phone(digits)
            }
            return .local(digits)
        }
        if let length = plan.nationalLength {
            if digits.count == length { return .phone(code + digits) }
            if digits.count == code.count + length, digits.hasPrefix(code) { return .phone(digits) }
        }
        return .local(digits)
    }
}
