import Foundation
import AppKit

/// How this process was started, and the Dock icon policy that follows from it.
@MainActor
enum LaunchContext {
    /// Started by an extension (or `--headless`): no window, no Dock icon, quits when idle if the menu bar item is off.
    static var headless = false

    /// Decided in `main()`, before the app object exists, so the window is never presented and the Dock never bounces.
    nonisolated static func detectHeadless(_ args: [String]) -> Bool {
        args.contains("--headless") || GroupContainer.hasFreshRequest()
    }

    static var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.level == .normal }
    }

    /// Dock icon rule (Settings › Général › Présence). A headless launch never shows one until a window opens.
    static func desiredPolicy(windowShown: Bool) -> NSApplication.ActivationPolicy {
        switch PreferencesStore.shared.prefs.effectiveDockIcon {
        case .always: headless && !windowShown ? .accessory : .regular
        case .withWindows: windowShown ? .regular : .accessory
        case .never: .accessory
        }
    }

    static func updateDockPolicy(animated: Bool = false) {
        apply(desiredPolicy(windowShown: hasVisibleWindow), keepFocus: animated)
    }

    /// The user opened a window: Forma is now an ordinary, interactive app (with or without a Dock icon).
    static func becomeInteractive() {
        headless = false
        quitWork?.cancel()
        apply(desiredPolicy(windowShown: true), keepFocus: false)
    }

    private static func apply(_ wanted: NSApplication.ActivationPolicy, keepFocus: Bool) {
        guard NSApp.activationPolicy() != wanted else { return }
        let key = NSApp.keyWindow
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(wanted)
        // Leaving the Dock deactivates the app on some systems: keep the window the user is looking at in front.
        if keepFocus, wasActive, let key {
            DispatchQueue.main.async {
                NSApp.activate()
                key.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static var quitWork: DispatchWorkItem?

    /// A headless launch ends once the queue is empty, the HUD gone and no window open (unless the menu bar item keeps Forma around).
    static func quitIfIdle(after delay: TimeInterval) {
        quitWork?.cancel()
        guard headless else { return }
        let w = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard headless, !PreferencesStore.shared.prefs.showInMenuBar, !JobCenter.shared.isBusy,
                      !AppModel.shared.isRunning, !ProgressHUD.shared.isVisible, !hasVisibleWindow else { return }
                NSApp.terminate(nil)
            }
        }
        quitWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

/// Entry point for everything that reaches Forma from outside the window: `forma://` URLs, the App Group inbox,
/// Services and menu bar drops.
@MainActor
final class RequestRouter {
    static let shared = RequestRouter()
    private var handled = Set<UUID>()

    /// Registered in `applicationWillFinishLaunching`, so the URL that launched the app comes here too and SwiftUI
    /// never opens a window for it.
    func installURLHandler() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { RequestRouter.shared.drainInbox() } }
        }, GroupContainer.inboxNotification as CFString, nil, .deliverImmediately)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        handle(url)
    }

    /// Picks up requests written while Forma was not running (or whose URL got lost).
    func drainInbox() {
        let now = Date()
        for file in GroupContainer.pendingRequests() {
            // Anything older than an hour is stale (Forma crashed or was killed): drop it rather than surprise the user.
            if now.timeIntervalSince(file.modificationDate ?? now) > 3600 {
                discard(file)
                continue
            }
            load(file)
        }
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == GroupContainer.scheme else { return }
        let host = url.host()?.lowercased() ?? ""
        if host == "job" {
            if let id = UUID(uuidString: url.lastPathComponent), let file = GroupContainer.requestURL(id),
               FileManager.default.fileExists(atPath: file.path) {
                load(file)
            }
            drainInbox()
            return
        }
        guard let request = Self.publicRequest(url) else {
            Toast.show("Lien Forma non reconnu", symbol: "link.badge.plus")
            return
        }
        dispatch(request, trusted: false)
    }

    private func load(_ file: URL) {
        // Claim the file first: rename is atomic, so if two Forma processes ever see the same request
        // (a second copy launched by an extension), only one of them processes it.
        let claimed = file.appendingPathExtension("claimed-\(ProcessInfo.processInfo.processIdentifier)")
        guard rename(file.path, claimed.path) == 0 else { return }
        defer { discard(claimed) }
        guard let data = try? Data(contentsOf: claimed), let request = try? RequestCodec.decode(data) else {
            NSLog("Forma: unreadable request \(file.lastPathComponent)")
            return
        }
        guard handled.insert(request.id).inserted else { return }
        dispatch(request, trusted: true)
    }

    private func discard(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    // MARK: Dispatch

    func dispatch(_ r: ExternalRequest, trusted: Bool) {
        let urls = r.paths.map { URL(fileURLWithPath: $0) }
        switch r.action {
        case .process, .recipe, .upload:
            JobCenter.shared.submit(r, trusted: trusted)
        case .open:
            LaunchContext.becomeInteractive()
            AppDelegate.showMainWindow()
            let n = AppModel.shared.add(urls, mode: r.target == nil ? nil : r.mode, autoStart: false)
            if n == 0 { Toast.show("Aucun fichier compatible dans la sélection", symbol: "exclamationmark.triangle") }
        case .undo:
            undo(batch: r.batch)
        case .watch:
            guard trusted, let folder = urls.first else { return }
            watch(folder)
        case .clipboard:
            ClipboardOptimizer.shared.optimizeNow()
            LaunchContext.quitIfIdle(after: 4)
        case .refresh:
            MenuConfigPublisher.shared.publishNow()
            LaunchContext.quitIfIdle(after: 1)
        case .showApp:
            LaunchContext.becomeInteractive()
            AppDelegate.showMainWindow()
        case .settings:
            LaunchContext.becomeInteractive()
            SettingsNavigation.shared.tab = .finder
            AppDelegate.showSettings()
        }
    }

    private func undo(batch: UUID?) {
        let entries = HistoryStore.shared.fetch()
        let target: [HistoryEntry]
        if let batch {
            target = entries.filter { $0.batch == batch && !$0.isUndone }
        } else if let last = entries.first(where: { !$0.isUndone && $0.origin.isExternal }) {
            target = entries.filter { $0.batch == last.batch && !$0.isUndone }
        } else {
            target = []
        }
        guard !target.isEmpty else {
            Toast.show("Rien à annuler", symbol: "arrow.uturn.backward")
            LaunchContext.quitIfIdle(after: 3)
            return
        }
        let msg = HistoryModel.shared.undo(target)
        JobCenter.shared.jobs.filter { $0.batch == target.first?.batch }.forEach { $0.undone = true }
        Toast.show(msg, symbol: "arrow.uturn.backward")
        MenuConfigPublisher.shared.setNeedsPublish()
        LaunchContext.quitIfIdle(after: 3.5)
    }

    /// "Surveiller ce dossier avec Forma…": a watched folder pre-filled with the current targets, then the settings.
    private func watch(_ folder: URL) {
        let store = PreferencesStore.shared
        let path = folder.standardizedFileURL.path
        if !store.prefs.watchedFolders.contains(where: { $0.path == path }) {
            var f = WatchedFolder(path: path)
            f.mode = .convert
            f.imageTarget = store.prefs.finder.favorites(for: .image).first ?? store.prefs.processing.imageTarget
            f.videoTarget = store.prefs.processing.videoTarget
            f.audioTarget = store.prefs.processing.audioTarget
            f.officeTarget = store.prefs.processing.officeTarget
            store.prefs.watchedFolders.append(f)
            FolderWatcher.shared.reload()
        }
        LaunchContext.becomeInteractive()
        SettingsNavigation.shared.tab = .automation
        AppDelegate.showSettings()
    }

    // MARK: Public scheme

    /// `forma://convert?to=webp&path=/a.png&path=/b.png`, `forma://compress?preset=web_optimized&path=…`,
    /// `forma://upscale?path=…`, `forma://recipe?name=Web&path=…`, `forma://open?path=…`.
    /// For Raycast, Alfred, BetterTouchTool, Copia. Any web page can open such a link, so it never replaces originals.
    static func publicRequest(_ url: URL) -> ExternalRequest? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
        let paths = items.filter { $0.name == "path" || $0.name == "file" }.compactMap(\.value)
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { $0.hasPrefix("/") }
        guard !paths.isEmpty else { return nil }
        var r = ExternalRequest(source: .url, paths: paths)
        switch url.host()?.lowercased() {
        case "convert":
            guard let to = value("to"), let f = FormatCatalog.resolve(to) else { return nil }
            r.mode = .convert
            r.target = f.id
        case "compress": r.mode = .compress
        case "upscale": r.mode = .upscale
        case "open": r.action = .open
        case "recipe":
            guard let name = value("name"), let recipe = PreferencesStore.shared.prefs.recipes.named(name) else { return nil }
            r.action = .recipe
            r.recipe = recipe.id
        default: return nil
        }
        var o = RequestOverrides()
        if let p = value("preset").flatMap({ CompressionPreset(rawValue: $0.replacingOccurrences(of: "-", with: "_")) }) { o.preset = p }
        if let q = value("quality").flatMap(Int.init), (1...100).contains(q) { o.quality = q }
        if let d = value("max").flatMap(Int.init), d > 0 { o.maxDimension = d }
        if !o.isEmpty { r.overrides = o }
        if value("dest") == "clipboard" { r.destination = .clipboard }
        return r
    }
}

/// Which settings tab to show (the Finder menu's "Réglages…" entry jumps to the Finder tab).
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    enum Tab: String, Hashable { case general, images, video, audio, output, automation, clipboard, finder, drop, presets, engines }
    var tab: Tab = .general
}
