import Foundation
import AppKit
import Contacts
import ImageIO
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// Whether this process is a fixture run — the test suite, the preview renderer, a `--demo` or
/// `--isolated` launch, or one started with `MOSAIC_ISOLATED=1` — rather than the installed app.
/// A fixture run never reaches the user's accounts or files: it reads no Contacts and asks for no
/// permission, keeps outgoing files in a temporary folder of its own (so its cleanup can never
/// remove a file the installed app's drafts point at), keeps its preferences apart from the app's,
/// reads no Messages database it was not given, and has no way to send.
enum MosaicRuntime {
    static let isIsolated: Bool = {
        let info = ProcessInfo.processInfo
        if NSClassFromString("XCTestCase") != nil { return true }
        if info.environment["MOSAIC_ISOLATED"] == "1" { return true }
        return info.arguments.contains("--isolated") || info.arguments.contains("--demo")
    }()
    /// A fixture run's own folder (in the temporary directory, one per process).
    static let isolatedRoot: URL = FileManager.default.temporaryDirectory
        .appending(path: "Mosaic-isolated-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
    /// The preferences a fixture launch of the app uses instead of the installed app's.
    static let isolatedDefaultsSuite = "com.doctorschmoctor.Mosaic.isolated"
}

/// What a workspace store reaches outside itself: where contact names and photos come from, and
/// where outgoing files are kept. The installed app uses the system's; fixture runs (tests, the
/// preview renderer, `--demo` and `--isolated` launches) get fictional contacts and a temporary
/// folder, and tests can pass their own.
struct StoreServices {
    var contacts: any ContactsSource
    var outgoing: OutgoingStorage

    static var system: StoreServices { StoreServices(contacts: SystemContacts(), outgoing: .system) }
    static func isolated(contacts: any ContactsSource = FixtureContacts(), outgoing: OutgoingStorage = .isolated) -> StoreServices {
        StoreServices(contacts: contacts, outgoing: outgoing)
    }
    /// The installed app's services, or a fixture run's.
    static var processDefault: StoreServices { MosaicRuntime.isIsolated ? .isolated() : .system }
}

/// Where outgoing files live: `pending` holds the pictures Mosaic writes (pasted, dropped, picked
/// from Photos) until they are sent; `staging` is where each file is copied for Messages to take.
/// A store only ever removes files inside its own `pending` folder.
struct OutgoingStorage: Equatable, Sendable {
    var pending: URL
    var staging: URL

    static let system = OutgoingStorage(
        pending: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Mosaic/Outgoing", directoryHint: .isDirectory),
        staging: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/.mosaic-outgoing", directoryHint: .isDirectory))
    /// A fixture run's folders, inside its own temporary folder.
    static let isolated = OutgoingStorage(root: MosaicRuntime.isolatedRoot)
    static var processDefault: OutgoingStorage { MosaicRuntime.isIsolated ? isolated : system }

    /// Both folders inside `root`.
    init(root: URL) {
        pending = root.appending(path: "Outgoing", directoryHint: .isDirectory)
        staging = root.appending(path: "Staging", directoryHint: .isDirectory)
    }
    init(pending: URL, staging: URL) { self.pending = pending; self.staging = staging }

    /// Whether a file is one this storage wrote (and may remove), never one the user chose.
    func owns(_ url: URL) -> Bool {
        let folder = pending.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

/// Contact names, handles and photos: Contacts on this Mac, or fictional ones for a fixture run.
/// Every call may be slow or fail; the store never waits on one to show Messages' history.
protocol ContactsSource: Sendable {
    /// Whether Mosaic may read contacts. Asked off the main thread.
    func authorizationStatus() async -> CNAuthorizationStatus
    /// Asks the person for access (shows the system prompt). Only ever called from the settings' button.
    func requestAccess() async -> Bool
    /// Every named contact with its handles, and which handles lead to a contact with a photo.
    func entries() async throws -> ContactsSnapshot
    /// One contact's thumbnail, decoded small.
    func thumbnail(forContact contactID: String) async -> CGImage?
}

struct ContactsSnapshot: Sendable {
    var entries: [ContactNames.Entry]
    /// Which contact each comparable handle (`Recipient.key`) belongs to, for contacts with a photo.
    var photoIDs: [String: String] = [:]
}

/// The Contacts on this Mac, through `CNContactStore`. Nothing here runs on the main thread.
struct SystemContacts: ContactsSource {
    func authorizationStatus() async -> CNAuthorizationStatus {
        await Task.detached(priority: .userInitiated) { CNContactStore.authorizationStatus(for: .contacts) }.value
    }
    func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }
    func entries() async throws -> ContactsSnapshot {
        // Names and addresses only, and whether each contact has a photo: the photos themselves
        // are fetched one contact at a time, for the avatars that are shown.
        try await Task.detached(priority: .userInitiated) { () -> ContactsSnapshot in
            let request = CNContactFetchRequest(keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactIdentifierKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor, CNContactImageDataAvailableKey as CNKeyDescriptor])
            var snapshot = ContactsSnapshot(entries: [])
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                let addresses = contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }
                // Each of the contact's numbers and addresses leads to its photo.
                if contact.imageDataAvailable {
                    for address in addresses { snapshot.photoIDs[Recipient.key(for: address)] = contact.identifier }
                }
                let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                let name = [formatted, contact.nickname, contact.organizationName].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                guard !name.isEmpty else { return }
                snapshot.entries.append(ContactNames.Entry(id: contact.identifier, name: name, addresses: addresses))
            }
            return snapshot
        }.value
    }
    func thumbnail(forContact contactID: String) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
            guard let contact = try? CNContactStore().unifiedContact(withIdentifier: contactID, keysToFetch: keys),
                  let data = contact.thumbnailImageData,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 120]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

/// Fictional contacts for fixture runs. By default access was never decided, as on a fresh Mac,
/// so nothing loads at launch; a test can choose a status, entries, a delay or a failure. It
/// counts what it was asked, so a test can check that nothing asked more than it should.
final class FixtureContacts: ContactsSource, @unchecked Sendable {
    private let lock = NSLock()
    private let status: CNAuthorizationStatus
    private let fixture: ContactsSnapshot
    private let delay: Duration
    private let failure: String?
    private var counts = (status: 0, requests: 0, entries: 0)

    init(status: CNAuthorizationStatus = .notDetermined, entries: [ContactNames.Entry] = [], delay: Duration = .zero, failure: String? = nil) {
        self.status = status
        fixture = ContactsSnapshot(entries: entries)
        self.delay = delay
        self.failure = failure
    }
    var statusQueries: Int { locked { counts.status } }
    var accessRequests: Int { locked { counts.requests } }
    var entryReads: Int { locked { counts.entries } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func authorizationStatus() async -> CNAuthorizationStatus {
        locked { counts.status += 1 }
        return status
    }
    func requestAccess() async -> Bool {
        locked { counts.requests += 1 }
        return status == .authorized
    }
    func entries() async throws -> ContactsSnapshot {
        locked { counts.entries += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw TransportError(failure) }
        return fixture
    }
    func thumbnail(forContact contactID: String) async -> CGImage? { nil }
}

/// The transport a fixture run gets when none was given: it refuses every send, so a test or an
/// audit launch can never hand anything to Messages by accident.
@MainActor final class UnavailableTransport: MessageTransport {
    let capabilities = TransportCapabilities.messagesAppleScript
    private(set) var refusals = 0
    func send(text: String, to target: SendTarget) async throws { refusals += 1; throw TransportError("Sending is off in this run.") }
    func send(file: URL, to target: SendTarget) async throws { refusals += 1; throw TransportError("Sending is off in this run.") }
}
