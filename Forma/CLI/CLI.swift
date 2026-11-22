import Foundation
import AppKit

/// `forma` command-line interface (the app binary itself, symlinked into /usr/local/bin).
enum CLI {
    static let commands: Set<String> = ["convert", "compress", "upscale", "formats", "tools", "help", "--help", "-h", "--version", "version", "info", "history", "undo", "optimize", "request", "run", "finder", "drop"]

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
        case "request": return request(rest)
        case "run": return runRecipe(rest)
        case "finder": return finder(rest)
        case "drop": return drop(rest)
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
        var dropOptions: DropOptions?
        var dropPrefs = PreferencesStore.loadSnapshot().drop
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
            case "--drop": dropOptions = dropOptions ?? DropOptions()
            case "--expiry":
                guard let v = value(), let e = DropExpiry.parse(v) else { fputs("Durée inconnue : 1h, 1d, 7d, 30d, never.\n", stderr); return 2 }
                dropOptions = dropOptions ?? DropOptions()
                dropOptions?.expiry = e
            case "--direct": dropPrefs.linkStyle = .direct
            case "--origin":
                guard let v = value(), let o = HistoryOrigin(rawValue: v) else { return 2 }
                origin = o
            default:
                if a.hasPrefix("-") { fputs("Option inconnue : \(a)\n\(usage)\n", stderr); return 2 }
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
            }
        }
        if mode == .convert && target == nil { fputs("Précisez --to <format>.\n", stderr); return 2 }
        if dropOptions != nil, !DropServer.isConfigured(dropPrefs) { fputs("✗ \(DropError.notConfigured.localizedDescription)\n", stderr); return 1 }
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
        let dropOpts = dropOptions, dropSettings = dropPrefs
        nonisolated(unsafe) var report: [[String: Any]] = []
        nonisolated(unsafe) var links: [String] = []
        Task.detached {
            let width = mode == .upscale ? 2 : SystemInfo.imageParallelism(requested: 0)
            await withTaskGroup(of: (URL, Result<PipelineResult, Error>, TimeInterval, [DropUpload], Int).self) { group in
                var iterator = inputs.enumerated().makeIterator()
                func add() {
                    guard let (i, u) = iterator.next() else { return }
                    group.addTask {
                        let t = Date()
                        do {
                            let res = try await Pipeline.run(input: u, mode: mode, snapshot: snapshot, index: i + 1, targetOverride: tgt, outputFolder: out, origin: org, batch: batch) { _ in }
                            // Results go to Drop as soon as they are written; the next file converts meanwhile.
                            var sent: [DropUpload] = []
                            var failed = 0
                            if let dropOpts {
                                for o in res.outputs {
                                    do { sent.append(try await DropUploader.upload(o, options: dropOpts, prefs: dropSettings, origin: org, batch: batch, entry: res.historyID)) }
                                    catch { failed += 1; fputs("✗ \(o.lastPathComponent) : \(error.localizedDescription)\n", stderr) }
                                }
                            }
                            return (u, .success(res), Date().timeIntervalSince(t), sent, failed)
                        } catch { return (u, .failure(error), Date().timeIntervalSince(t), [], 0) }
                    }
                }
                for _ in 0..<width { add() }
                while let (u, r, t, sent, uploadFailures) = await group.next() {
                    links += sent.map(\.url)
                    failures += Int32(uploadFailures)
                    if asJSON {
                        var item = resultJSON(u, r, t, mode: mode)
                        if !sent.isEmpty { item["drop"] = sent.map { ["url": $0.url, "key": $0.key] } }
                        report.append(item)
                    }
                    switch r {
                    case .success(let res):
                        if !quiet {
                            let before = u.fileSize
                            if res.outputs.isEmpty { print("• \(u.lastPathComponent): \(res.note ?? "inchangé")") }
                            else {
                                let pct = before > 0 && res.outputSize > 0 && mode != .upscale ? Int((1 - Double(res.outputSize) / Double(max(1, before))) * 100) : 0
                                print("✓ \(u.lastPathComponent) → \(res.outputs.map(\.lastPathComponent).joined(separator: ", ")) · \(res.outputSize.formattedBytes)\(pct > 0 ? " (−\(pct) %)" : "") · \(String(format: "%.2f s", t))")
                                for s in sent { print("  ↑ \(s.url)") }
                            }
                        } else if !asJSON { sent.forEach { print($0.url) } }
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
        if !links.isEmpty, dropOptions?.copyLink ?? dropPrefs.copyLink {
            MainActor.assumeIsolated { DropUploader.copy(links) }
            if !quiet { print(links.count == 1 ? "Lien Drop copié dans le presse-papiers." : "\(links.count) liens Drop copiés dans le presse-papiers.") }
        }
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
        // Results that were sent to Drop go away with their conversion.
        let remote = DropUploader.records(forEntries: done).filter { !$0.isDeleted }
        if !remote.isEmpty {
            let prefs = PreferencesStore.loadSnapshot().drop
            let failed = wait { await DropUploader.delete(remote, prefs: prefs) }
            print("🗑  \(remote.count - failed.count) lien\(remote.count - failed.count > 1 ? "s" : "") Drop supprimé\(remote.count - failed.count > 1 ? "s" : "")")
            for k in failed { fputs("✗ \(k) n'a pas pu être supprimé de Drop\n", stderr); failures += 1 }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: Background requests (same path as the Finder menu)

    /// `forma request <convert|compress|upscale|recipe|open|undo|clipboard> [options] <fichiers…>`
    /// Writes a request into the App Group inbox and wakes Forma, exactly like the Finder extension does.
    static func request(_ args: [String]) -> Int32 {
        var it = args.makeIterator()
        guard let verb = it.next() else { fputs(requestUsage, stderr); return 2 }
        var r = ExternalRequest(source: .cli)
        switch verb {
        case "convert": r.mode = .convert
        case "compress": r.mode = .compress
        case "upscale": r.mode = .upscale
        case "recipe": r.action = .recipe
        case "open": r.action = .open
        case "undo": r.action = .undo
        case "clipboard": r.action = .clipboard
        case "watch": r.action = .watch
        case "upload", "drop": r.action = .upload; r.drop = DropOptions()
        default: fputs(requestUsage, stderr); return 2
        }
        let prefs = PreferencesStore.loadSnapshot()
        var o = RequestOverrides()
        while let a = it.next() {
            switch a {
            case "--to", "-t":
                guard let v = it.next(), let f = FormatCatalog.resolve(v) else { fputs("Format inconnu.\n", stderr); return 2 }
                r.target = f.id
            case "--recipe", "--name":
                guard let v = it.next(), let rec = prefs.recipes.named(v) else { fputs("Recette inconnue. Voir `forma run --list`.\n", stderr); return 2 }
                r.recipe = rec.id
            case "--preset", "-p":
                guard let v = it.next(), let p = CompressionPreset(rawValue: v.replacingOccurrences(of: "-", with: "_")) else { return 2 }
                o.preset = p
            case "--quality", "-q": o.quality = it.next().flatMap(Int.init)
            case "--max": o.maxDimension = it.next().flatMap(Int.init)
            case "--dest":
                guard let v = it.next() else { return 2 }
                r.destination = v == "alongside" ? .alongside : v == "clipboard" ? .clipboard : v == "default" ? .standard
                    : .folder((v as NSString).expandingTildeInPath)
            case "--only":
                r.kinds = it.next()?.split(separator: ",").compactMap { MediaKind(rawValue: String($0)) }
            case "--drop": r.drop = r.drop ?? DropOptions()
            case "--expiry":
                guard let v = it.next(), let e = DropExpiry.parse(v) else { fputs("Durée inconnue : 1h, 1d, 7d, 30d, never.\n", stderr); return 2 }
                var d = r.drop ?? DropOptions(); d.expiry = e; r.drop = d
            case "--no-recursive": r.recursive = false
            case "--reveal": r.reveal = true
            case "--batch": r.batch = it.next().flatMap(UUID.init(uuidString:))
            default:
                if a.hasPrefix("-") { fputs("Option inconnue : \(a)\n", stderr); return 2 }
                r.paths.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardizedFileURL.path)
            }
        }
        if !o.isEmpty { r.overrides = o }
        if r.action == .recipe, r.recipe == nil { fputs("Précisez --recipe <nom>.\n", stderr); return 2 }
        if [.process, .recipe, .open, .watch, .upload].contains(r.action), r.paths.isEmpty { fputs("Aucun fichier.\n", stderr); return 2 }
        do {
            guard let inbox = GroupContainer.inbox, let url = GroupContainer.requestURL(r.id) else { throw GroupContainer.GroupError.unavailable }
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try RequestCodec.encode(r).write(to: url, options: .atomic)
        } catch {
            fputs("✗ \(error.localizedDescription)\n", stderr); return 1
        }
        // Wait for Launch Services to deliver the URL before this process exits.
        let sem = DispatchSemaphore(value: 0)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.arguments = ["--headless"]
        let app = GroupContainer.preferredAppURL() ?? GroupContainer.installedAppURL
        nonisolated(unsafe) var failure: Error?
        NSWorkspace.shared.open([GroupContainer.jobURL(r.id)], withApplicationAt: app, configuration: config) { _, e in failure = e; sem.signal() }
        _ = sem.wait(timeout: .now() + 15)
        if let failure { fputs("✗ \(failure.localizedDescription)\n", stderr); return 1 }
        print("→ demande \(r.id.uuidString.prefix(8)) envoyée à Forma (\(app.path))")
        return 0
    }

    static let requestUsage = """
    forma request <convert|compress|upscale|recipe|open|undo|clipboard|watch|upload> [options] <fichiers…>
      --to <fmt>  --recipe <nom>  --preset <nom>  -q <1-100>  --max <px>
      --dest alongside|clipboard|default|<dossier>  --only image,video,…  --no-recursive  --reveal
      --drop [--expiry 7d]     envoie les résultats sur Drop (avec « upload » : les fichiers tels quels)

    """

    /// `forma run <recette> <fichiers…> [--json]` — applies a recipe in this process. `forma run --list` lists them.
    static func runRecipe(_ args: [String]) -> Int32 {
        let prefs = PreferencesStore.loadSnapshot()
        guard let name = args.first, name != "--list" else {
            if prefs.recipes.isEmpty { print("Aucune recette (Réglages › Finder › Recettes).") }
            for r in prefs.recipes { print("• \(r.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(r.detail)") }
            return 0
        }
        guard let recipe = prefs.recipes.named(name) else { fputs("Recette inconnue : \(name). Voir `forma run --list`.\n", stderr); return 2 }
        let json = args.contains("--json")
        let paths = args.dropFirst().filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        guard !paths.isEmpty else { fputs("forma run <recette> <fichiers…> [--json]\n", stderr); return 2 }
        var r = ExternalRequest(source: .cli, action: .recipe, paths: paths)
        r.recipe = recipe.id
        let plan: JobPlan
        do { plan = try RequestPlanner.plan(r, prefs: prefs) } catch { fputs("✗ \(error.localizedDescription)\n", stderr); return 1 }
        guard !plan.files.isEmpty else {
            if json { print("[]") }
            fputs("Aucun fichier compatible avec la recette « \(recipe.name) ».\n", stderr); return 1
        }
        if !json { print("\(plan.title) · \(plan.files.count) fichier\(plan.files.count > 1 ? "s" : "")\(plan.ignored > 0 ? " (\(plan.ignored) ignoré(s))" : "")") }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failures: Int32 = 0
        nonisolated(unsafe) var report: [[String: Any]] = []
        let batch = UUID()
        let dropSettings = prefs.drop
        nonisolated(unsafe) var links: [String] = []
        Task.detached {
            let width = plan.mode == .upscale ? 2 : SystemInfo.imageParallelism(requested: 0)
            await withTaskGroup(of: (URL, Result<PipelineResult, Error>, TimeInterval).self) { group in
                var iterator = plan.files.enumerated().makeIterator()
                func add() {
                    guard let (i, f) = iterator.next() else { return }
                    group.addTask {
                        let t = Date()
                        do {
                            let res = try await Pipeline.run(input: f.url, mode: plan.mode, snapshot: plan.snapshot, index: i + 1, targetOverride: f.target,
                                                             outputFolder: f.outputFolder, origin: .cli, batch: batch) { _ in }
                            if let dropOptions = plan.drop {
                                for o in res.outputs {
                                    do {
                                        let up = try await DropUploader.upload(o, options: dropOptions, prefs: dropSettings, origin: .cli, batch: batch, entry: res.historyID)
                                        links.append(up.url)
                                        if !json { print("  ↑ \(up.url)") }
                                    } catch { fputs("✗ \(o.lastPathComponent) : \(error.localizedDescription)\n", stderr) }
                                }
                            }
                            return (f.url, .success(res), Date().timeIntervalSince(t))
                        } catch { return (f.url, .failure(error), Date().timeIntervalSince(t)) }
                    }
                }
                for _ in 0..<width { add() }
                while let (u, res, t) = await group.next() {
                    if json { report.append(resultJSON(u, res, t, mode: plan.mode)) }
                    switch res {
                    case .success(let out):
                        if !json { print(out.outputs.isEmpty ? "• \(u.lastPathComponent): \(out.note ?? "inchangé")" : "✓ \(u.lastPathComponent) → \(out.outputs.map(\.lastPathComponent).joined(separator: ", ")) · \(out.outputSize.formattedBytes)") }
                    case .failure(let e):
                        failures += 1
                        if !json { fputs("✗ \(u.lastPathComponent): \(e.localizedDescription)\n", stderr) }
                    }
                    add()
                }
            }
            sem.signal()
        }
        sem.wait()
        if json { printJSON(report) }
        if !links.isEmpty, plan.drop?.copyLink ?? dropSettings.copyLink {
            MainActor.assumeIsolated { DropUploader.copy(links) }
            if !json { print(links.count == 1 ? "Lien Drop copié dans le presse-papiers." : "\(links.count) liens Drop copiés dans le presse-papiers.") }
        }
        return failures == 0 ? 0 : 1
    }

    /// `forma finder status|enable|disable|reset|menu [--container|--toolbar] <fichiers…>`
    static func finder(_ args: [String]) -> Int32 {
        switch args.first ?? "status" {
        case "status":
            for id in [ExtensionStatus.finderID, ExtensionStatus.shareID] {
                let s = ExtensionStatus.query(id)
                print("\(s.state == .enabled ? "✓" : "✗") \(id) — \(s.label)\(s.version.map { " · \($0)" } ?? "")")
                if let p = s.path { print("    chargée : \(p)") }
                for o in s.otherPaths { print("    autre copie enregistrée : \(o)") }
            }
            if let url = GroupContainer.menuConfigURL {
                let m = url.modificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "absent"
                print("menu.json : \(url.path) (\(m))")
            }
            print("demandes en attente : \(GroupContainer.pendingRequests().count)")
            return 0
        case "enable":
            ExtensionStatus.setEnabled(ExtensionStatus.finderID, true); ExtensionStatus.setEnabled(ExtensionStatus.shareID, true)
            print("Extensions activées."); return 0
        case "disable":
            ExtensionStatus.setEnabled(ExtensionStatus.finderID, false); ExtensionStatus.setEnabled(ExtensionStatus.shareID, false)
            print("Extensions désactivées."); return 0
        case "reset":
            ExtensionStatus.reset().forEach { print($0) }
            return 0
        case "menu":
            let rest = Array(args.dropFirst())
            let place: MenuPlace = rest.contains("--container") ? .container : rest.contains("--toolbar") ? .toolbar : .items
            let urls = rest.filter { !$0.hasPrefix("--") }.map { p -> URL in
                let path = (p as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                return URL(fileURLWithPath: path, isDirectory: isDir.boolValue)
            }
            let config = MenuConfigStore.Reader().config
            let t = Date()
            let nodes = MenuBuilder.build(MenuBuilder.summarize(urls), config: config, place: place)
            let ms = Date().timeIntervalSince(t) * 1000
            if nodes.isEmpty { print("(aucun menu Forma pour cette sélection)") }
            func dump(_ n: MenuNode, _ depth: Int) {
                let pad = String(repeating: "   ", count: depth)
                switch n {
                case .separator: print(pad + "─────────")
                case .header(let t): print(pad + "[\(t)]")
                case .item(let t, _, let e):
                    var d = e.action.rawValue
                    if e.action == .process { d += " \(e.mode.rawValue)" + (e.target.map { " → \($0)" } ?? "") }
                    if let k = e.kinds { d += " [\(k.map(\.rawValue).joined(separator: ","))]" }
                    if let p = e.preset { d += " preset=\(p.rawValue)" }
                    print(pad + t + "    · " + d)
                case .submenu(let t, _, let c):
                    print(pad + t + " ▸")
                    c.forEach { dump($0, depth + 1) }
                }
            }
            nodes.forEach { dump($0, 0) }
            print(String(format: "(%d éléments analysés en %.2f ms)", urls.count, ms))
            return 0
        default:
            fputs("forma finder status|enable|disable|reset|menu [--container|--toolbar] <fichiers…>\n", stderr)
            return 2
        }
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
          --drop [--expiry 7d] [--direct]   envoie ensuite chaque résultat sur Drop et copie le lien

      forma optimize <images…> [--app <bundle id>] [--force] [-o <dossier>] [--json]
                               applique les règles de l'optimiseur de presse-papiers

    RECETTES & INTÉGRATION FINDER
      forma run <recette> <fichiers…> [--json]   applique une recette (forma run --list)
      forma request <convert|compress|upscale|recipe|open|undo|clipboard> [options] <fichiers…>
                               confie le travail à Forma en arrière-plan, comme le menu du Finder
      forma drop <fichiers…> [--expiry 7d] [--direct]   envoie sur Drop et copie le lien (forma drop --help)
      forma finder status|enable|disable|reset   état des extensions Finder et Partager
      forma finder menu [--container|--toolbar] <fichiers…>   affiche le menu Finder pour ces fichiers
    """
}
