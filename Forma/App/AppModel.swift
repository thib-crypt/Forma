import Foundation
import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ItemStatus: Equatable {
    case pending
    case processing(Double)
    case done
    case failed(String)
    case skipped(String)
    case cancelled

    var isFinished: Bool {
        switch self { case .done, .failed, .skipped, .cancelled: true; default: false }
    }
}

@MainActor
@Observable
final class FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let inputClass: InputClass
    let kind: MediaKind
    let size: Int64
    var status: ItemStatus = .pending
    var outputs: [URL] = []
    var outputSize: Int64 = 0
    var note: String?
    var resolutionBadge: String?       // upscale mode: "3000 × 2000" instead of a size delta
    var targetOverride: String?        // per-file output format
    var thumbnail: NSImage?
    var startedAt: Date?
    var finishedAt: Date?
    var historyID: UUID?               // history entry of the last successful run (for undo)
    var dropLinks: [String] = []       // links on Drop (sent after processing, or by hand)
    var isSendingToDrop = false

    init(url: URL) {
        self.url = url
        inputClass = FileDetection.classify(url)
        kind = inputClass.mediaKind ?? .image
        size = url.fileSize
    }

    var name: String { url.lastPathComponent }
    var inputExt: String { url.pathExtension.uppercased() }
    var savings: Double? {
        guard status == .done, size > 0, outputSize > 0 else { return nil }
        return 1 - Double(outputSize) / Double(size)
    }
    var progress: Double {
        switch status {
        case .processing(let p): p
        case .done, .failed, .skipped, .cancelled: 1
        case .pending: 0
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var mode: ProcessMode {
        didSet { PreferencesStore.shared.prefs.lastMode = mode }
    }
    var convertItems: [FileItem] = []
    var compressItems: [FileItem] = []
    var upscaleItems: [FileItem] = []
    var isRunning = false
    var isPaused = false
    var runningMode: ProcessMode?
    var selection = Set<FileItem.ID>()
    var lastBatchSummary: String?
    var lastBatchID: UUID?

    private var runTask: Task<Void, Never>?
    private var pauseContinuations: [CheckedContinuation<Void, Never>] = []

    private init() {
        mode = PreferencesStore.shared.prefs.lastMode
    }

    var prefs: Preferences {
        get { PreferencesStore.shared.prefs }
        set { PreferencesStore.shared.prefs = newValue }
    }

    func items(for mode: ProcessMode) -> [FileItem] {
        switch mode {
        case .convert: convertItems
        case .compress: compressItems
        case .upscale: upscaleItems
        }
    }
    var items: [FileItem] { items(for: mode) }

    private func setItems(_ list: [FileItem], for mode: ProcessMode) {
        switch mode {
        case .convert: convertItems = list
        case .compress: compressItems = list
        case .upscale: upscaleItems = list
        }
    }

    // MARK: Adding

    @discardableResult
    func add(_ urls: [URL], mode: ProcessMode? = nil, autoStart: Bool? = nil) -> Int {
        let m = mode ?? self.mode
        if let mode { self.mode = mode }
        let existing = Set(items(for: m).map(\.url))
        let files = Pipeline.expand(urls).filter {
            !existing.contains($0) && (m != .upscale || FileDetection.classify($0).mediaKind == .image)
        }
        guard !files.isEmpty else { return 0 }
        let new = files.map(FileItem.init)
        setItems(items(for: m) + new, for: m)
        new.forEach(loadThumbnail)
        let shouldStart = autoStart ?? (m != .convert && prefs.autoStartOnDrop)
        if shouldStart { start(mode: m) }
        return new.count
    }

    private func loadThumbnail(_ item: FileItem) {
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: [.thumbnail, .icon])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            Task { @MainActor in item.thumbnail = img }
        }
    }

    // MARK: Queue control

    func start(mode: ProcessMode? = nil, snapshot: ProcessingSnapshot? = nil, origin: HistoryOrigin = .app) {
        let m = mode ?? self.mode
        guard !isRunning else { return }
        let pending = items(for: m).filter { $0.status == .pending || $0.status == .cancelled }
        guard !pending.isEmpty else { return }
        pending.forEach { $0.status = .pending }
        isRunning = true
        isPaused = false
        runningMode = m
        lastBatchSummary = nil
        let snap = snapshot ?? prefs.processing
        let batch = UUID()
        lastBatchID = batch
        // Upscaling is bound by the Neural Engine (one tile at a time): 2 lanes overlap decode/encode with inference.
        let imageWidth = m == .upscale ? 2 : SystemInfo.imageParallelism(requested: prefs.maxParallelImages)
        let mediaWidth = max(1, prefs.maxParallelVideos)

        runTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let images = pending.filter { $0.kind == .image || $0.kind == .document || $0.kind == .office }
            let media = pending.filter { $0.kind == .video || $0.kind == .audio }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.lane(images, width: imageWidth, mode: m, snapshot: snap, origin: origin, batch: batch) }
                group.addTask { await self.lane(media, width: mediaWidth, mode: m, snapshot: snap, origin: origin, batch: batch) }
            }
            for t in self.dropTasks { await t.value }
            self.dropTasks.removeAll()
            self.finishBatch(pending, mode: m, elapsed: Date().timeIntervalSince(started))
        }
    }

    private func lane(_ items: [FileItem], width: Int, mode: ProcessMode, snapshot: ProcessingSnapshot,
                      origin: HistoryOrigin, batch: UUID) async {
        guard !items.isEmpty else { return }
        var iterator = items.enumerated().makeIterator()
        await withTaskGroup(of: Void.self) { group in
            func enqueueNext() async -> Bool {
                await self.waitIfPaused()
                guard !Task.isCancelled, let (i, item) = iterator.next() else { return false }
                group.addTask { await self.process(item, index: i + 1, mode: mode, snapshot: snapshot, origin: origin, batch: batch) }
                return true
            }
            for _ in 0..<width { if !(await enqueueNext()) { break } }
            while await group.next() != nil {
                _ = await enqueueNext()
            }
        }
    }

    private func process(_ item: FileItem, index: Int, mode: ProcessMode, snapshot: ProcessingSnapshot,
                         origin: HistoryOrigin, batch: UUID) async {
        if Task.isCancelled { item.status = .cancelled; return }
        item.status = .processing(0.02)
        item.startedAt = Date()
        let url = item.url
        let override = item.targetOverride.flatMap(FormatCatalog.format)
        let throttle = ProgressThrottle()
        do {
            // Shared slots with JobCenter: a Finder job and this batch never double the load.
            let result = try await WorkLimits.run(item.kind) {
                try await Pipeline.run(input: url, mode: mode, snapshot: snapshot, index: index, targetOverride: override,
                                       origin: origin, batch: batch) { p in
                    guard throttle.shouldEmit(p) else { return }
                    Task { @MainActor in if case .processing = item.status { item.status = .processing(max(0.02, p)) } }
                }
            }.get()
            item.outputs = result.outputs
            item.outputSize = result.outputSize
            item.note = result.note
            item.historyID = result.historyID
            if mode == .upscale, let out = result.outputs.first { item.resolutionBadge = Self.pixelSize(of: out) }
            item.status = result.skipped ? .skipped(result.note ?? "Ignoré") : .done
            if prefs.drop.afterProcessing, !result.outputs.isEmpty, DropServer.isConfigured(prefs.drop) {
                dropTasks.append(Task { await self.sendToDrop(item, urls: result.outputs, origin: origin, batch: batch, entry: result.historyID) })
            }
        } catch is CancellationError {
            item.status = .cancelled
        } catch {
            item.status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
        item.finishedAt = Date()
    }

    // MARK: Drop

    @ObservationIgnored private var dropTasks: [Task<Void, Never>] = []

    /// Sends files to Drop and attaches the links to the row. The link is copied by the caller (batch end or single send).
    @discardableResult
    func sendToDrop(_ item: FileItem, urls: [URL], origin: HistoryOrigin = .app, batch: UUID? = nil, entry: UUID? = nil,
                    copyWhenDone: Bool = false) async -> [String] {
        let drop = prefs.drop
        item.isSendingToDrop = true
        defer { item.isSendingToDrop = false }
        var links: [String] = []
        for url in urls {
            do {
                let up = try await WorkLimits.uploads.run { () async -> Result<DropUpload, Error> in
                    do { return .success(try await DropUploader.upload(url, prefs: drop, origin: origin, batch: batch, entry: entry)) }
                    catch { return .failure(error) }
                }.get()
                links.append(up.url)
            } catch {
                Toast.show("Drop : \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
        item.dropLinks += links
        if copyWhenDone, !links.isEmpty {
            DropUploader.copy(links)
            Toast.show(links.count == 1 ? "Lien Drop copié" : "\(links.count) liens Drop copiés", symbol: "link")
        }
        return links
    }

    private func finishBatch(_ batch: [FileItem], mode: ProcessMode, elapsed: TimeInterval) {
        isRunning = false
        isPaused = false
        runningMode = nil
        runTask = nil
        let done = batch.filter { $0.status == .done }
        let failed = batch.filter { if case .failed = $0.status { true } else { false } }
        let before = done.reduce(Int64(0)) { $0 + $1.size }
        let after = done.reduce(Int64(0)) { $0 + ($1.outputs.isEmpty ? $1.size : $1.outputSize) }
        var summary = "\(done.count) fichier\(done.count > 1 ? "s" : "") traité\(done.count > 1 ? "s" : "") en \(Self.format(elapsed))"
        if before > after { summary += " · \((before - after).formattedBytes) économisés" }
        if !failed.isEmpty { summary += " · \(failed.count) échec\(failed.count > 1 ? "s" : "")" }
        lastBatchSummary = summary
        guard !done.isEmpty || !failed.isEmpty else { return }

        let outputs = done.flatMap(\.outputs)
        let links = done.flatMap(\.dropLinks)
        if !links.isEmpty {
            summary += " · \(links.count) lien\(links.count > 1 ? "s" : "") Drop"
            lastBatchSummary = summary
            if prefs.drop.copyLink { DropUploader.copy(links) }
        }
        if prefs.autoCopyResult, !outputs.isEmpty, links.isEmpty || !prefs.drop.copyLink {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(outputs as [NSURL])
        }
        if prefs.processing.output.revealWhenDone, !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if prefs.notifyWhenDone, !NSApp.isActive {
            Notifier.post(title: mode.doneLabel, body: summary)
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    nonisolated static func pixelSize(of url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h)"
    }

    static func format(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1f s", t) : String(format: "%d min %02d s", Int(t) / 60, Int(t) % 60)
    }

    func pause() { isPaused = true }

    func resume() {
        isPaused = false
        let c = pauseContinuations
        pauseContinuations.removeAll()
        c.forEach { $0.resume() }
    }

    private func waitIfPaused() async {
        guard isPaused else { return }
        await withCheckedContinuation { pauseContinuations.append($0) }
    }

    func cancel() {
        runTask?.cancel()
        resume()
    }

    // MARK: List management

    func remove(_ ids: Set<FileItem.ID>) {
        setItems(items.filter { !ids.contains($0.id) || $0.status.isProcessing }, for: mode)
        selection.subtract(ids)
    }

    func clearFinished() {
        setItems(items.filter { !$0.status.isFinished }, for: mode)
    }

    func removeAll() {
        guard !isRunning || runningMode != mode else { return }
        setItems([], for: mode)
        selection.removeAll()
    }

    func reset(_ item: FileItem) {
        item.status = .pending
        item.outputs = []
        item.outputSize = 0
        item.note = nil
        item.resolutionBadge = nil
        item.historyID = nil
        item.dropLinks = []
    }

    /// Called after history entries were undone: matching rows go back to "pending" so they can be re-tuned and rerun.
    func didUndo(_ ids: Set<UUID>) {
        for list in [convertItems, compressItems, upscaleItems] {
            for item in list where item.historyID.map(ids.contains) == true { reset(item) }
        }
        lastBatchSummary = nil
    }

    func retryFailed() {
        for i in items where { if case .failed = i.status { true } else { false } }() { reset(i) }
        start()
    }

    func resetAndRun() {
        items.forEach(reset)
        start()
    }

    var pendingCount: Int { items.filter { $0.status == .pending }.count }
    var doneCount: Int { items.filter { $0.status.isFinished }.count }
    var overallProgress: Double {
        let list = runningMode.map(items(for:)) ?? items
        guard !list.isEmpty else { return 0 }
        return list.reduce(0) { $0 + $1.progress } / Double(list.count)
    }
    var totalSaved: Int64 {
        items.filter { $0.status == .done && !$0.outputs.isEmpty }.reduce(Int64(0)) { $0 + max(0, $1.size - $1.outputSize) }
    }
}

extension ItemStatus {
    var isProcessing: Bool { if case .processing = self { true } else { false } }
}

/// Limits progress callbacks to ~15/s per file so a 4K encode never floods the main thread.
final class ProgressThrottle: @unchecked Sendable {
    private var last = Date.distantPast
    private var lastValue = -1.0
    private let lock = NSLock()
    func shouldEmit(_ v: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) > 0.066 || v >= 0.99 || abs(v - lastValue) > 0.1 else { return false }
        last = now; lastValue = v
        return true
    }
}
