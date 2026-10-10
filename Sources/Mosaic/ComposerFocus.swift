import AppKit
import os

/// Puts the keyboard in a tile's message field when Mosaic asks for it: opening a conversation (a
/// click on its row, Return in the list or the search field, the menu, a drop), Tab, a click in a
/// thread, on a tile's header or on a Focus chip, closing the Photos card or the file chooser.
///
/// A request stays a request until it is confirmed. The keyboard is handed over outside SwiftUI's
/// view updates, at a moment of rest — when the run loop is about to wait, after the event that
/// asked and the updates it caused (a new tile's field being made and put in the window) are done —
/// and only to the field that is live in the workspace window now, never to one a closure kept.
/// The request completes once that field is the window's first responder at a moment of rest, so
/// whatever the opening itself did to the keyboard afterwards (the list's table taking it on the
/// press, the search field letting go) cannot leave it elsewhere. A failed or displaced attempt
/// stays pending and is tried again, a few times, at the next moments of rest, and again whenever
/// the field joins the window or the window becomes key.
///
/// Only the newest request counts. Any press of the mouse, ⌘F or ⌘L, and closing or replacing the
/// tile cancel it, so a request can never take the keyboard from something chosen after it.
/// Becoming first responder some other way (a click in the field) selects the tile
/// (`WorkspaceStore.focus`) and asks for nothing.
@MainActor final class ComposerFocus {
    struct Request: Equatable, CustomStringConvertible {
        let conversationID: String
        let token: Int
        var description: String { "#\(token) \(conversationID)" }
    }
    /// The request being carried out, until it is confirmed or cancelled.
    private(set) var pending: Request?
    /// The last request confirmed (tests).
    private(set) var lastCompleted: Request?
    /// How many times the keyboard was handed over for a request (tests).
    private(set) var claimCount = 0
    /// The workspace window; a field in any other window is not the one asked for.
    private(set) weak var window: NSWindow?
    /// Whether a conversation still has a tile (a request for one that has none is dropped).
    var isOpen: (String) -> Bool = { _ in true }

    /// Hand-overs one request makes at moments of rest before it waits for the field to join the
    /// window or the window to become key.
    static let maximumClaims = 4
    /// Moments of rest a request waits for its field to be in the window before it waits for the
    /// field itself to say it arrived.
    static let maximumWaits = 12

    private var claims = 0
    private var waits = 0
    private var observer: CFRunLoopObserver?
    private var pressMonitor: Any?
    private var keyObserver: NSObjectProtocol?
    private static let log = Logger(subsystem: "com.doctorschmoctor.Mosaic", category: "ComposerFocus")

    deinit {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    /// The workspace's window (from the view that hosts it): requests are carried out there, a
    /// press anywhere cancels one, and the window becoming key tries a pending one again.
    func attach(window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry("the window became key") }
        }
        if pressMonitor == nil {
            pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.readerPressed() }
                return event
            }
        }
        retry("the window is known")
    }

    /// Asks for the keyboard in a conversation's field; replaces any earlier request.
    func request(_ conversationID: String, token: Int) {
        pending = Request(conversationID: conversationID, token: token)
        claims = 0
        waits = 0
        trace("request")
        watchForRest()
    }
    /// Drops the pending request, if any.
    func cancel(_ reason: String) {
        guard pending != nil else { return }
        trace("cancelled: \(reason)")
        pending = nil
        stopWatching()
    }
    /// The conversation's tile closed or was replaced: a request for it has nowhere to go.
    func cancel(for conversationID: String) {
        if pending?.conversationID == conversationID { cancel("its tile closed") }
    }
    /// The reader pressed the mouse somewhere: whatever they pressed is their choice now.
    func readerPressed() { cancel("the reader pressed the mouse") }

    /// A message field joined a window: if it is the one asked for, it is tried now.
    func editorDidMoveToWindow(_ editor: DraftTextView) {
        guard let pending, editor.conversationID == pending.conversationID, editor.window != nil else { return }
        retry("its field joined the window")
    }
    private func retry(_ reason: String) {
        guard pending != nil else { return }
        claims = 0
        waits = 0
        trace("again: \(reason)")
        watchForRest()
    }

    /// The field asked for, as it is in the workspace window now.
    private func liveEditor(for conversationID: String) -> DraftTextView? {
        DraftTextView.editors(for: conversationID).last { editor in
            editor.conversationID == conversationID && editor.window != nil && (window == nil || editor.window === window)
        }
    }

    /// A moment of rest: the event that asked and the view updates it caused are done.
    private func atRest() {
        guard let request = pending else { stopWatching(); return }
        guard isOpen(request.conversationID) else { cancel("its tile is gone"); return }
        guard let editor = liveEditor(for: request.conversationID), let window = editor.window else {
            waits += 1
            trace("waiting for its field (\(waits))")
            // From here the field itself says when it arrives (`editorDidMoveToWindow`).
            if waits >= Self.maximumWaits { stopWatching() }
            return
        }
        if window.firstResponder === editor {
            // Confirmed: the field has the keyboard at a moment of rest.
            trace("confirmed")
            pending = nil
            lastCompleted = request
            stopWatching()
            return
        }
        guard claims < Self.maximumClaims else {
            trace("displaced \(claims) times; waiting for the field or the window")
            stopWatching()
            return
        }
        claims += 1
        claimCount += 1
        let accepted = window.makeFirstResponder(editor)
        let holds = window.firstResponder === editor
        trace("hand-over \(claims): accepted \(accepted), holds \(holds), key window \(window.isKeyWindow), first responder \(Self.name(of: window.firstResponder))")
        // The caret goes to the end of the draft once the field is known to have the keyboard,
        // before anything else can be typed; a field that already had it keeps its selection.
        if accepted, holds { editor.placeCaretAtEnd() }
        // Confirmed (or tried again) at the next moment of rest, which this brings on promptly.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {}
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func watchForRest() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_500_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.atRest() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    private func stopWatching() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
    }

    /// What happened to a request, in the unified log at debug level (`log stream --level debug
    /// --predicate 'category == "ComposerFocus"'`): enough to see which responder won when a
    /// hand-over fails.
    private func trace(_ step: String) {
        let label = pending?.description ?? "no request"
        Self.log.debug("\(label, privacy: .public): \(step, privacy: .public)")
    }
    static func name(of responder: NSResponder?) -> String {
        switch responder {
        case nil: return "none"
        case let editor as DraftTextView: return "message field (\(editor.conversationID))"
        case let text as NSTextView where text.isFieldEditor: return "a text field"
        case is NSTableView: return "the conversation list"
        case is SidebarKeyFocus.CatcherView: return "the list's keyboard"
        case is NSWindow: return "the window"
        default: return String(describing: type(of: responder!))
        }
    }
}
