import AppKit
import Carbon
import os

/// Hands messages to Messages through its AppleScript dictionary.
///
/// A send runs in a process of its own: the script is compiled once per launch into a file
/// (`osacompile`), and each send runs that file with `osascript`, which waits for Messages on its
/// own main thread while Mosaic's stays free — a slow Messages no longer freezes the window.
/// NSAppleScript is main-thread only (Apple's thread-safety summary), so moving it to a background
/// thread is not an option; a separate process is. The process is Mosaic's child, so macOS asks
/// for (and remembers) the Automation permission for Mosaic, as before.
///
/// Only when the helper process cannot be started at all — nothing was sent — does a send fall
/// back to running the same script in Mosaic itself, on the main thread, as earlier versions did.
@MainActor enum MessagesBridge {
    private static let source = """
    on run argv
        set requestName to item 1 of argv
        if requestName is "sendMessage" then return sendMessage(item 2 of argv, item 3 of argv)
        if requestName is "sendToParticipant" then return sendToParticipant(item 2 of argv, item 3 of argv, item 4 of argv)
        if requestName is "sendFile" then return sendFile(item 2 of argv, item 3 of argv)
        if requestName is "sendFileToParticipant" then return sendFileToParticipant(item 2 of argv, item 3 of argv, item 4 of argv)
        error "Mosaic asked Messages for something it does not do." number -50
    end run
    on sendMessage(messageText, conversationID)
        tell application id "com.apple.MobileSMS"
            set targetChat to chat id conversationID
            send messageText to targetChat
        end tell
        return "submitted"
    end sendMessage
    on sendToParticipant(messageText, handle, serviceKind)
        tell application id "com.apple.MobileSMS"
            if serviceKind is "SMS" then
                set targetService to 1st account whose service type = SMS
            else
                set targetService to 1st account whose service type = iMessage
            end if
            set targetParticipant to participant handle of targetService
            send messageText to targetParticipant
        end tell
        return "submitted"
    end sendToParticipant
    on sendFile(filePath, conversationID)
        set theFile to (POSIX file filePath) as alias
        tell application id "com.apple.MobileSMS"
            set targetChat to chat id conversationID
            send theFile to targetChat
        end tell
        return "submitted"
    end sendFile
    on sendFileToParticipant(filePath, handle, serviceKind)
        set theFile to (POSIX file filePath) as alias
        tell application id "com.apple.MobileSMS"
            if serviceKind is "SMS" then
                set targetService to 1st account whose service type = SMS
            else
                set targetService to 1st account whose service type = iMessage
            end if
            set targetParticipant to participant handle of targetService
            send theFile to targetParticipant
        end tell
        return "submitted"
    end sendFileToParticipant
    """

    /// Arguments are passed as data (process arguments, or Apple event descriptors in the
    /// fallback), never interpolated into executable script. Use the exact chat GUID; a failed
    /// lookup must never fall back to another recipient.
    private static let log = Logger(subsystem: "com.doctorschmoctor.Mosaic", category: "bridge")
    /// Compile and execution times of the last send, measured apart so a slow Messages reply is
    /// not mistaken for compile cost. Logged under the "bridge" category (Console, Info messages).
    private(set) static var lastCompileDuration: Duration?
    private(set) static var lastExecutionDuration: Duration?

    // MARK: Sending

    static func send(text: String, conversationID: String) async throws {
        try await call("sendMessage", [text, conversationID])
    }
    /// Starts (or continues) a one-to-one conversation with a handle that has no chat yet. Messages
    /// creates the chat; it shows up in the database afterwards. Group chats cannot be created this
    /// way: Messages offers no automation for it.
    static func send(text: String, toNewRecipient handle: String, service: String = "iMessage") async throws {
        try await call("sendToParticipant", [text, handle, serviceKind(service)])
    }
    /// Sends a file (a picture, a document) to an existing conversation. The file must be where
    /// Messages' sandbox can read it — see `OutgoingFiles.stage`; a file elsewhere is accepted and
    /// then fails to send.
    static func send(filePath: String, conversationID: String) async throws {
        try await call("sendFile", [filePath, conversationID])
    }
    static func send(filePath: String, toNewRecipient handle: String, service: String = "iMessage") async throws {
        try await call("sendFileToParticipant", [filePath, handle, serviceKind(service)])
    }
    private static func serviceKind(_ service: String) -> String {
        service.caseInsensitiveCompare("SMS") == .orderedSame ? "SMS" : "iMessage"
    }

    /// Whether sends run in their own process this session; false once the helper could not be
    /// prepared or started, after which sends run in Mosaic (on the main thread).
    private(set) static var usesHelperProcess = true

    private static func call(_ handler: String, _ arguments: [String]) async throws {
        if usesHelperProcess {
            do {
                let file = try await compiledScriptFile()
                try await runHelper(file: file, handler: handler, arguments: arguments)
                return
            } catch let unavailable as HelperUnavailable {
                // Nothing reached Messages: the helper never ran. Sending goes on in Mosaic itself.
                log.error("Send helper unavailable (\(unavailable.reason, privacy: .public)); sending in process")
                usesHelperProcess = false
            }
        }
        try callInProcess(handler, arguments)
    }

    // MARK: The helper process

    nonisolated static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    nonisolated static let osacompile = URL(fileURLWithPath: "/usr/bin/osacompile")
    /// The script compiled to a file for `osascript`, once per launch (again only if the file
    /// went away). Concurrent first sends share one compile.
    private static var compiling: Task<URL, Error>?
    /// Compiles done by `osacompile` this session (tests).
    private(set) static var fileCompileCount = 0

    /// Why the helper could not be used. Thrown only when nothing was handed to Messages.
    struct HelperUnavailable: Error { let reason: String }

    static func compiledScriptFile() async throws -> URL {
        if let compiling, let file = try? await compiling.value, FileManager.default.fileExists(atPath: file.path) { return file }
        let task = Task<URL, Error> {
            let folder = FileManager.default.temporaryDirectory.appending(path: "Mosaic-\(UUID().uuidString)")
            let file = folder.appending(path: "Send Messages.scpt")
            let clock = ContinuousClock()
            let started = clock.now
            let result: ToolRun
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // One -e per line, as osacompile takes a script on its command line.
                let lines = source.components(separatedBy: "\n").flatMap { ["-e", $0] }
                result = try await runTool(osacompile, ["-o", file.path] + lines)
            } catch {
                throw HelperUnavailable(reason: "could not compile: \(error.localizedDescription)")
            }
            guard result.status == 0, !result.crashed, FileManager.default.fileExists(atPath: file.path) else {
                throw HelperUnavailable(reason: "osacompile failed: \(result.errors.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let elapsed = clock.now - started
            lastCompileDuration = elapsed
            fileCompileCount += 1
            log.info("Compiled Messages script in \(String(describing: elapsed), privacy: .public)")
            return file
        }
        compiling = task
        do { return try await task.value }
        catch {
            if compiling == task { compiling = nil }
            throw error
        }
    }

    /// Runs one send in its own `osascript` process and waits for it without holding the main
    /// thread. A non-zero exit is Messages' (or the script's) refusal, reported as such.
    private static func runHelper(file: URL, handler: String, arguments: [String]) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result: ToolRun
        do {
            // "--" ends osascript's options: nothing after it (a text starting with "-") is read as one.
            result = try await runTool(osascript, ["--", file.path, handler] + arguments)
        } catch {
            throw HelperUnavailable(reason: "could not start osascript: \(error.localizedDescription)")
        }
        let elapsed = clock.now - started
        lastExecutionDuration = elapsed
        log.info("\(handler, privacy: .public) ran in \(String(describing: elapsed), privacy: .public) (helper process)")
        if result.crashed {
            // It may or may not have reached Messages: say so, and never send it again by itself.
            throw BridgeError("Mosaic couldn't tell whether Messages took this message. Check Messages before sending it again.")
        }
        guard result.status == 0 else {
            let reported = parseError(result.errors)
            throw failure(message: reported.message, number: reported.number)
        }
    }

    /// What a finished command-line tool left: its exit status and what it printed.
    struct ToolRun: Sendable {
        let status: Int32
        let crashed: Bool
        let output: String
        let errors: String
    }

    /// Runs a tool to completion off the main thread. Throws only when it could not be started.
    nonisolated static func runTool(_ executable: URL, _ arguments: [String]) async throws -> ToolRun {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            // What these tools print is a line or two, well within a pipe's buffer, so reading
            // after the exit cannot hold the tool up.
            process.terminationHandler = { finished in
                let printed = output.fileHandleForReading.readDataToEndOfFile()
                let reported = errors.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ToolRun(status: finished.terminationStatus,
                                                       crashed: finished.terminationReason == .uncaughtSignal,
                                                       output: String(decoding: printed, as: UTF8.self),
                                                       errors: String(decoding: reported, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// osascript reports a failure as "<where>: execution error: <message> (<number>)".
    nonisolated static func parseError(_ text: String) -> (message: String, number: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.range(of: "execution error: ") else { return (trimmed, nil) }
        var message = String(trimmed[marker.upperBound...])
        var number: Int?
        if message.hasSuffix(")"), let open = message.range(of: " (", options: .backwards),
           let parsed = Int(message[open.upperBound..<message.index(before: message.endIndex)]) {
            number = parsed
            message = String(message[..<open.lowerBound])
        }
        return (message.trimmingCharacters(in: .whitespacesAndNewlines), number)
    }

    /// The error a refused send shows: the Automation permission when that is what is missing,
    /// else what Messages said. Either way the draft is kept.
    nonisolated static func failure(message: String?, number: Int?) -> BridgeError {
        if number == -1743 {
            return BridgeError("Allow Mosaic to control Messages in System Settings → Privacy & Security → Automation. Your draft has been kept.")
        }
        let reason = message.flatMap { $0.isEmpty ? nil : $0 } ?? "Messages could not send this message."
        return BridgeError(reason + " Your draft has been kept.")
    }

    // MARK: In process (fallback)

    /// The compiled script for in-process sends, kept for the life of the app: compiled on first
    /// use, then only executed. Main-thread only, which is why the bridge is main-actor isolated.
    private static var compiled: NSAppleScript?
    /// How many times the in-process script has been compiled — at most once per launch. Tests check it.
    private(set) static var compileCount = 0

    static func prepareScript() throws -> NSAppleScript {
        if let compiled { return compiled }
        let clock = ContinuousClock()
        let started = clock.now
        guard let script = NSAppleScript(source: source) else { throw BridgeError("Could not prepare Messages automation.") }
        var compilationError: NSDictionary?
        guard script.compileAndReturnError(&compilationError) else {
            throw BridgeError(compilationError?[NSAppleScript.errorMessage] as? String ?? "Could not compile Messages automation.")
        }
        compileCount += 1
        let elapsed = clock.now - started
        lastCompileDuration = elapsed
        log.info("Compiled Messages script in process in \(String(describing: elapsed), privacy: .public)")
        compiled = script
        return script
    }

    /// Runs a handler in Mosaic itself. This blocks the main thread until Messages answers.
    private static func callInProcess(_ handler: String, _ arguments: [String]) throws {
        let script = try prepareScript()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() { parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1) }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let clock = ContinuousClock()
        let started = clock.now
        _ = script.executeAppleEvent(event, error: &error)
        let elapsed = clock.now - started
        lastExecutionDuration = elapsed
        log.info("\(handler, privacy: .public) ran in \(String(describing: elapsed), privacy: .public) (in process)")
        if let error {
            throw failure(message: error[NSAppleScript.errorMessage] as? String, number: error[NSAppleScript.errorNumber] as? Int)
        }
    }

    struct BridgeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
