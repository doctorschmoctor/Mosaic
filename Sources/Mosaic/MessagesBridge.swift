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
        let script = try prepareScript()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "sendMessage"), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(string: text), at: 1)
        parameters.insert(NSAppleEventDescriptor(string: conversationID), at: 2)
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
