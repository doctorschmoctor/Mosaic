import Foundation

/// Where a message goes: an existing conversation (by its exact chat identifier — a failed lookup
/// must never fall through to another recipient) or a person who has no chat yet.
enum SendTarget: Equatable {
    case chat(String)
    case participant(handle: String, service: String)
}

/// What a way of sending can do. Reading and showing something (a reply, a reaction, an edit) is
/// separate from being able to send it: Messages' scripting dictionary sends text and files to a
/// chat or participant and nothing else, so an action it cannot express is never offered as a send.
struct TransportCapabilities: Equatable {
    var text = false
    var files = false
    var nativeReply = false
    var nativeReaction = false
    var edit = false
    var unsend = false
    var readState = false

    /// Messages.app's AppleScript dictionary (`Messages.sdef`): `send` of text or a file.
    static let messagesAppleScript = TransportCapabilities(text: true, files: true)
    static let none = TransportCapabilities()
}

/// A way of handing a message to Messages. Submission is not delivery: a transport that returns
/// without error has handed the message over, and the database says the rest.
@MainActor protocol MessageTransport: AnyObject {
    var capabilities: TransportCapabilities { get }
    func send(text: String, to target: SendTarget) async throws
    /// The file must be readable by Messages; the transport takes care of that (staging).
    func send(file: URL, to target: SendTarget) async throws
}

struct TransportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The live transport: Messages' AppleScript dictionary through `MessagesBridge`, which runs each
/// send in a helper process, so the window stays responsive however long Messages takes to accept
/// it. Sends still go one at a time, in order (the store chains them). Files are staged in
/// Messages' own folder first (see `OutgoingFiles.stage`), the one place its sandbox reads
/// attachments from.
@MainActor final class AppleScriptTransport: MessageTransport {
    let capabilities = TransportCapabilities.messagesAppleScript
    func send(text: String, to target: SendTarget) async throws {
        switch target {
        case .chat(let id): try await MessagesBridge.send(text: text, conversationID: id)
        case .participant(let handle, let service): try await MessagesBridge.send(text: text, toNewRecipient: handle, service: service)
        }
    }
    func send(file: URL, to target: SendTarget) async throws {
        // The copy is made off the main thread, and the hand-off to Messages runs in the helper.
        let staged = try await OutgoingFiles.stageInBackground(file)
        do {
            switch target {
            case .chat(let id): try await MessagesBridge.send(filePath: staged.path, conversationID: id)
            case .participant(let handle, let service): try await MessagesBridge.send(filePath: staged.path, toNewRecipient: handle, service: service)
            }
        } catch {
            // Refused: Messages took nothing, so the staged copy goes now (never the original).
            OutgoingFiles.removeStaged(staged)
            throw error
        }
        OutgoingFiles.scheduleRemoval(of: staged)
    }
}

/// The demo workspace's transport: sends go nowhere and succeed at once.
@MainActor final class DemoTransport: MessageTransport {
    let capabilities = TransportCapabilities.messagesAppleScript
    func send(text: String, to target: SendTarget) async throws {}
    func send(file: URL, to target: SendTarget) async throws {}
}

/// A transport for tests: records every submission in order and fails or delays on request.
@MainActor final class RecordingTransport: MessageTransport {
    enum Submission: Equatable {
        case text(String, SendTarget)
        case file(URL, SendTarget)
    }
    var capabilities = TransportCapabilities.messagesAppleScript
    private(set) var submissions: [Submission] = []
    /// Submissions (by position, counting from zero) that fail with this message.
    var failures: [Int: String] = [:]
    /// How long each submission takes.
    var latency: Duration = .zero
    /// Suspends every submission until `release()` is called (to look at the state in between).
    var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// A release that came before any submission was held lets the next one through, so a test
    /// cannot hang on a submission that arrived late.
    private var releasedAhead = 0

    func release() {
        let waiting = held
        held = []
        if waiting.isEmpty { releasedAhead += 1 }
        for continuation in waiting { continuation.resume() }
    }
    func send(text: String, to target: SendTarget) async throws {
        try await submit(.text(text, target))
    }
    func send(file: URL, to target: SendTarget) async throws {
        try await submit(.file(file, target))
    }
    private func submit(_ submission: Submission) async throws {
        let index = submissions.count
        submissions.append(submission)
        if holds {
            if releasedAhead > 0 { releasedAhead -= 1 } else { await withCheckedContinuation { held.append($0) } }
        }
        if latency > .zero { try? await Task.sleep(for: latency) }
        if let failure = failures[index] { throw TransportError(failure) }
    }
}
