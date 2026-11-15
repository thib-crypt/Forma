import Foundation

/// `forma` command-line interface (the app binary itself, symlinked into /usr/local/bin).
enum CLI {
    static let commands: Set<String> = ["convert", "compress", "upscale", "formats", "tools", "help", "--help", "-h", "--version", "version", "info", "history", "undo", "optimize"]

    static func shouldHandle(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        return commands.contains(args[1])
    }

    static func run(_ args: [String]) -> Int32 {
        let cmd = args[1]
        var rest = Array(args.dropFirst(2))
        switch cmd {
        case "help", "--help", "-h": print(usage); return 0
        case "--version", "version":
            print("forma \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"); return 0
        case "formats":
            for kind in [MediaKind.image, .audio, .video, .office] {
                print("\n\(kind.label.uppercased())")
                let list = kind == .image ? FormatCatalog.images : kind == .audio ? FormatCatalog.audio : kind == .video ? FormatCatalog.video : FormatCatalog.office
                for f in list { print("  \(f.id.padding(toLength: 8, withPad: " ", startingAt: 0)) .\(f.ext.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f.name) — \(f.detail)") }
            }
            return 0
        case "tools":
            for t in Tool.allCases { print("\(t.isAvailable ? "✓" : "✗") \(t.label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(t.path ?? "brew install \(t.brewFormula)")") }
            return 0
        case "history": return history(rest)
        case "optimize": return optimize(rest)
        case "undo": return undo(rest)
        case "info":
            for p in rest {
                let u = URL(fileURLWithPath: p)
                print("\(u.lastPathComponent): \(FileDetection.classify(u)) · \(u.fileSize.formattedBytes)")
            }
            return 0
        default: break
        }

        let mode: ProcessMode = cmd == "convert" ? .convert : cmd == "upscale" ? .upscale : .compress
        var snap = PreferencesStore.loadSnapshot().processing
        var target: FormatDescriptor?
        var outDir: URL?
        var files: [URL] = []
        var quiet = false
        var json = false
        var origin: HistoryOrigin = .cli
        func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--to", "-t":
                guard let v = value(), let f = FormatCatalog.resolve(v) else { fputs("Format inconnu. Voir `forma formats`.\n", stderr); return 2 }
                target = f
            case "--quality", "-q":
                guard let v = value().flatMap(Int.init) else { return 2 }
                snap.image.preset = .custom; snap.image.customQuality = v
                snap.video.preset = .custom; snap.video.quality = v
                if mode == .convert { snap.compressWhileConverting = true }
            case "--preset", "-p":
                guard let v = value(), let p = CompressionPreset(rawValue: v.replacingOccurrences(of: "-", with: "_")) else {
                    fputs("Préréglages : \(CompressionPreset.allCases.map(\.rawValue).joined(separator: ", "))\n", stderr); return 2
                }
                snap.image.preset = p
            case "--target-size":
                guard let v = value() else { return 2 }
                let lower = v.lowercased()
                let n = Double(lower.trimmingCharacters(in: CharacterSet.letters)) ?? 0
                snap.image.targetFileSizeKB = Int(lower.hasSuffix("mb") ? n * 1024 : n)
            case "--resize", "-r":
                guard let v = value() else { return 2 }
                if v.hasSuffix("%"), let p = Int(v.dropLast()) { snap.image.resizeMode = .percent; snap.image.percent = p }
                else {
                    let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { snap.image.resizeMode = .fit; snap.image.width = parts[0]; snap.image.height = parts[1] }
                    else if parts.count == 1 { snap.image.resizeMode = .width; snap.image.width = parts[0] }
                }
            case "--strip": snap.image.metadata = .stripAll
            case "--keep-metadata": snap.image.metadata = .keepAll
            case "--replace": snap.output.replaceOriginals = true
            case "--overwrite": snap.output.conflict = .overwrite
            case "--codec":
                if let v = value(), let c = VideoCodec(rawValue: v.lowercased()) { snap.video.codec = c; snap.video.preset = .custom }
            case "--resolution":
                if let v = value(), let r = VideoResolution(rawValue: "p" + v.lowercased().replacingOccurrences(of: "p", with: "")) { snap.video.resolution = r }
            case "--no-hw": snap.video.hardwareAcceleration = false
            case "--out", "-o":
                guard let v = value() else { return 2 }
                outDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            case "--quiet": quiet = true
            case "--json": json = true; quiet = true
            case "--origin":
                guard let v = value(), let o = HistoryOrigin(rawValue: v) else { return 2 }
                origin = o
            default:
                if a.hasPrefix("-") { fputs("Option inconnue : \(a)\n\(usage)\n", stderr); return 2 }
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
            }
        }
        if mode == .convert && target == nil { fputs("Précisez --to <format>.\n", stderr); return 2 }
        var inputs = Pipeline.expand(files)
        if mode == .upscale {
            inputs = inputs.filter { FileDetection.classify($0).mediaKind == .image }
            if !Upscaler.isSupported { fputs("Super-résolution IA indisponible : agrandissement Lanczos.\n", stderr) }
            else if Upscaler.modelState != .ready && !quiet { print("Téléchargement du modèle IA d'Apple (une seule fois)…") }
        }
        guard !inputs.isEmpty else {
            if json { print("[]") }
            fputs("Aucun fichier compatible.\n", stderr); return 1
        }

        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failures: Int32 = 0
        let snapshot = snap, tgt = target, out = outDir, batch = UUID(), org = origin, asJSON = json
        nonisolated(unsafe) var report: [[String: Any]] = []
        Task.detached {
            let width = mode == .upscale ? 2 : SystemInfo.imageParallelism(requested: 0)
            await withTaskGroup(of: (URL, Result<PipelineResult, Error>, TimeInterval).self) { group in
                var iterator = inputs.enumerated().makeIterator()
                func add() {
                    guard let (i, u) = iterator.next() else { return }
                    group.addTask {
                        let t = Date()
                        do { return (u, .success(try await Pipeline.run(input: u, mode: mode, snapshot: snapshot, index: i + 1, targetOverride: tgt, outputFolder: out, origin: org, batch: batch) { _ in }), Date().timeIntervalSince(t)) }
                        catch { return (u, .failure(error), Date().timeIntervalSince(t)) }
                    }
                }
                for _ in 0..<width { add() }
                while let (u, r, t) = await group.next() {
                    if asJSON { report.append(resultJSON(u, r, t, mode: mode)) }
                    switch r {
                    case .success(let res):
                        if !quiet {
                            let before = u.fileSize
                            if res.outputs.isEmpty { print("• \(u.lastPathComponent): \(res.note ?? "inchangé")") }
                            else {
                                let pct = before > 0 && res.outputSize > 0 && mode != .upscale ? Int((1 - Double(res.outputSize) / Double(max(1, before))) * 100) : 0
                                print("✓ \(u.lastPathComponent) → \(res.outputs.map(\.lastPathComponent).joined(separator: ", ")) · \(res.outputSize.formattedBytes)\(pct > 0 ? " (−\(pct) %)" : "") · \(String(format: "%.2f s", t))")
                            }
                        }
                    case .failure(let e):
                        failures += 1
                        if !asJSON { fputs("✗ \(u.lastPathComponent): \(e.localizedDescription)\n", stderr) }
                    }
                    add()
                }
            }
            sem.signal()
        }
        sem.wait()
        if json { printJSON(report) }
        return failures == 0 ? 0 : 1
    }

    static func printJSON(_ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        print(String(data: data, encoding: .utf8) ?? "[]")
    }

    static func resultJSON(_ u: URL, _ r: Result<PipelineResult, Error>, _ t: TimeInterval, mode: ProcessMode) -> [String: Any] {
        var d: [String: Any] = ["input": u.path, "inputSize": u.fileSize, "seconds": (t * 100).rounded() / 100]
        switch r {
        case .success(let res):
            d["status"] = res.outputs.isEmpty ? (res.skipped ? "skipped" : "unchanged") : "done"
            d["outputs"] = res.outputs.map { ["path": $0.path, "size": $0.fileSize] }
            d["outputSize"] = res.outputSize
            if mode != .upscale, res.outputSize > 0, u.fileSize > 0 { d["savingsPercent"] = Int(((1 - Double(res.outputSize) / Double(u.fileSize)) * 100).rounded()) }
            if let n = res.note { d["note"] = n }
            if let h = res.historyID { d["historyID"] = h.uuidString }
        case .failure(let e):
            d["status"] = "error"
            d["error"] = e.localizedDescription
        }
        return d
    }

    // MARK: Clipboard rules

    /// `forma optimize <images…> [--app <bundle id>] [--force] [-o <dossier>] [--json]`
    /// Applies the clipboard optimizer rules to files (used by Copia's "Coller optimisé").
    static func optimize(_ args: [String]) -> Int32 {
        var files: [URL] = [], app: String?, force = false, json = false, outDir: URL?
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--app": app = it.next()
            case "--force": force = true
            case "--json": json = true
            case "-o", "--out": outDir = it.next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            default:
                if a.hasPrefix("-") { fputs("Option inconnue : \(a)\n", stderr); return 2 }
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
            }
        }
        guard !files.isEmpty else { fputs("forma optimize <images…> [--app <bundle id>] [--force] [-o dossier] [--json]\n", stderr); return 2 }
        let settings = PreferencesStore.loadSnapshot().clipboard
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var report: [[String: Any]] = []
        nonisolated(unsafe) var failures: Int32 = 0
        let list = files, src = app, f = force, out = outDir
        Task.detached {
            for u in list {
                var d: [String: Any] = ["input": u.path]
                do {
                    let o = try await ClipboardEngine.optimize(file: u, sourceApp: src, settings: settings, force: f, outputDir: out)
                    d["status"] = o.status.rawValue
                    d["rule"] = o.rule
                    d["inputSize"] = o.before
                    d["outputSize"] = o.after
                    d["width"] = o.width
                    d["height"] = o.height
                    if let r = o.reason { d["reason"] = r }
                    if let out = o.output { d["output"] = out.path }
                    if let fmt = o.format { d["format"] = fmt.name; d["ext"] = fmt.ext }
                    if o.status == .optimized { d["savingsPercent"] = o.savingsPercent }
                    if !json {
                        switch o.status {
                        case .optimized: print("✓ \(u.lastPathComponent) → \(o.output?.lastPathComponent ?? "") · \(o.after.formattedBytes) (−\(o.savingsPercent) %) · règle « \(o.rule) »")
                        default: print("• \(u.lastPathComponent): \(o.reason ?? "inchangée") · règle « \(o.rule) »")
                        }
                    }
                } catch {
                    failures += 1
                    d["status"] = "error"; d["error"] = error.localizedDescription
                    if !json { fputs("✗ \(u.lastPathComponent): \(error.localizedDescription)\n", stderr) }
                }
                report.append(d)
            }
            sem.signal()
        }
        sem.wait()
        if json { printJSON(report) }
        return failures == 0 ? 0 : 1
    }

    // MARK: History

    static func entryJSON(_ e: HistoryEntry) -> [String: Any] {
        var d: [String: Any] = [
            "id": e.id.uuidString, "date": ISO8601DateFormatter().string(from: e.date), "mode": e.mode.rawValue,
            "origin": e.origin.rawValue, "input": e.input.path, "inputSize": e.inputSize,
            "outputs": e.outputs.map { ["path": $0.path, "size": $0.size] }, "outputSize": e.outputSize,
            "format": e.formatName, "originalTrashed": e.originalWasTrashed, "undone": e.isUndone,
        ]
        if let b = e.batch { d["batch"] = b.uuidString }
        if let s = e.savings { d["savingsPercent"] = Int((s * 100).rounded()) }
        if let n = e.note { d["note"] = n }
        return d
    }

    /// `forma history [-n 20] [--json]`
    static func history(_ args: [String]) -> Int32 {
        var limit = 20, json = false
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "-n", "--limit": limit = it.next().flatMap(Int.init) ?? limit
            case "--json": json = true
            case "--all": limit = 100_000
            default: fputs("Option inconnue : \(a)\n", stderr); return 2
            }
        }
        let list = HistoryStore.shared.fetch(limit: limit)
        if json {
            let data = (try? JSONSerialization.data(withJSONObject: list.map(entryJSON), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
            return 0
        }
        if list.isEmpty { print("Historique vide."); return 0 }
        let df = DateFormatter(); df.dateFormat = "dd/MM HH:mm"
        for e in list {
            let flag = e.isUndone ? "↩" : e.outputURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) ? "✓" : "?"
            let pct = e.savings.map { $0 > 0.005 ? " (−\(Int(($0 * 100).rounded())) %)" : "" } ?? ""
            print("\(flag) \(df.string(from: e.date))  \(e.mode.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.input.lastPathComponent) → \(e.outputs.first.map { ($0.path as NSString).lastPathComponent } ?? "—") · \(e.outputSize.formattedBytes)\(pct)\(e.origin == .app ? "" : "  [\(e.origin.label)]")  \(e.id.uuidString.prefix(8))")
        }
        return 0
    }

    /// `forma undo [--last | <id…>]` — the last batch by default.
    static func undo(_ args: [String]) -> Int32 {
        let all = HistoryStore.shared.fetch(limit: 100_000)
        var targets: [HistoryEntry]
        let ids = args.filter { !$0.hasPrefix("-") }
        if ids.isEmpty {
            guard let first = all.first(where: { !$0.isUndone }) else { fputs("Rien à annuler.\n", stderr); return 1 }
            targets = first.batch.map { b in all.filter { $0.batch == b && !$0.isUndone } } ?? [first]
        } else {
            targets = all.filter { e in ids.contains { e.id.uuidString.lowercased().hasPrefix($0.lowercased()) } }
            guard !targets.isEmpty else { fputs("Aucune entrée ne correspond.\n", stderr); return 1 }
        }
        var failures: Int32 = 0
        var done: [UUID] = []
        for e in targets {
            do {
                let r = try HistoryUndo.undo(e)
                done.append(e.id)
                print("↩ \(e.input.lastPathComponent): \(r.trashedOutputs.count) résultat(s) à la Corbeille\(r.restored.isEmpty ? "" : ", \(r.restored.count) fichier(s) restauré(s)")\(r.keptModified.isEmpty ? "" : ", \(r.keptModified.count) modifié(s) conservé(s)")")
            } catch {
                failures += 1
                fputs("✗ \(e.input.lastPathComponent): \(error.localizedDescription)\n", stderr)
            }
        }
        HistoryStore.shared.markUndone(done)
        return failures == 0 ? 0 : 1
    }

    static let usage = """
    forma — convertisseur & compresseur local (images, vidéo, audio, PDF, documents)

    UTILISATION
      forma convert <fichiers|dossiers…> --to <format> [options]
      forma compress <fichiers|dossiers…> [options]
      forma upscale <images|dossiers…> [--to <format>] [-o <dossier>]
                               agrandit ×2 par super-résolution IA (Neural Engine)
      forma history [-n 20] [--json]   derniers traitements (toutes origines)
      forma undo [<id>…]       annule le dernier lot (ou les entrées données)
      forma formats            liste des formats de sortie
      forma tools              état des moteurs (ffmpeg, ImageMagick…)

    OPTIONS
      -t, --to <fmt>           format de sortie (jpg, webp, heic, avif, mp4, mp3, docx, pdf, md, epub…)
      -q, --quality <1-100>    qualité
      -p, --preset <nom>       maximum_quality | high_quality | balanced | web_optimized | social_media | maximum_compression
          --target-size <taille>  ex. 500KB, 2MB (images)
      -r, --resize <WxH|W|N%>  redimensionner (tenir dans WxH)
          --strip / --keep-metadata
          --codec <h264|hevc|av1|vp9|prores>   --resolution <1080|720…>   --no-hw
      -o, --out <dossier>      dossier de sortie
          --replace            remplacer les originaux (compression, originaux à la Corbeille)
          --overwrite          écraser les fichiers existants
          --quiet
          --json               résultat en JSON (pour les scripts et Copia)

      forma optimize <images…> [--app <bundle id>] [--force] [-o <dossier>] [--json]
                               applique les règles de l'optimiseur de presse-papiers
    """
}
