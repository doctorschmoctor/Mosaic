import AppKit
import Carbon

enum MessagesBridge {
    private static let source = """
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

    /// Arguments are Apple event descriptors, never interpolated into executable script.
    /// Use the exact chat GUID; a failed lookup must never fall back to another recipient.
    static func prepareScript() throws -> NSAppleScript {
        guard let script = NSAppleScript(source: source) else { throw BridgeError("Could not prepare Messages automation.") }
        var compilationError: NSDictionary?
        guard script.compileAndReturnError(&compilationError) else {
            throw BridgeError(compilationError?[NSAppleScript.errorMessage] as? String ?? "Could not compile Messages automation.")
        }
        return script
    }

    static func send(text: String, conversationID: String) throws {
        try call("sendMessage", [text, conversationID])
    }
    /// Starts (or continues) a one-to-one conversation with a handle that has no chat yet. Messages
    /// creates the chat; it shows up in the database afterwards. Group chats cannot be created this
    /// way: Messages offers no automation for it.
    static func send(text: String, toNewRecipient handle: String, service: String = "iMessage") throws {
        try call("sendToParticipant", [text, handle, serviceKind(service)])
    }
    /// Sends a file (a picture, a document) to an existing conversation. The file must be where
    /// Messages' sandbox can read it — see `OutgoingFiles.stage`; a file elsewhere is accepted and
    /// then fails to send.
    static func send(filePath: String, conversationID: String) throws {
        try call("sendFile", [filePath, conversationID])
    }
    static func send(filePath: String, toNewRecipient handle: String, service: String = "iMessage") throws {
        try call("sendFileToParticipant", [filePath, handle, serviceKind(service)])
    }
    private static func serviceKind(_ service: String) -> String {
        service.caseInsensitiveCompare("SMS") == .orderedSame ? "SMS" : "iMessage"
    }

    private static func call(_ handler: String, _ arguments: [String]) throws {
        let script = try prepareScript()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() { parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1) }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        _ = script.executeAppleEvent(event, error: &error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 {
                throw BridgeError("Allow Mosaic to control Messages in System Settings → Privacy & Security → Automation. Your draft has been kept.")
            }
            throw BridgeError((error[NSAppleScript.errorMessage] as? String ?? "Messages could not send this message.") + " Your draft has been kept.")
        }
    }
    struct BridgeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
