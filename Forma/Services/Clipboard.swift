import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Engine (shared by the watcher, `forma optimize` and Copia)

enum ClipboardEngine {
    struct Outcome: Sendable {
        enum Status: String, Sendable { case optimized, noGain = "no-gain", skipped }
        var status: Status
        var reason: String?
        var input: URL
        var output: URL?
        var before: Int64
        var after: Int64
        var format: FormatDescriptor?
        var rule: String
        var width = 0
        var height = 0
        var savingsPercent: Int { before > 0 && after > 0 ? Int(((1 - Double(after) / Double(before)) * 100).rounded()) : 0 }
    }

    static var directory: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Forma/Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Removes optimized clipboard files older than the retention period.
    static func cleanup(retentionDays: Int) {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-Double(max(1, retentionDays)) * 86_400)
        let dir = directory
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if d < limit || u.lastPathComponent.hasPrefix(".incoming-") { try? fm.removeItem(at: u) }
        }
    }

    /// Optimizes one image file with the clipboard rules. `force` ignores the global minimum size
    /// (explicit requests), but a rule that says "don't touch" is always respected.
    static func optimize(file input: URL, sourceApp: String?, settings s: ClipboardSettings, force: Bool,
                         outputDir: URL? = nil, baseName: String? = nil) async throws -> Outcome {
        let before = input.fileSize
        guard let a = ClipboardRules.analyze(input) else { throw ToolError("Image illisible.") }
        let match = ClipboardRules.match(s, sourceApp: sourceApp, isPhoto: a.isPhoto, bytes: before)
        var outcome = Outcome(status: .skipped, input: input, before: before, after: before, rule: match.ruleName, width: a.width, height: a.height)
        if !force && before < Int64(s.minSizeKB) * 1024 {
            outcome.reason = "Image légère (< \(s.minSizeKB) Ko)"
            return outcome
        }
        let act = match.action
        if act.skip {
            outcome.reason = "Règle « \(match.ruleName) » : ne pas toucher"
            return outcome
        }

        // Output format
        let format: FormatDescriptor
        switch act.format {
        case "AUTO": format = FormatCatalog.format(a.isPhoto && !a.hasAlpha ? "JPEG" : "PNG")!
        case "SAME": format = FileDetection.sameFormat(for: input) ?? FormatCatalog.format("PNG")!
        default: format = FormatCatalog.format(act.format) ?? FormatCatalog.format("WEBP")!
        }

        var img = ImageSettings()
        img.preset = .custom
        img.customQuality = act.quality
        img.metadata = act.stripMetadata ? .stripAll : .keepEssential
        img.lossyPNG = act.lossyPNG
        img.animatedFrames = false
        let longest = max(a.width, a.height)
        var target = longest
        if act.retinaToStandard && a.dpi >= 143 { target = longest / 2 }
        if let m = act.maxDimension { target = min(target, m) }
        if target < longest { img.resizeMode = .fit; img.width = target; img.height = target } else { img.resizeMode = .none }

        let dir = outputDir ?? directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let job = ImageEngine.Job(input: input, inputClass: FileDetection.classify(input), format: format, settings: img,
                                  mode: .compress, compress: true, near: dir)
        guard let produced = try await ImageEngine.process(job, progress: { _ in }).first else { throw ToolError("L'optimisation a échoué.") }
        let after = produced.url.fileSize
        let gain = before > 0 ? 1 - Double(after) / Double(before) : 0
        if after <= 0 || after >= before || gain * 100 < Double(s.minGainPercent) {
            try? FileManager.default.removeItem(at: produced.url)
            outcome.status = .noGain
            outcome.after = after
            outcome.reason = after >= before ? "Déjà optimisée" : "Gain trop faible (\(Int((gain * 100).rounded())) %)"
            outcome.format = format
            return outcome
        }
        let base = baseName ?? input.deletingPathExtension().lastPathComponent
        var out = dir.appendingPathComponent("\(base) (optimisée)").appendingPathExtension(format.ext)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent("\(base) (optimisée \(n))").appendingPathExtension(format.ext); n += 1
        }
        try FileManager.default.moveItem(at: produced.url, to: out)
        outcome.status = .optimized
        outcome.output = out
        outcome.after = after
        outcome.format = format
        if target < longest { outcome.width = a.width * target / longest; outcome.height = a.height * target / longest }
        return outcome
    }
}

// MARK: - Watcher

struct ClipboardLogEntry: Identifiable, Sendable {
    let id = UUID()
    var date = Date()
    var app: String
    var rule: String
    var status: ClipboardEngine.Outcome.Status
    var reason: String?
    var before: Int64
    var after: Int64
    var format: String?
}

/// Watches the clipboard and optimizes copied images according to the user's rules.
@MainActor
@Observable
final class ClipboardOptimizer {
    static let shared = ClipboardOptimizer()
    static let marker = NSPasteboard.PasteboardType("com.thibault.forma.optimized")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    private(set) var busy = false
    /// Last decisions, shown in Settings so rules are easy to debug.
    private(set) var log: [ClipboardLogEntry] = []

    private var settings: ClipboardSettings { PreferencesStore.shared.prefs.clipboard }

    func apply() {
        let s = settings
        if s.enabled && s.trigger == .automatic { start() } else { stop() }
        let days = s.fileRetentionDays
        DispatchQueue.global(qos: .utility).async { ClipboardEngine.cleanup(retentionDays: days) }
    }

    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { ClipboardOptimizer.shared.poll() } }
        timer?.tolerance = 0.2
    }

    func stop() { timer?.invalidate(); timer = nil }

    func pause(for interval: TimeInterval?) {
        PreferencesStore.shared.prefs.clipboard.pausedUntil = interval.map { Date().addingTimeInterval($0) }
        if let interval { Toast.show("Optimiseur en pause \(interval >= 3600 ? "\(Int(interval / 3600)) h" : "\(Int(interval / 60)) min")", symbol: "pause.circle") }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard !settings.isPaused else { return }
        handle(force: false)
    }

    /// ⌥⌘V / menu: optimize the current clipboard image now, whatever the trigger setting.
    func optimizeNow() {
        lastChange = NSPasteboard.general.changeCount
        handle(force: true)
    }

    private func handle(force: Bool) {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        guard !busy else { return }
        if types.contains(Self.marker) || types.contains(.init(ClipboardRules.stampType)) {
            if force { Toast.show("Déjà optimisée par Forma", symbol: "checkmark.seal") }
            return
        }
        // Passwords, transient data, Finder files.
        if types.contains(.init("org.nspasteboard.ConcealedType")) || types.contains(.init("org.nspasteboard.TransientType")) { return }
        if types.contains(.fileURL) { if force { Toast.show("Le presse-papiers contient des fichiers, pas une image", symbol: "doc") }; return }
        let markerSource = pb.string(forType: Self.sourceType)
        if !force, settings.ignoreClipboardManagers, let m = markerSource, ClipboardSettings.clipboardManagers.contains(m) { return }
        let candidates: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.init("public.jpeg"), "jpg"), (.init("public.heic"), "heic"), (.tiff, "tiff")]
        guard let (type, ext) = candidates.first(where: { types.contains($0.0) }), let data = pb.data(forType: type) else {
            if force { Toast.show("Aucune image dans le presse-papiers", symbol: "photo.badge.exclamationmark") }
            return
        }
        // Same representation Copia hashes, so it can find (and update) the original clip.
        let copiaHash = ClipboardRules.copiaImageTypes.lazy.compactMap { pb.data(forType: .init($0)) }.first.map(ClipboardRules.copiaHash)
        let front = NSWorkspace.shared.frontmostApplication
        let source = (markerSource?.isEmpty == false ? markerSource : nil) ?? front?.bundleIdentifier
        let appName = source.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? front?.localizedName ?? "?"
        let count = pb.changeCount
        Task { await optimize(data, ext: ext, source: source, appName: appName, copiaHash: copiaHash, force: force, changeCount: count) }
    }

    private func optimize(_ data: Data, ext: String, source: String?, appName: String, copiaHash: String?, force: Bool, changeCount: Int) async {
        busy = true
        defer { busy = false }
        let s = settings
        let dir = ClipboardEngine.directory
        let stamp = Self.stampFormatter.string(from: Date())
        let input = dir.appendingPathComponent(".incoming-\(UUID().uuidString)").appendingPathExtension(ext == "tiff" ? "png" : ext)
        defer { try? FileManager.default.removeItem(at: input) }
        do {
            if ext == "tiff" { // screenshots arrive as TIFF: store as PNG first
                guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
                try png.write(to: input)
            } else { try data.write(to: input) }
            let originalBytes = Int64(data.count)

            let o = try await ClipboardEngine.optimize(file: input, sourceApp: source, settings: s, force: force, baseName: "Image \(stamp)")
            record(ClipboardLogEntry(app: appName, rule: o.rule, status: o.status, reason: o.reason, before: originalBytes, after: o.after, format: o.format?.name))
            guard o.status == .optimized, let out = o.output, let format = o.format else {
                if force { Toast.show(o.reason ?? "Rien à optimiser", symbol: "checkmark.seal") }
                return
            }
            // The clipboard changed while we were working: never overwrite a newer copy.
            guard NSPasteboard.general.changeCount == changeCount else { return }
            let saved = Int(((1 - Double(o.after) / Double(max(1, originalBytes))) * 100).rounded())
            let meta = ClipboardStamp(originalHash: copiaHash, originalBytes: originalBytes, bytes: o.after, format: format.name, ext: format.ext,
                                      rule: o.rule, savingsPercent: saved, sourceApp: source, file: out.path)
            write(out, format: format, stamp: meta, output: s.output)
            if s.showToast { Toast.show("Presse-papiers optimisé · \(format.name) · \(o.after.formattedBytes) (−\(saved) %)", symbol: "sparkles") }
            if s.playSound { NSSound(named: "Tink")?.play() }
            ClipboardEngine.cleanup(retentionDays: s.fileRetentionDays)
        } catch {
            record(ClipboardLogEntry(app: appName, rule: "—", status: .skipped, reason: error.localizedDescription, before: Int64(data.count), after: 0))
            if force { Toast.show("Échec de l'optimisation : \(error.localizedDescription)", symbol: "exclamationmark.triangle") }
        }
    }

    private func write(_ out: URL, format: FormatDescriptor, stamp: ClipboardStamp, output: ClipboardOutput) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if output != .imageOnly { item.setString(out.absoluteString, forType: .fileURL) }
        if output != .fileOnly, let d = try? Data(contentsOf: out), let ut = UTType(filenameExtension: format.ext) {
            item.setData(d, forType: NSPasteboard.PasteboardType(ut.identifier))
            if format.id == "PNG" { item.setData(d, forType: .png) }
        }
        if let json = try? JSONEncoder().encode(stamp) { item.setData(json, forType: .init(ClipboardRules.stampType)) }
        item.setString("com.thibault.forma", forType: Self.sourceType)
        item.setData(Data(), forType: Self.marker)
        pb.writeObjects([item])
        lastChange = pb.changeCount
    }

    private func record(_ e: ClipboardLogEntry) {
        log.insert(e, at: 0)
        if log.count > 30 { log.removeLast(log.count - 30) }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        return f
    }()
}

// MARK: - Toast HUD

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String) {
        hideWork?.cancel()
        let host = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        host.frame.size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return p
        }()
        panel = p
        p.contentView = host
        if let screen = NSScreen.main {
            let size = host.fittingSize
            p.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24,
                              width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.tint)
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
        .padding(8)
    }
}
