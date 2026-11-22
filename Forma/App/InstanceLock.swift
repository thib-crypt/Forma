import AppKit

/// An advisory lock held for the lifetime of the app process. The kernel drops it when the process dies,
/// so a crash never leaves Forma "locked". The CLI never takes it.
enum InstanceLock {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func acquire() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forma", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path
        fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }   // can't lock: don't block the launch
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}

/// A second Forma process: forwards the URLs / files it receives to the running one, wakes its inbox, and quits.
/// It never builds the SwiftUI scenes, so no window, menu bar item or Dock icon appears.
enum DuplicateLaunch {
    static func run(headless: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = ForwardingDelegate(headless: headless)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    private final class ForwardingDelegate: NSObject, NSApplicationDelegate {
        let headless: Bool
        private var forwarded = false
        init(headless: Bool) { self.headless = headless }

        func applicationWillFinishLaunching(_ notification: Notification) {
            NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                         forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(GroupContainer.inboxNotification as CFString), nil, nil, true)
            // Launch events (URLs, files) arrive right after launch; give them a moment, then leave.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !self.forwarded && !self.headless && !GroupContainer.hasFreshRequest(within: 5) {
                    // A plain double-click on the other copy: bring the running Forma forward instead.
                    self.forward([], activate: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
            }
        }

        @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
            // forma://job/… is already in the inbox, which the notification above makes the running app drain.
            if url.host()?.lowercased() == "job" { forwarded = true; return }
            forward([url], activate: false)
        }

        func application(_ application: NSApplication, open urls: [URL]) {
            forward(urls, activate: urls.contains(where: \.isFileURL))
        }

        private func forward(_ urls: [URL], activate: Bool) {
            forwarded = true
            guard let primary = GroupContainer.runningApp() else { return }
            if urls.isEmpty {
                // Same as clicking the Dock icon: the running app reopens its main window.
                if let bundle = primary.bundleURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, _ in }
                }
                return
            }
            guard let bundle = primary.bundleURL else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activate
            config.addsToRecentItems = false
            NSWorkspace.shared.open(urls, withApplicationAt: bundle, configuration: config) { _, _ in }
        }
    }
}
