import Foundation

/// One file of a planned job.
struct PlannedFile: Sendable, Hashable {
    var url: URL
    var kind: MediaKind
    var target: FormatDescriptor?       // nil = snapshot default for the kind
    var outputFolder: URL?
}

/// A request resolved against the preferences: files, formats, settings. Pure and nonisolated, so the app
/// (`JobCenter`), the CLI (`forma run`) and Shortcuts share the exact same behaviour.
struct JobPlan: Sendable {
    var mode: ProcessMode
    var snapshot: ProcessingSnapshot
    var files: [PlannedFile]
    var ignored: Int
    var title: String
    var copyToClipboard: Bool
    var reveal: Bool
    var origin: HistoryOrigin
    var recipeName: String?
    /// Send the results to Drop (nil = no upload).
    var drop: DropOptions?
    /// `.upload` requests: files (or folders, zipped) sent as they are, without processing.
    var uploads: [URL] = []
}

enum RequestPlanner {
    enum PlanError: LocalizedError {
        case unknownRecipe
        case unknownFormat(String)
        case dropUnavailable
        case untrusted
        var errorDescription: String? {
            switch self {
            case .dropUnavailable: DropError.notConfigured.localizedDescription
            case .untrusted: "Un lien forma:// ne peut pas envoyer de fichiers sur Drop."
            case .unknownRecipe: "Cette recette n'existe plus."
            case .unknownFormat(let f): "Format inconnu : \(f)."
            }
        }
    }

    /// Expands folders (disk I/O: call off the main thread for big folders).
    /// `trusted` is false for `forma://convert?…` URLs, which any web page can open: they can never touch originals.
    static func plan(_ r: ExternalRequest, prefs: Preferences, trusted: Bool = true) throws -> JobPlan {
        if r.action == .upload { return try planUpload(r, prefs: prefs, trusted: trusted) }
        var snap = prefs.processing
        var mode = r.mode
        var recipe: Recipe?
        if r.action == .recipe {
            guard let id = r.recipe, let found = prefs.recipes.first(where: { $0.id == id }) else { throw PlanError.unknownRecipe }
            recipe = found
            mode = found.mode
            apply(found.overrides, to: &snap, mode: mode)
        }
        if let o = r.overrides { apply(o, to: &snap, mode: mode) }
        var fixedTarget: FormatDescriptor?
        if let t = r.target {
            guard let f = FormatCatalog.format(t) ?? FormatCatalog.resolve(t) else { throw PlanError.unknownFormat(t) }
            fixedTarget = f
        }

        // Destination: request, then recipe, then the Finder settings for anything started outside the window.
        let external: Set<RequestSource> = [.finder, .share, .service, .url, .cli]
        let destination = r.destination ?? (recipe?.destination != .standard ? recipe?.destination : nil)
            ?? (external.contains(r.source) ? prefs.finder.destination : .standard)
        var folder: URL?
        switch destination {
        case .standard: break
        case .alongside, .clipboard: snap.output.destination = .alongside
        case .folder(let p): folder = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        if !trusted {
            snap.output.replaceOriginals = false
            snap.output.deleteOriginals = false
            if snap.output.conflict == .overwrite { snap.output.conflict = .rename }
        }

        // Files
        let urls = r.paths.map { URL(fileURLWithPath: $0) }
        let expanded = Pipeline.expand(urls, recursive: r.recursive ?? true)
        let staged = r.stagedDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path + "/" }
        let sharesFolder = prefs.finder.sharesFolderURL
        var files: [PlannedFile] = []
        var ignored = 0
        var seen = Set<String>()
        for url in expanded where seen.insert(url.path).inserted {
            guard let kind = FileDetection.classify(url).mediaKind else { ignored += 1; continue }
            if let kinds = r.kinds, !kinds.contains(kind) { ignored += 1; continue }
            if mode == .upscale && kind != .image { ignored += 1; continue }
            var target: FormatDescriptor?
            if let recipe, mode == .convert {
                if recipe.targets.isEmpty { target = nil }
                else if let t = recipe.target(for: kind) { target = t }
                else { ignored += 1; continue }
            } else if let recipe, mode == .upscale {
                target = recipe.target(for: .image)
            }
            if let f = fixedTarget {
                guard mode != .convert || FormatCatalog.canConvert(kind, to: f) else { ignored += 1; continue }
                target = f
            }
            var out = folder
            // Copies staged by the Share extension are deleted after the job: never write next to them.
            if let staged, url.standardizedFileURL.path.hasPrefix(staged) { out = folder ?? sharesFolder }
            files.append(PlannedFile(url: url, kind: kind, target: target, outputFolder: out))
        }
        if staged != nil || files.contains(where: { $0.outputFolder == sharesFolder }) { snap.output.replaceOriginals = false; snap.output.deleteOriginals = false }

        let title = recipe.map { "Recette « \($0.name) »" } ?? Self.title(mode: mode, target: fixedTarget, preset: r.overrides?.preset)
        // Public `forma://` links never reach Drop: any web page can open them.
        let dropOptions = trusted ? (r.drop ?? recipe?.drop) : nil
        if dropOptions != nil, !DropServer.isConfigured(prefs.drop) { throw PlanError.dropUnavailable }
        let linkReplacesFiles = dropOptions.map { $0.copyLink ?? prefs.drop.copyLink } ?? false
        return JobPlan(mode: mode, snapshot: snap, files: files, ignored: ignored, title: dropOptions == nil ? title : title + " → Drop",
                       copyToClipboard: destination == .clipboard && !linkReplacesFiles,
                       reveal: r.reveal ?? (external.contains(r.source) ? prefs.finder.revealWhenDone : prefs.processing.output.revealWhenDone),
                       origin: origin(of: r.source), recipeName: recipe?.name, drop: dropOptions)
    }

    static func origin(of source: RequestSource) -> HistoryOrigin {
        switch source {
        case .finder: .finder
        case .share: .share
        case .service: .service
        case .url: .url
        case .cli: .cli
        case .menuBar: .menuBar
        case .shortcut: .shortcut
        }
    }

    /// Files are sent untouched; folders (and packages) become one zip each. No file type is refused.
    private static func planUpload(_ r: ExternalRequest, prefs: Preferences, trusted: Bool) throws -> JobPlan {
        guard trusted else { throw PlanError.untrusted }
        guard DropServer.isConfigured(prefs.drop) else { throw PlanError.dropUnavailable }
        var seen = Set<String>()
        var uploads: [URL] = []
        var ignored = 0
        for p in r.paths {
            let url = URL(fileURLWithPath: p)
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: url.path), !url.lastPathComponent.hasPrefix(".") else { ignored += 1; continue }
            uploads.append(url)
        }
        let title = uploads.count == 1 ? "Envoi de « \(uploads[0].lastPathComponent) »" : "Envoi sur Drop"
        return JobPlan(mode: .convert, snapshot: prefs.processing, files: [], ignored: ignored, title: title, copyToClipboard: false,
                       reveal: false, origin: origin(of: r.source), recipeName: nil, drop: r.drop ?? DropOptions(), uploads: uploads)
    }

    static func title(mode: ProcessMode, target: FormatDescriptor?, preset: CompressionPreset? = nil) -> String {
        switch mode {
        case .convert: target.map { "Conversion en \($0.name)" } ?? "Conversion"
        case .compress: preset.map { "Compression · \($0.label)" } ?? "Compression"
        case .upscale: "Agrandissement ×2"
        }
    }

    /// Settings a request or a recipe changes on top of the preferences.
    static func apply(_ o: RequestOverrides, to s: inout ProcessingSnapshot, mode: ProcessMode) {
        if let p = o.preset { s.image.preset = p }
        if let q = o.quality {
            s.image.preset = .custom; s.image.customQuality = q
            s.video.preset = .custom; s.video.quality = q
            if mode == .convert { s.compressWhileConverting = true }
        }
        if let d = o.maxDimension {
            s.image.resizeMode = .fit; s.image.width = d; s.image.height = d; s.image.upscale = false
        }
        if let k = o.targetSizeKB { s.image.targetFileSizeKB = k }
        if let m = o.metadata { s.image.metadata = m }
        if let c = o.compressWhileConverting { s.compressWhileConverting = c }
        if let r = o.replaceOriginals { s.output.replaceOriginals = r }
        if let w = o.watermark { s.image.watermark.enabled = w && s.image.watermark.imagePath != nil }
    }
}

extension FormatCatalog {
    /// Whether a file of `kind` can be converted to `f` (an image format chosen for a mixed batch is not applied to audio).
    static func canConvert(_ kind: MediaKind, to f: FormatDescriptor) -> Bool {
        switch kind {
        case .image: return f.kind == .image
        case .document: return f.kind == .image || pdfTextOutputs.contains(f.id) || f.id == "PDFDOC"
        case .video:
            if f.kind == .video || f.kind == .audio { return true }
            if f.kind == .image, case .animated = f.writer { return true }
            return false
        case .audio: return f.kind == .audio
        case .office: return officeEquivalent(of: f) != nil
        }
    }
}
