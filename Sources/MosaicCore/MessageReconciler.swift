import Foundation

/// Matches the messages Mosaic sent (pending bubbles) to the rows Messages later reports, so a
/// bubble keeps its identity when the real message arrives — and never claims someone else's.
public enum MessageReconciler {
    public struct Result {
        public let messages: [Message]
        public let pending: [Message]
    }
    /// How far apart the local time of a send and the database's time may be.
    public static let window: TimeInterval = 120

    /// `loaded` is the database's current page, `previous` what the thread showed before (its
    /// presentation identities are kept), `pending` the local messages still waiting for a row.
    /// A pending message claims a loaded row only when the row is new to the thread, outgoing,
    /// within the time window, and the evidence agrees: equal text for a text message; for a file
    /// message, the same number of files with the same kinds and — where both sides know them —
    /// names and sizes. When several rows fit several identical pendings, they pair up in order;
    /// a pending with no plausible row, or an ambiguous one, stays pending.
    public static func merge(loaded: [Message], previous: [Message], pending: [Message]) -> Result {
        var messages = loaded
        let previousByID = Dictionary(previous.map { ($0.id, $0.presentationID) }, uniquingKeysWith: { first, _ in first })
        for index in messages.indices {
            if let identity = previousByID[messages[index].id] { messages[index].presentationID = identity }
        }
        var taken = Set<Int>()
        var waiting: [Message] = []
        for candidate in pending {
            // Rows this pending could be, in the page's (time) order, not yet given to another.
            let options = messages.indices.filter { index in
                let row = messages[index]
                return !taken.contains(index) && row.isFromMe && row.sendState == nil && previousByID[row.id] == nil
                    && abs(row.date.timeIntervalSince(candidate.date)) < window && matches(row, candidate)
            }
            // One row, or rows that cannot be told apart (the same text or the same files sent
            // more than once): the first free one is this pending's, in submission order. Rows
            // that differ from each other would make the choice a guess, unless exactly one of
            // them carries the pending's full evidence.
            let chosen: Int?
            if options.count == 1 || (options.count > 1 && options.dropFirst().allSatisfy { sameEvidence(messages[$0], messages[options[0]]) }) {
                chosen = options.first
            } else {
                let exact = options.filter { sameEvidence(messages[$0], candidate) }
                chosen = exact.count == 1 ? exact[0] : nil
            }
            guard let index = chosen else { waiting.append(candidate); continue }
            messages[index].presentationID = candidate.presentationID
            taken.insert(index)
        }
        // Local messages stay on screen: the ones still waiting for their row, and the ones Messages
        // refused (until the reader retries or removes them).
        let failed = previous.filter { prior in prior.sendState?.isFailed == true && !waiting.contains { $0.presentationID == prior.presentationID } }
        messages.append(contentsOf: (waiting + failed).sorted { $0.date < $1.date })
        return Result(messages: messages, pending: waiting)
    }

    /// Whether a database row could be this pending message.
    static func matches(_ row: Message, _ pending: Message) -> Bool {
        if pending.attachments.isEmpty {
            return row.attachments.isEmpty && row.attachmentCount == 0 && row.text == pending.text
        }
        let rowCount = max(row.attachmentCount, row.attachments.count)
        guard rowCount == pending.attachments.count, row.text == pending.text else { return false }
        // Files not yet downloaded on this Mac have no local record to compare; count and text decide.
        guard !row.attachments.isEmpty else { return true }
        for (theirs, ours) in zip(row.attachments, pending.attachments) {
            if theirs.kind != ours.kind { return false }
            if !theirs.name.isEmpty, !ours.name.isEmpty, theirs.name.caseInsensitiveCompare(ours.name) != .orderedSame { return false }
            if let a = theirs.byteCount, let b = ours.byteCount, a != b { return false }
        }
        return true
    }
    /// Whether two messages carry the same evidence (so either could be the other's row).
    static func sameEvidence(_ a: Message, _ b: Message) -> Bool {
        a.text == b.text && a.attachments.count == b.attachments.count
            && zip(a.attachments, b.attachments).allSatisfy { $0.kind == $1.kind && $0.name == $1.name && $0.byteCount == $1.byteCount }
    }
}
