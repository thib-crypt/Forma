import Foundation
import AppKit

/// The App Group shared by Forma and its extensions.
///
/// ```
/// ~/Library/Group Containers/PG46BWSK3T.com.thibault.forma/
///   Inbox/<id>.json          requests waiting for the app
///   Inbox/<id>/files/        copies made by the Share extension
///   menu.json                menu configuration, written by the app
/// ```
/// Only binaries signed by the team can write here, so a request found in the inbox is genuine.
enum GroupContainer {
    static let identifier = "PG46BWSK3T.com.thibault.forma"
    static let scheme = "forma"
    static let appBundleID = "com.thibault.forma"
    /// Darwin notification posted by the app after rewriting menu.json.
    static let menuChangedNotification = "com.thibault.forma.menu-changed"
    /// Darwin notification posted by the extensions after writing a request (a running Forma drains its inbox).
    static let inboxNotification = "com.thibault.forma.inbox"

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
    static var inbox: URL? { root?.appendingPathComponent("Inbox", isDirectory: true) }
    static var menuConfigURL: URL? { root?.appendingPathComponent("menu.json") }

    static func requestURL(_ id: UUID) -> URL? { inbox?.appendingPathComponent("\(id.uuidString).json") }

    /// Where the Share extension copies items that only exist as data (an image shared from Safari or Photos).
    static func stagingDirectory(for id: UUID) throws -> URL {
        guard let inbox else { throw GroupError.unavailable }
        let dir = inbox.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum GroupError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Le conteneur partagé de Forma est inaccessible (signature ou App Group)." }
    }

    // MARK: Requests

    /// Writes the request where the app will find it, then wakes Forma without activating it.
    static func submit(_ request: ExternalRequest, hostApp: URL? = nil) throws {
        guard let inbox, let url = requestURL(request.id) else { throw GroupError.unavailable }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try RequestCodec.encode(request).write(to: url, options: .atomic)
        // Two paths: the notification reaches a running Forma even if the sandbox refuses to open the URL,
        // the URL launches Forma when it isn't running. Requests are deduplicated by id.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(inboxNotification as CFString), nil, nil, true)
        wake(request.id, hostApp: hostApp)
    }

    static func jobURL(_ id: UUID) -> URL { URL(string: "\(scheme)://job/\(id.uuidString)")! }

    /// Opens `forma://job/<id>`. When Forma isn't running it is launched in the background (`--headless`).
    static func wake(_ id: UUID, hostApp: URL?) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        config.arguments = ["--headless"]
        let url = jobURL(id)
        if let app = preferredAppURL(hostApp: hostApp) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
                if let error { NSLog("Forma: cannot wake the app: \(error.localizedDescription)") }
            }
        } else {
            NSWorkspace.shared.open(url, configuration: config) { _, _ in }
        }
    }

    static let installedAppURL = URL(fileURLWithPath: "/Applications/Forma.app")

    /// A Forma app process already running (GUI or headless; the CLI never has an activation policy).
    static func runningApp(excludingSelf: Bool = true) -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).first {
            !$0.isTerminated && $0.activationPolicy != .prohibited && (!excludingSelf || $0.processIdentifier != me)
        }
    }

    /// Which copy of Forma.app to hand a request to. Several copies can be registered (/Applications plus the
    /// Xcode build folders, whose extensions PlugInKit may prefer): opening the URL with a copy that isn't the one
    /// running would start a second instance, so the running one wins, then /Applications, then the host app.
    static func preferredAppURL(hostApp: URL? = nil) -> URL? {
        if let running = runningApp(excludingSelf: false)?.bundleURL { return running }
        if FileManager.default.fileExists(atPath: installedAppURL.path) { return installedAppURL }
        return hostApp ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
    }

    /// Requests still waiting in the inbox, oldest first.
    static func pendingRequests() -> [URL] {
        guard let inbox, let names = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return names.filter { $0.pathExtension == "json" }
            .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
    }

    /// True when a request was dropped in the inbox a moment ago: Forma is being launched to handle it.
    static func hasFreshRequest(within seconds: TimeInterval = 20) -> Bool {
        let now = Date()
        return pendingRequests().contains { now.timeIntervalSince($0.modificationDate ?? .distantPast) < seconds }
    }

    /// The app that contains this extension (…/Forma.app/Contents/PlugIns/X.appex → …/Forma.app).
    static func hostAppURL(of bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL
        guard url.pathExtension == "appex" else { return nil }
        let app = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    // MARK: Menu configuration

    static func postMenuChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(menuChangedNotification as CFString), nil, nil, true)
    }
}

extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
