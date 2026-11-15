import Foundation
import AppKit
import UserNotifications
import ServiceManagement
import CoreServices

// MARK: - Notifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { NSLog("Forma login item: \(error)") }
    }
}

// MARK: - Command-line tool

enum CLIInstaller {
    static let linkPath = "/usr/local/bin/forma"
    static var executable: String { Bundle.main.executableURL?.path ?? "/Applications/Forma.app/Contents/MacOS/Forma" }
    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == executable
    }

    @discardableResult
    static func install() -> String? {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: "/usr/local/bin") {
            try? fm.removeItem(atPath: linkPath)
            do { try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: executable); return nil }
            catch { return error.localizedDescription }
        }
        return runPrivileged("mkdir -p /usr/local/bin && ln -sf '\(executable)' '\(linkPath)'")
    }

    @discardableResult
    static func uninstall() -> String? {
        if (try? FileManager.default.removeItem(atPath: linkPath)) != nil { return nil }
        return runPrivileged("rm -f '\(linkPath)'")
    }

    private static func runPrivileged(_ cmd: String) -> String? {
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        return err?[NSAppleScript.errorMessage] as? String
    }
}

// MARK: - Finder Services (right-click → Services)

final class ServicesProvider: NSObject {
    @objc func addFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, mode: nil, start: false)
    }
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, mode: .convert, start: true)
    }
    @objc func compressFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, mode: .compress, start: true)
    }
    @objc func upscaleFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, mode: .upscale, start: true)
    }
    /// "Ajouter" fills the window as before; the other services run in the background (`JobCenter`), without a window.
    private func handle(_ pb: NSPasteboard, mode: ProcessMode?, start: Bool) {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        Task { @MainActor in
            guard start, let mode else {
                AppDelegate.showMainWindow()
                let n = AppModel.shared.add(urls, mode: mode, autoStart: start)
                if n == 0 { Toast.show("Aucun fichier compatible dans la sélection", symbol: "exclamationmark.triangle") }
                return
            }
            guard !urls.isEmpty else { NSSound.beep(); return }
            JobCenter.shared.submit(ExternalRequest(source: .service, mode: mode, paths: urls.map(\.path)))
        }
    }
}

// MARK: - Watched folders (FSEvents)

@MainActor
final class FolderWatcher {
    static let shared = FolderWatcher()
    private var stream: FSEventStreamRef?
    private var pending: [String: Date] = [:]
    private var processing = Set<String>()
    private var debounce: Timer?
    private let limiter = AsyncLimiter(2)
    private(set) var activeCount = 0

    func reload() {
        stop()
        let folders = PreferencesStore.shared.prefs.watchedFolders.filter(\.enabled)
        guard !folders.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            let fl = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { me.handle(zip(arr, fl).map { ($0, $1) }) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, cb, &ctx, folders.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        for f in folders where f.processExisting && f.lastRun == nil { scanExisting(f) }
    }

    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }

    private func scanExisting(_ folder: WatchedFolder) {
        let urls = Pipeline.expand([URL(fileURLWithPath: folder.path)], recursive: folder.includeSubfolders)
        for u in urls where !isInOutput(u.path, folder) { pending[u.path] = .distantPast }
        schedule()
    }

    private func handle(_ events: [(String, FSEventStreamEventFlags)]) {
        for (path, flag) in events {
            let isFile = flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
            let created = flag & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified) != 0
            guard isFile, created, FileManager.default.fileExists(atPath: path), folder(for: path) != nil else { continue }
            if (path as NSString).lastPathComponent.hasPrefix(".") || processing.contains(path) { continue }
            pending[path] = Date()
        }
        schedule()
    }

    private func schedule() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated { self.flush() }
        }
    }

    private func folder(for path: String) -> WatchedFolder? {
        PreferencesStore.shared.prefs.watchedFolders.first { f in
            guard f.enabled, path.hasPrefix(f.path + "/"), !isInOutput(path, f) else { return false }
            let rel = path.dropFirst(f.path.count + 1)
            return f.includeSubfolders || !rel.contains("/")
        }
    }

    private func isInOutput(_ path: String, _ f: WatchedFolder) -> Bool {
        path.hasPrefix(f.path + "/" + f.outputSubfolder + "/") || path.contains("/.forma-")
    }

    private func flush() {
        let ready = pending
        pending.removeAll()
        for (path, _) in ready {
            guard let f = folder(for: path), FileDetection.classify(URL(fileURLWithPath: path)) != .unsupported else { continue }
            processing.insert(path)
            Task { await self.process(path, folder: f) }
        }
    }

    private func process(_ path: String, folder: WatchedFolder) async {
        defer { processing.remove(path) }
        let url = URL(fileURLWithPath: path)
        // Wait until the file is fully written (size stable for 1 s).
        var last: Int64 = -1
        for _ in 0..<30 {
            let s = url.fileSize
            if s == last && s > 0 { break }
            last = s
            try? await Task.sleep(for: .seconds(1))
        }
        var snap = PreferencesStore.shared.prefs.processing
        snap.imageTarget = folder.imageTarget
        snap.videoTarget = folder.videoTarget
        snap.audioTarget = folder.audioTarget
        if let t = folder.officeTarget { snap.officeTarget = t }
        snap.output.replaceOriginals = false
        snap.output.destination = .alongside
        let out = URL(fileURLWithPath: folder.path).appendingPathComponent(folder.outputSubfolder.isEmpty ? "Forma" : folder.outputSubfolder)
        activeCount += 1
        defer { activeCount -= 1 }
        let snapshot = snap
        await limiter.run {
            do {
                let r = try await Pipeline.run(input: url, mode: folder.mode, snapshot: snapshot, index: 1, outputFolder: out, origin: .watch) { _ in }
                await MainActor.run {
                    if let i = PreferencesStore.shared.prefs.watchedFolders.firstIndex(where: { $0.id == folder.id }) {
                        PreferencesStore.shared.prefs.watchedFolders[i].processedCount += 1
                        PreferencesStore.shared.prefs.watchedFolders[i].lastRun = Date()
                    }
                    if !r.outputs.isEmpty, PreferencesStore.shared.prefs.notifyWhenDone, !NSApp.isActive {
                        Notifier.post(title: "Dossier surveillé · \(URL(fileURLWithPath: folder.path).lastPathComponent)",
                                      body: "\(url.lastPathComponent) → \(r.outputs[0].lastPathComponent) (\(r.outputSize.formattedBytes))")
                    }
                }
            } catch {
                NSLog("Forma watched folder: \(path): \(error.localizedDescription)")
            }
        }
    }
}

/// Simple async semaphore.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = n }
    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let r = await body()
        release()
        return r
    }
    private func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

// MARK: - Scheduled batches

@MainActor
final class Scheduler {
    static let shared = Scheduler()
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        tick()
    }

    func schedule(paths: [URL], mode: ProcessMode, at date: Date) {
        let job = ScheduledJob(paths: paths.map(\.path), mode: mode, date: date, snapshot: PreferencesStore.shared.prefs.processing)
        PreferencesStore.shared.prefs.scheduledJobs.append(job)
    }

    func cancel(_ id: UUID) { PreferencesStore.shared.prefs.scheduledJobs.removeAll { $0.id == id } }

    private func tick() {
        let model = AppModel.shared
        guard !model.isRunning else { return }
        let now = Date()
        guard let job = PreferencesStore.shared.prefs.scheduledJobs.sorted(by: { $0.date < $1.date }).first(where: { $0.date <= now }) else { return }
        cancel(job.id)
        let urls = job.paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            Notifier.post(title: "Tâche planifiée", body: "Les fichiers planifiés ne sont plus disponibles.")
            return
        }
        model.add(urls, mode: job.mode, autoStart: false)
        model.start(mode: job.mode, snapshot: job.snapshot, origin: .schedule)
    }
}
