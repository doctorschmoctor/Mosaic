import Foundation

public enum MessageReconciler {
    public struct Result {
        public let messages: [Message]
        public let pending: [Message]
    }
    public static func merge(loaded: [Message], previous: [Message], pending: [Message]) -> Result {
        var messages = loaded
        let previousByID = Dictionary(previous.map { ($0.id, $0.presentationID) }, uniquingKeysWith: { first, _ in first })
        for index in messages.indices {
            if let identity = previousByID[messages[index].id] { messages[index].presentationID = identity }
        }
        var claimed = Set<String>()
        var waiting: [Message] = []
        for candidate in pending {
            if let index = messages.firstIndex(where: { message in
                message.isFromMe && message.text == candidate.text && !claimed.contains(message.id) &&
                previousByID[message.id] == nil && abs(message.date.timeIntervalSince(candidate.date)) < 120
            }) {
                messages[index].presentationID = candidate.presentationID
                claimed.insert(messages[index].id)
            } else { waiting.append(candidate) }
        }
        messages.append(contentsOf: waiting)
        return Result(messages: messages, pending: waiting)
    }
}
