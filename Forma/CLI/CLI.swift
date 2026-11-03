import Foundation

/// `forma` command-line interface (the app binary itself, symlinked into /usr/local/bin).
enum CLI {
    static let commands: Set<String> = ["convert", "compress", "formats", "tools", "help", "--help", "-h", "--version", "version", "info"]

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
            for kind in [MediaKind.image, .audio, .video] {
                print("\n\(kind.label.uppercased())")
                let list = kind == .image ? FormatCatalog.images : kind == .audio ? FormatCatalog.audio : FormatCatalog.video
                for f in list { print("  \(f.id.padding(toLength: 8, withPad: " ", startingAt: 0)) .\(f.ext.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f.name) — \(f.detail)") }
            }
            return 0
        case "tools":
            for t in Tool.allCases { print("\(t.isAvailable ? "✓" : "✗") \(t.label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(t.path ?? "brew install \(t.brewFormula)")") }
            return 0
        case "info":
            for p in rest {
                let u = URL(fileURLWithPath: p)
                print("\(u.lastPathComponent): \(FileDetection.classify(u)) · \(u.fileSize.formattedBytes)")
            }
            return 0
        default: break
        }

        let mode: ProcessMode = cmd == "convert" ? .convert : .compress
        var snap = PreferencesStore.loadSnapshot().processing
        var target: FormatDescriptor?
        var outDir: URL?
        var files: [URL] = []
        var quiet = false
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
            default:
                if a.hasPrefix("-") { fputs("Option inconnue : \(a)\n\(usage)\n", stderr); return 2 }
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
            }
        }
        if mode == .convert && target == nil { fputs("Précisez --to <format>.\n", stderr); return 2 }
        let inputs = Pipeline.expand(files)
        guard !inputs.isEmpty else { fputs("Aucun fichier compatible.\n", stderr); return 1 }

        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failures: Int32 = 0
        let snapshot = snap, tgt = target, out = outDir
        Task.detached {
            let width = SystemInfo.imageParallelism(requested: 0)
            await withTaskGroup(of: (URL, Result<PipelineResult, Error>, TimeInterval).self) { group in
                var iterator = inputs.enumerated().makeIterator()
                func add() {
                    guard let (i, u) = iterator.next() else { return }
                    group.addTask {
                        let t = Date()
                        do { return (u, .success(try await Pipeline.run(input: u, mode: mode, snapshot: snapshot, index: i + 1, targetOverride: tgt, outputFolder: out) { _ in }), Date().timeIntervalSince(t)) }
                        catch { return (u, .failure(error), Date().timeIntervalSince(t)) }
                    }
                }
                for _ in 0..<width { add() }
                while let (u, r, t) = await group.next() {
                    switch r {
                    case .success(let res):
                        if !quiet {
                            let before = u.fileSize
                            if res.outputs.isEmpty { print("• \(u.lastPathComponent): \(res.note ?? "inchangé")") }
                            else {
                                let pct = before > 0 && res.outputSize > 0 ? Int((1 - Double(res.outputSize) / Double(max(1, before))) * 100) : 0
                                print("✓ \(u.lastPathComponent) → \(res.outputs.map(\.lastPathComponent).joined(separator: ", ")) · \(res.outputSize.formattedBytes)\(pct > 0 ? " (−\(pct) %)" : "") · \(String(format: "%.2f s", t))")
                            }
                        }
                    case .failure(let e):
                        failures += 1
                        fputs("✗ \(u.lastPathComponent): \(e.localizedDescription)\n", stderr)
                    }
                    add()
                }
            }
            sem.signal()
        }
        sem.wait()
        return failures == 0 ? 0 : 1
    }

    static let usage = """
    forma — convertisseur & compresseur local (images, vidéo, audio, PDF)

    UTILISATION
      forma convert <fichiers|dossiers…> --to <format> [options]
      forma compress <fichiers|dossiers…> [options]
      forma formats            liste des formats de sortie
      forma tools              état des moteurs (ffmpeg, ImageMagick…)

    OPTIONS
      -t, --to <fmt>           format de sortie (jpg, webp, heic, avif, mp4, mp3…)
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
    """
}
