import Foundation

/// External engines. Everything native (ImageIO, VideoToolbox through ffmpeg, PDFKit) is used first;
/// these binaries only cover formats macOS can't write on its own.
enum Tool: String, CaseIterable, Sendable {
    case magick, ffmpeg, ffprobe, gs, cwebp, gif2webp, cjxl, mozjpeg, pngquant, oxipng, gifsicle, pandoc, soffice

    var label: String {
        switch self {
        case .magick: "ImageMagick"
        case .ffmpeg: "FFmpeg"
        case .ffprobe: "FFprobe"
        case .gs: "Ghostscript"
        case .cwebp: "cwebp (libwebp)"
        case .gif2webp: "gif2webp (libwebp)"
        case .cjxl: "cjxl (libjxl)"
        case .mozjpeg: "MozJPEG"
        case .pngquant: "pngquant"
        case .oxipng: "oxipng"
        case .gifsicle: "gifsicle"
        case .pandoc: "Pandoc"
        case .soffice: "LibreOffice"
        }
    }
    var purpose: String {
        switch self {
        case .magick: "Formats exotiques, RAW, PSD, SVG"
        case .ffmpeg: "Vidéo & audio (VideoToolbox)"
        case .ffprobe: "Analyse des médias"
        case .gs: "PDF, EPS, Illustrator"
        case .cwebp: "Encodeur WebP rapide"
        case .gif2webp: "GIF → WebP animé en un éclair"
        case .cjxl: "Encodeur JPEG XL"
        case .mozjpeg: "JPEG 5–15 % plus légers"
        case .pngquant: "PNG avec perte (-60 à -80 %)"
        case .oxipng: "PNG sans perte optimisés"
        case .gifsicle: "GIF optimisés"
        case .pandoc: "Word, Markdown, EPUB, LaTeX…"
        case .soffice: "Mise en page Office fidèle, Excel, PowerPoint"
        }
    }
    var brewFormula: String {
        switch self {
        case .magick: "imagemagick"
        case .ffmpeg, .ffprobe: "ffmpeg"
        case .gs: "ghostscript"
        case .cwebp, .gif2webp: "webp"
        case .cjxl: "jpeg-xl"
        case .mozjpeg: "mozjpeg"
        case .soffice: "--cask libreoffice"
        default: rawValue
        }
    }
    private var candidates: [String] {
        switch self {
        case .mozjpeg: ["/opt/homebrew/opt/mozjpeg/bin/cjpeg", "/usr/local/opt/mozjpeg/bin/cjpeg"]
        case .soffice: ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "\(NSHomeDirectory())/Applications/LibreOffice.app/Contents/MacOS/soffice",
                        "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
        default: ["/opt/homebrew/bin/\(rawValue)", "/usr/local/bin/\(rawValue)", "/opt/local/bin/\(rawValue)"]
        }
    }

    private static let cache: [Tool: String] = {
        var d: [Tool: String] = [:]
        let fm = FileManager.default
        for t in Tool.allCases {
            if let p = t.candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { d[t] = p }
        }
        return d
    }()

    var path: String? { Tool.cache[self] }
    var isAvailable: Bool { path != nil }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
}

/// Runs a command-line process asynchronously with cancellation, timeout and live stderr/stdout parsing.
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    static func run(_ executable: String,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    stdin: Data? = nil,
                    cwd: URL? = nil,
                    timeout: TimeInterval = 3600,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        environment?.forEach { env[$0] = $1 }
        process.environment = env
        process.qualityOfService = .userInitiated

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe } else { process.standardInput = FileHandle.nullDevice }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var out = Data()
            var err = Data()
            var errText = ""
            var lineBuffer = ""
            var timedOut = false
        }
        let box = Box()

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            box.lock.lock(); box.out.append(d)
            var lines: [String] = []
            if onLine != nil, let s = String(data: d, encoding: .utf8) {
                box.lineBuffer += s
                while let r = box.lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    lines.append(String(box.lineBuffer[..<r]))
                    box.lineBuffer.removeSubrange(...r)
                }
            }
            box.lock.unlock()
            lines.forEach { onLine?($0) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            box.lock.lock()
            box.err.append(d)
            if box.err.count > 256_000 { box.err.removeFirst(box.err.count - 128_000) }
            box.lock.unlock()
            if let onLine, let s = String(data: d, encoding: .utf8) {
                s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).forEach { onLine(String($0)) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    box.timedOut = true
                    if process.isRunning { process.terminate() }
                }
                process.terminationHandler = { p in
                    timer.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    box.lock.lock()
                    box.out.append(restOut); box.err.append(restErr)
                    let result = Result(status: p.terminationStatus, stdout: box.out,
                                        stderr: String(decoding: box.err, as: UTF8.self))
                    box.lock.unlock()
                    if box.timedOut {
                        cont.resume(throwing: ToolError("Délai dépassé après \(Int(timeout)) s"))
                    } else if p.terminationReason == .uncaughtSignal && Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: result)
                    }
                }
                do {
                    try process.run()
                    timer.resume()
                    if let inPipe, let stdin {
                        DispatchQueue.global().async {
                            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                            try? inPipe.fileHandleForWriting.close()
                        }
                    }
                } catch {
                    timer.cancel()
                    cont.resume(throwing: ToolError("Impossible de lancer \(URL(fileURLWithPath: executable).lastPathComponent) : \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs and throws a readable error when the exit status is non-zero.
    @discardableResult
    static func check(_ tool: Tool, _ arguments: [String], stdin: Data? = nil, cwd: URL? = nil, timeout: TimeInterval = 3600,
                      onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        guard let path = tool.path else {
            throw ToolError("\(tool.label) n'est pas installé — `brew install \(tool.brewFormula)`")
        }
        let r = try await run(path, arguments, stdin: stdin, cwd: cwd, timeout: timeout, onLine: onLine)
        try Task.checkCancellation()
        guard r.status == 0 else {
            throw ToolError(Self.humanize(tool: tool, stderr: r.stderr, status: r.status))
        }
        return r
    }

    static func humanize(tool: Tool, stderr: String, status: Int32) -> String {
        let s = stderr.lowercased()
        if s.contains("no space left") { return "Espace disque insuffisant." }
        if s.contains("permission denied") { return "Permission refusée sur ce fichier." }
        if s.contains("password") || s.contains("encrypted") { return "Ce PDF est protégé par mot de passe. Déverrouillez-le d'abord." }
        if s.contains("moov atom not found") { return "Vidéo corrompue (atome moov manquant)." }
        if s.contains("drm") || s.contains("protected") { return "Média protégé par DRM, conversion impossible." }
        if s.contains("does not contain any stream") || s.contains("output file is empty") { return "Le fichier ne contient aucun flux exploitable." }
        if s.contains("invalid data found") { return "Fichier invalide ou corrompu." }
        if s.contains("no decoder") || s.contains("no delegate") { return "Format non pris en charge par \(tool.label)." }
        let last = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty && !$0.hasPrefix("frame=") && !$0.hasPrefix("size=") && !$0.contains("=") }) ?? ""
        return last.isEmpty ? "\(tool.label) a échoué (code \(status))." : "\(tool.label) : \(last.prefix(220))"
    }
}

enum SystemInfo {
    static let performanceCores: Int = {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &v, &size, nil, 0) == 0, v > 0 { return Int(v) }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()
    static let totalCores = ProcessInfo.processInfo.activeProcessorCount
    static let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    /// Parallelism that adapts to the thermal state so long batches never throttle the Mac.
    static func imageParallelism(requested: Int) -> Int {
        let base = requested > 0 ? requested : max(2, totalCores - 1)
        switch ProcessInfo.processInfo.thermalState {
        case .serious: return max(1, base / 2)
        case .critical: return 1
        default: return base
        }
    }
}
