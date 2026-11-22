import Foundation
import AppKit

/// Shared slots so a Finder job and a batch in the main window never double the load on the Mac.
enum WorkLimits {
    static let images = AsyncLimiter(SystemInfo.imageParallelism(requested: PreferencesStore.loadSnapshot().maxParallelImages))
    static let media = AsyncLimiter(max(1, PreferencesStore.loadSnapshot().maxParallelVideos))

    /// Uploads to Drop: two at a time, independent of the CPU lanes (the network is the bottleneck).
    static let uploads = AsyncLimiter(2)

    static func limiter(for kind: MediaKind) -> AsyncLimiter { kind == .video || kind == .audio ? media : images }

    /// Runs one pipeline call inside a slot of the right lane.
    static func run(_ kind: MediaKind, _ body: @escaping @Sendable () async throws -> PipelineResult) async -> Result<PipelineResult, Error> {
        await limiter(for: kind).run {
            if Task.isCancelled { return .failure(CancellationError()) }
            do { return .success(try await body()) } catch { return .failure(error) }
        }
    }
}

struct JobFailure: Identifiable, Sendable {
    let id = UUID()
    var url: URL
    var message: String
}

/// A request being processed by `JobCenter` (Finder, Share, Services, menu bar drops, `forma://`).
@MainActor
@Observable
final class BackgroundJob: Identifiable {
    enum State: Equatable { case queued, preparing, running, finished, cancelled }

    let id: UUID
    let request: ExternalRequest
    var title: String
    var mode: ProcessMode
    var state: State = .queued
    var total = 0
    var completed = 0
    var unchanged = 0
    var ignored = 0
    var failures: [JobFailure] = []
    var outputs: [URL] = []
    var historyIDs: [UUID] = []
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var running: [URL: Double] = [:]
    var startedAt: Date?
    var finishedAt: Date?
    let batch = UUID()
    var undone = false
    /// false for public `forma://convert?…` links: originals can never be replaced or deleted.
    var trusted = true
    fileprivate var task: Task<Void, Never>?

    // Drop
    var dropOptions: DropOptions?
    /// `.upload` request: nothing is processed, the files are sent as they are.
    var isUploadOnly: Bool { request.action == .upload }
    var uploads: [DropUpload] = []
    var uploading: [URL: Double] = [:]
    /// Uploads started so far (a PDF split into pages produces several files for one input).
    var uploadsStarted = 0
    /// Failures of the upload step; they are also in `failures`.
    var uploadFailureCount = 0
    var linksCopied = false
    var linksDeleted = false
    fileprivate var uploadTasks: [Task<Void, Never>] = []
    var links: [String] { uploads.map(\.url) }
    var sendsToDrop: Bool { dropOptions != nil }

    init(request: ExternalRequest) {
        id = request.id
        self.request = request
        mode = request.mode
        title = request.action == .upload ? "Envoi sur Drop"
            : RequestPlanner.title(mode: request.mode, target: request.target.flatMap(FormatCatalog.format), preset: request.overrides?.preset)
    }

    var isActive: Bool { state == .preparing || state == .running }
    var isDone: Bool { state == .finished || state == .cancelled }
    var processed: Int { completed + unchanged + failures.count - uploadFailureCount }
    var uploadsDone: Int { uploads.count + uploadFailureCount }
    var fraction: Double {
        guard total > 0 else { return state == .finished ? 1 : 0 }
        let process = isUploadOnly ? 1 : min(1, (Double(processed) + running.values.reduce(0, +)) / Double(total))
        guard sendsToDrop else { return process }
        let expected = Double(max(total, uploadsStarted))
        let upload = min(1, (Double(uploadsDone) + uploading.values.reduce(0, +)) / expected)
        return isUploadOnly ? upload : (process + upload) / 2
    }
    var savings: Double? {
        guard mode != .upscale, bytesIn > 0, bytesOut > 0 else { return nil }
        return 1 - Double(bytesOut) / Double(bytesIn)
    }
    var currentNames: String {
        let names = running.keys.map(\.lastPathComponent).sorted()
        if !names.isEmpty { return names.joined(separator: ", ") }
        let sending = uploading.keys.map(\.lastPathComponent).sorted()
        return sending.isEmpty ? "" : "Envoi · " + sending.joined(separator: ", ")
    }
    /// Phase shown in the progress panel.
    var isSending: Bool { running.isEmpty && !uploading.isEmpty }
    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt ?? Date()) }

    /// "12 fichiers · −64 %"
    var summary: String {
        if isUploadOnly {
            if state == .cancelled { return "Annulé · \(uploads.count) sur \(total) envoyé\(uploads.count > 1 ? "s" : "")" }
            if total == 0 { return failures.first?.message ?? "Aucun fichier à envoyer" }
            var s = uploads.isEmpty ? "Aucun fichier envoyé" : "\(uploads.count) fichier\(uploads.count > 1 ? "s" : "") envoyé\(uploads.count > 1 ? "s" : "") sur Drop"
            let bytes = uploads.reduce(Int64(0)) { $0 + $1.size }
            if bytes > 0, !uploads.isEmpty { s += " · \(bytes.formattedBytes)" }
            if !failures.isEmpty { s += " · \(failures.count) échec\(failures.count > 1 ? "s" : "")" }
            return s
        }
        if state == .cancelled { return "Annulé · \(completed) sur \(total) traité\(completed > 1 ? "s" : "")" }
        if total == 0 { return failures.first?.message ?? "Aucun fichier compatible" }
        var s = "\(completed) fichier\(completed > 1 ? "s" : "")"
        if let v = savings, v > 0.005 { s += " · −\(Int((v * 100).rounded())) %" }
        else if mode == .upscale { s += " · ×2" }
        if unchanged > 0 { s += " · \(unchanged) déjà optimisé\(unchanged > 1 ? "s" : "")" }
        if sendsToDrop, !uploads.isEmpty { s += " · \(uploads.count == 1 ? "lien Drop prêt" : "\(uploads.count) liens Drop") " }
        if !failures.isEmpty { s += " · \(failures.count) échec\(failures.count > 1 ? "s" : "")" }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// FIFO queue of background jobs, independent of the main window's lists: a request that arrives while something
/// runs waits its turn and is never lost.
@MainActor
@Observable
final class JobCenter {
    static let shared = JobCenter()

    private(set) var jobs: [BackgroundJob] = []
    /// Called when a job ends (HUD, menu config, quit-when-idle).
    @ObservationIgnored var onFinish: [(BackgroundJob) -> Void] = []

    var active: BackgroundJob? { jobs.first(where: \.isActive) }
    var queued: [BackgroundJob] { jobs.filter { $0.state == .queued } }
    var isBusy: Bool { jobs.contains { !$0.isDone } }
    var lastFinished: BackgroundJob? { jobs.last(where: \.isDone) }
    var overallProgress: Double {
        let open = jobs.filter { !$0.isDone }
        guard !open.isEmpty else { return 0 }
        return open.reduce(0) { $0 + $1.fraction } / Double(open.count)
    }

    @discardableResult
    func submit(_ request: ExternalRequest, trusted: Bool = true) -> BackgroundJob {
        let job = BackgroundJob(request: request)
        job.trusted = trusted
        jobs.append(job)
        trim()
        pump()
        if request.source != .menuBar { ProgressHUD.shared.jobQueued(job) }
        return job
    }

    func cancel(_ job: BackgroundJob) {
        if job.state == .queued {
            job.state = .cancelled
            job.finishedAt = Date()
            finish(job)
        } else {
            job.task?.cancel()
            job.uploadTasks.forEach { $0.cancel() }
        }
    }

    func cancelAll() { jobs.filter { !$0.isDone }.forEach(cancel) }

    /// Undoes everything the job produced (outputs to the Trash, originals put back).
    @discardableResult
    func undo(_ job: BackgroundJob) -> String {
        let entries = HistoryStore.shared.fetch().filter { $0.batch == job.batch && !$0.isUndone }
        // Links without a history entry (plain uploads) are deleted here; the others go with their conversion.
        let plain = HistoryStore.shared.fetchDrops(batch: job.batch).filter { $0.entry == nil }
        guard !entries.isEmpty || !plain.isEmpty else { NSSound.beep(); return "Rien à annuler" }
        var msg = entries.isEmpty ? "" : HistoryModel.shared.undo(entries)
        if !plain.isEmpty {
            let prefs = PreferencesStore.shared.prefs.drop
            Task {
                let failed = await DropUploader.delete(plain, prefs: prefs)
                Toast.show(failed.isEmpty ? "Supprimé de Drop" : "\(failed.count) fichier\(failed.count > 1 ? "s" : "") non supprimé\(failed.count > 1 ? "s" : "") de Drop",
                           symbol: failed.isEmpty ? "trash" : "exclamationmark.triangle")
            }
            msg = msg.isEmpty ? "Suppression de \(plain.count) lien\(plain.count > 1 ? "s" : "") Drop…" : msg
            job.linksDeleted = true
        }
        job.undone = true
        MenuConfigPublisher.shared.setNeedsPublish()
        return msg
    }

    // MARK: Running

    private func pump() {
        guard active == nil, let next = jobs.first(where: { $0.state == .queued }) else { return }
        next.state = .preparing
        next.startedAt = Date()
        let prefs = PreferencesStore.shared.prefs
        let request = next.request
        let trusted = next.trusted
        next.task = Task { [weak self] in
            let planned = await Task.detached(priority: .userInitiated) {
                Result { try RequestPlanner.plan(request, prefs: prefs, trusted: trusted) }
            }.value
            guard let self else { return }
            switch planned {
            case .success(let plan): await self.execute(next, plan: plan)
            case .failure(let e):
                next.failures.append(JobFailure(url: URL(fileURLWithPath: request.paths.first ?? "/"), message: e.localizedDescription))
            }
            next.state = Task.isCancelled ? .cancelled : .finished
            next.finishedAt = Date()
            self.finish(next)
        }
    }

    private func execute(_ job: BackgroundJob, plan: JobPlan) async {
        job.title = plan.title
        job.mode = plan.mode
        job.dropOptions = plan.drop
        job.ignored = plan.ignored
        if job.isUploadOnly {
            job.total = plan.uploads.count
            job.state = .running
            guard !plan.uploads.isEmpty, !Task.isCancelled else { return }
            for url in plan.uploads { startUpload(url, job: job, entry: nil) }
            await finishUploads(job)
            return
        }
        job.total = plan.files.count
        job.state = .running
        guard !plan.files.isEmpty, !Task.isCancelled else { return }
        let prefs = PreferencesStore.shared.prefs
        let imageWidth = plan.mode == .upscale ? 2 : SystemInfo.imageParallelism(requested: prefs.maxParallelImages)
        let mediaWidth = max(1, prefs.maxParallelVideos)
        let images = plan.files.filter { $0.kind != .video && $0.kind != .audio }
        let media = plan.files.filter { $0.kind == .video || $0.kind == .audio }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.lane(images, width: imageWidth, job: job, plan: plan) }
            group.addTask { await self.lane(media, width: mediaWidth, job: job, plan: plan) }
        }
        await finishUploads(job)
        if Task.isCancelled { return }
        if plan.copyToClipboard, !job.outputs.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(job.outputs as [NSURL])
        }
        if plan.reveal, !job.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
    }

    private func lane(_ files: [PlannedFile], width: Int, job: BackgroundJob, plan: JobPlan) async {
        guard !files.isEmpty else { return }
        var iterator = files.enumerated().makeIterator()
        await withTaskGroup(of: Void.self) { group in
            func enqueueNext() -> Bool {
                guard !Task.isCancelled, let (i, f) = iterator.next() else { return false }
                group.addTask { await self.process(f, index: i + 1, job: job, plan: plan) }
                return true
            }
            for _ in 0..<max(1, width) where enqueueNext() {}
            while await group.next() != nil { _ = enqueueNext() }
        }
    }

    private func process(_ file: PlannedFile, index: Int, job: BackgroundJob, plan: JobPlan) async {
        guard !Task.isCancelled else { return }
        let url = file.url
        job.running[url] = 0.02
        let throttle = ProgressThrottle()
        let mode = plan.mode, snapshot = plan.snapshot, origin = plan.origin, batch = job.batch
        let size = url.fileSize
        let result = await WorkLimits.run(file.kind) {
            try await Pipeline.run(input: url, mode: mode, snapshot: snapshot, index: index, targetOverride: file.target,
                                   outputFolder: file.outputFolder, origin: origin, batch: batch) { p in
                guard throttle.shouldEmit(p) else { return }
                Task { @MainActor in if job.running[url] != nil { job.running[url] = max(0.02, p) } }
            }
        }
        job.running[url] = nil
        switch result {
        case .success(let r):
            if r.outputs.isEmpty {
                job.unchanged += 1
            } else {
                job.completed += 1
                job.outputs += r.outputs
                job.bytesIn += size
                job.bytesOut += r.outputSize
            }
            if let h = r.historyID { job.historyIDs.append(h) }
            // Upload as soon as a file is ready: the next conversions keep running meanwhile.
            if job.sendsToDrop { for out in r.outputs { startUpload(out, job: job, entry: r.historyID) } }
        case .failure(let e):
            if e is CancellationError || Task.isCancelled { return }
            job.failures.append(JobFailure(url: url, message: e.localizedDescription))
        }
    }

    // MARK: Drop

    private func startUpload(_ url: URL, job: BackgroundJob, entry: UUID?) {
        guard let options = job.dropOptions, !Task.isCancelled else { return }
        let prefs = PreferencesStore.shared.prefs.drop
        let origin = RequestPlanner.origin(of: job.request.source)
        let batch = job.batch
        job.uploadsStarted += 1
        let task = Task { @MainActor in
            let result: Result<DropUpload, Error> = await WorkLimits.uploads.run {
                if Task.isCancelled { return .failure(CancellationError()) }
                await MainActor.run { job.uploading[url] = 0.02 }
                do {
                    let up = try await DropUploader.upload(url, options: options, prefs: prefs, origin: origin, batch: batch, entry: entry) { p in
                        Task { @MainActor in if job.uploading[url] != nil { job.uploading[url] = max(0.02, p) } }
                    }
                    return .success(up)
                } catch { return .failure(error) }
            }
            job.uploading[url] = nil
            switch result {
            case .success(let up): job.uploads.append(up)
            case .failure(let e):
                if e is CancellationError || Task.isCancelled { return }
                job.uploadFailureCount += 1
                job.failures.append(JobFailure(url: url, message: e.localizedDescription))
            }
        }
        job.uploadTasks.append(task)
    }

    /// Waits for the uploads, then copies the link(s) and opens them if asked.
    private func finishUploads(_ job: BackgroundJob) async {
        for t in job.uploadTasks { await t.value }
        job.uploadTasks.removeAll()
        guard let options = job.dropOptions, !Task.isCancelled else { return }
        job.uploads.sort { $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending }
        let prefs = PreferencesStore.shared.prefs.drop
        if !job.uploads.isEmpty, options.copyLink ?? prefs.copyLink {
            DropUploader.copy(job.links)
            job.linksCopied = true
        }
        if options.openLink ?? prefs.openLink, job.uploads.count == 1, let u = URL(string: job.uploads[0].url) {
            NSWorkspace.shared.open(u)
        }
    }

    private func finish(_ job: BackgroundJob) {
        job.task = nil
        if let staged = job.request.stagedDirectory {
            // Inbox/<id>/files → remove Inbox/<id>
            let dir = URL(fileURLWithPath: staged).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir.lastPathComponent == job.id.uuidString ? dir : URL(fileURLWithPath: staged))
        }
        onFinish.forEach { $0(job) }
        if job.request.source != .menuBar { ProgressHUD.shared.jobFinished(job) }
        let feedback = PreferencesStore.shared.prefs.finder.feedback
        if feedback == .notification, job.state == .finished, job.total > 0 {
            Notifier.post(title: job.title, body: job.summary)
        }
        MenuConfigPublisher.shared.setNeedsPublish()
        pump()
        LaunchContext.quitIfIdle(after: 1)
    }

    /// Keeps the 10 most recent finished jobs.
    private func trim() {
        let done = jobs.filter(\.isDone)
        if done.count > 10 { jobs.removeAll { j in done.prefix(done.count - 10).contains { $0 === j } } }
    }
}
