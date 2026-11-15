import Foundation

struct PipelineResult: Sendable {
    var outputs: [URL]
    var outputSize: Int64
    var note: String?
    var skipped = false
    var historyID: UUID? = nil
}

/// Routes one input file to the right engine, then places the result according to the output settings.
enum Pipeline {

    static func run(input: URL, mode: ProcessMode, snapshot: ProcessingSnapshot, index: Int,
                    targetOverride: FormatDescriptor? = nil, outputFolder: URL? = nil,
                    origin: HistoryOrigin = .app, batch: UUID? = nil,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> PipelineResult {
        let fm = FileManager.default
        let started = Date()
        var trashed: [TrashedFile] = []
        /// Every file Forma removes goes to the Trash and is remembered, so the run can be undone from the history.
        func trash(_ url: URL) throws {
            var resulting: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resulting)
            if let r = resulting as URL? { trashed.append(TrashedFile(original: url.path, trash: r.path)) }
        }
        guard fm.fileExists(atPath: input.path) else { throw ToolError("Le fichier n'existe plus. Il a peut-être été déplacé ou supprimé.") }
        let cls = FileDetection.classify(input)
        guard let kind = cls.mediaKind else { throw ToolError("Ce format n'est pas pris en charge.") }
        if mode == .upscale && kind != .image { throw ToolError("L'agrandissement IA concerne uniquement les images.") }
        guard var format = targetOverride ?? snapshot.target(for: input, kind: kind, mode: mode) else {
            throw ToolError(mode == .compress ? "Compression non prise en charge pour ce format." : "Choisissez un format de sortie.")
        }
        // "pdf" picked for a mixed batch (CLI, Shortcuts, mappings) means a document PDF for a .docx, an image PDF for a PDF.
        if kind == .office, format.kind != .office {
            guard let f = FormatCatalog.officeEquivalent(of: format) else { throw ToolError("Un document ne peut pas être converti en \(format.name).") }
            format = f
        } else if kind == .document, format.id == "PDFDOC", let f = FormatCatalog.format("PDF") {
            format = f
        }
        if mode == .upscale && format.kind != .image { throw ToolError("Choisissez un format d'image en sortie.") }
        let compress = mode == .compress || (mode == .convert && snapshot.compressWhileConverting)
        let near = outputFolder ?? input.deletingLastPathComponent()
        let originalSize = input.fileSize

        // ---- Produce temp files ----
        var produced: [ProducedFile]
        switch kind {
        case .office:
            let job = OfficeEngine.Job(input: input, format: format, image: snapshot.image, mode: mode, compress: compress, near: near)
            produced = try await OfficeEngine.process(job, progress: progress)
        case .document where format.kind == .office:
            guard cls == .pdf else { throw ToolError("Seul le texte des PDF peut être extrait vers \(format.name).") }
            let job = OfficeEngine.Job(input: input, format: format, image: snapshot.image, mode: mode, compress: compress, near: near)
            produced = try await OfficeEngine.process(job, progress: progress)
        case .image, .document:
            guard format.kind == .image else { throw ToolError("Une image ne peut pas être convertie en \(format.name).") }
            let job = ImageEngine.Job(input: input, inputClass: cls, format: format, settings: snapshot.image,
                                      mode: mode, compress: compress, near: near)
            produced = try await ImageEngine.process(job, progress: progress)
        case .video, .audio:
            if kind == .audio && format.kind != .audio { throw ToolError("Un fichier audio ne peut être converti qu'en format audio.") }
            if kind == .video, format.kind == .image, case .animated = format.writer {} else if kind == .video && format.kind == .image {
                throw ToolError("Choisissez un format vidéo, audio ou animé (GIF, WebP, APNG).")
            }
            let job = MediaEngine.Job(input: input, inputKind: kind, format: format, video: snapshot.video, audio: snapshot.audio,
                                      image: snapshot.image, mode: mode, compress: compress, near: near)
            produced = [ProducedFile(url: try await MediaEngine.process(job, progress: progress))]
        }
        try Task.checkCancellation()
        produced = produced.filter { $0.url.fileSize > 0 }
        guard !produced.isEmpty else { throw ToolError("Le fichier de sortie n'a pas été créé.") }

        // ---- Compression never makes things bigger ----
        if mode == .compress, produced.count == 1, produced[0].url.fileSize >= originalSize,
           input.pathExtension.lowercased() == format.ext || FileDetection.sameFormat(for: input) == format {
            try? fm.removeItem(at: produced[0].url)
            return PipelineResult(outputs: [], outputSize: originalSize, note: "Déjà optimisé")
        }

        // ---- Place results ----
        var finals: [URL] = []
        var companions: [URL] = []
        if mode == .compress && snapshot.output.replaceOriginals && produced.count == 1 {
            let dest = input.deletingPathExtension().appendingPathExtension(format.ext)
            let attrs = try? fm.attributesOfItem(atPath: input.path)
            try trash(input)
            if dest != input, fm.fileExists(atPath: dest.path) { try trash(dest) }
            try fm.moveItem(at: produced[0].url, to: dest)
            if snapshot.output.preserveDates, let attrs {
                var keep: [FileAttributeKey: Any] = [:]
                if let c = attrs[.creationDate] { keep[.creationDate] = c }
                if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
                try? fm.setAttributes(keep, ofItemAtPath: dest.path)
            }
            finals = [dest]
        } else {
            for p in produced {
                guard let dest = try OutputResolver.destination(for: input, format: format, mode: mode, settings: snapshot.output,
                                                                 index: index, suffix: p.suffix, overrideFolder: outputFolder) else {
                    try? fm.removeItem(at: p.url)
                    continue
                }
                if fm.fileExists(atPath: dest.path) { try trash(dest) }
                try fm.moveItem(at: p.url, to: dest)
                if snapshot.output.preserveDates { OutputResolver.copyDates(from: input, to: dest) }
                finals.append(dest)
                if let c = p.companion {
                    let cdest = dest.deletingLastPathComponent().appendingPathComponent(c.lastPathComponent, isDirectory: true)
                    if fm.fileExists(atPath: cdest.path) { try trash(cdest) }
                    try fm.moveItem(at: c, to: cdest)
                    companions.append(cdest)
                }
            }
            if finals.isEmpty { return PipelineResult(outputs: [], outputSize: 0, note: "Ignoré (fichier existant)", skipped: true) }
            if snapshot.output.deleteOriginals && !finals.contains(input) {
                try? trash(input)
            }
        }
        let total = finals.reduce(Int64(0)) { $0 + $1.fileSize }
        let note: String? = finals.count > 1 ? "\(finals.count) pages"
            : produced.first?.aiUpscaled == false ? "Agrandi sans IA (Lanczos)"
            : companions.first.map { "Images dans « \($0.lastPathComponent) »" }
        let entry = HistoryEntry(id: UUID(), date: Date(), mode: mode, origin: origin, batch: batch, input: input,
                                 inputSize: originalSize, outputs: (finals + companions).map { HistoryOutput(path: $0.path, size: $0.fileSize) },
                                 formatName: format.name, trashed: trashed, note: note, duration: Date().timeIntervalSince(started))
        HistoryStore.shared.record(entry)
        return PipelineResult(outputs: finals, outputSize: total, note: note, historyID: HistoryStore.shared.enabled ? entry.id : nil)
    }

    /// Expands folders into supported files (optionally recursive), skipping hidden files and packages.
    static func expand(_ urls: [URL], recursive: Bool = true) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            if url.isDirectory {
                let opts: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: opts) {
                    for case let f as URL in e where FileDetection.classify(f) != .unsupported { out.append(f) }
                }
            } else if FileDetection.classify(url) != .unsupported {
                out.append(url)
            }
        }
        return out
    }
}
