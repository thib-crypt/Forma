import Foundation
import ImageIO
import CoreImage
import AppKit
import QuickLookThumbnailing

/// What the before/after viewer shows.
struct PreviewRequest: Identifiable {
    enum Source {
        /// A row of the main list: live preview with the current settings, or its actual result once processed.
        case item(FileItem, ProcessMode)
        /// A history entry: original (in place or in the Trash) vs output.
        case history(HistoryEntry)
    }
    let id = UUID()
    let source: Source
}

/// One side of the comparison.
struct PreviewSide: Sendable {
    var image: CGImage?
    var bytes: Int64
    var formatName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var estimated = false
    var note: String?

    var dimensions: String? { pixelWidth > 0 ? "\(pixelWidth) × \(pixelHeight)" : nil }
}

struct PreviewOutcome: Sendable {
    var after: PreviewSide
    var elapsed: TimeInterval
    /// Compression would not shrink the file: Forma will keep the original.
    var keepsOriginal = false
}

/// Renders previews with the real engines, into a private cache folder, then deletes the temp files.
enum PreviewRenderer {
    static let maxDisplayPixels = 8192

    static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Forma/Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func canPreview(_ kind: MediaKind) -> Bool {
        switch kind {
        case .image, .document: true
        case .video: Tool.ffmpeg.isAvailable
        case .audio, .office: false
        }
    }

    // MARK: Before

    static func original(_ url: URL, kind: MediaKind) async -> PreviewSide {
        let name = FileDetection.sameFormat(for: url)?.name ?? url.pathExtension.uppercased()
        if kind == .video {
            let p = await MediaEngine.probe(url)
            let t = max(0, p.duration * 0.4)
            let img = await videoFrame(url, at: t)
            return PreviewSide(image: img, bytes: url.fileSize, formatName: name, pixelWidth: p.width, pixelHeight: p.height)
        }
        let (w, h) = pixelSize(url)
        let img = await loadImage(url)
        return PreviewSide(image: img, bytes: url.fileSize, formatName: name,
                           pixelWidth: w > 0 ? w : img?.width ?? 0, pixelHeight: h > 0 ? h : img?.height ?? 0)
    }

    // MARK: After (live)

    static func render(input: URL, kind: MediaKind, mode: ProcessMode, snapshot: ProcessingSnapshot,
                       targetOverride: FormatDescriptor?, progress: @escaping @Sendable (Double) -> Void) async throws -> PreviewOutcome {
        let started = Date()
        let cls = FileDetection.classify(input)
        guard let format = targetOverride ?? snapshot.target(for: input, kind: kind, mode: mode) else {
            throw ToolError(mode == .compress ? "Compression non prise en charge pour ce format." : "Choisissez un format de sortie.")
        }
        let compress = mode == .compress || (mode == .convert && snapshot.compressWhileConverting)
        let dir = cacheDir

        if kind == .video {
            return try await renderVideo(input: input, format: format, mode: mode, snapshot: snapshot, compress: compress, started: started, progress: progress)
        }
        guard format.kind == .image else { throw ToolError("Aperçu disponible pour les sorties image uniquement.") }
        var settings = snapshot.image
        settings.pdfPerPage = false
        let job = ImageEngine.Job(input: input, inputClass: cls, format: format, settings: settings, mode: mode, compress: compress, near: dir)
        let produced = try await ImageEngine.process(job, progress: progress)
        defer { produced.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        guard let file = produced.first?.url, file.fileSize > 0 else { throw ToolError("L'aperçu n'a pas pu être généré.") }
        try Task.checkCancellation()

        let (w, h) = pixelSize(file)
        let img = await loadImage(file)
        let bytes = file.fileSize
        var side = PreviewSide(image: img, bytes: bytes, formatName: format.name, pixelWidth: w > 0 ? w : img?.width ?? 0, pixelHeight: h > 0 ? h : img?.height ?? 0)
        if cls == .pdf || cls == .postscript, snapshot.image.pdfPerPage { side.note = "Page 1" }
        if produced.first?.aiUpscaled == false { side.note = "Lanczos (IA indisponible)" }
        let keeps = mode == .compress && bytes >= input.fileSize && FileDetection.sameFormat(for: input) == format
        return PreviewOutcome(after: side, elapsed: Date().timeIntervalSince(started), keepsOriginal: keeps)
    }

    /// Encodes a short excerpt with the real settings and extrapolates the size to the full duration.
    private static func renderVideo(input: URL, format: FormatDescriptor, mode: ProcessMode, snapshot: ProcessingSnapshot,
                                    compress: Bool, started: Date, progress: @escaping @Sendable (Double) -> Void) async throws -> PreviewOutcome {
        let info = await MediaEngine.probe(input)
        guard info.duration > 0 else { throw ToolError("Durée de la vidéo inconnue.") }
        let full = MediaEngine.effectiveDuration(info.duration, snapshot.video)
        let fullJob = MediaEngine.Job(input: input, inputKind: .video, format: format, video: snapshot.video, audio: snapshot.audio,
                                      image: snapshot.image, mode: mode, compress: compress, near: cacheDir)

        // Remux: nothing is re-encoded, the result is the original stream.
        if MediaEngine.remuxArguments(fullJob, info: info, out: cacheDir.appendingPathComponent("x.\(format.ext)")) != nil {
            let frame = await videoFrame(input, at: (snapshot.video.trimStart ?? 0) + full * 0.4)
            var side = PreviewSide(image: frame, bytes: Int64(Double(input.fileSize) * min(1, full / info.duration)), formatName: format.name,
                                   pixelWidth: info.width, pixelHeight: info.height, estimated: true)
            side.note = "Remux instantané, qualité identique"
            return PreviewOutcome(after: side, elapsed: Date().timeIntervalSince(started))
        }

        let lo = snapshot.video.trimStart ?? 0, hi = snapshot.video.trimEnd ?? info.duration
        let length = min(4, max(0.5, hi - lo))
        let start = max(lo, min(hi - length, lo + (hi - lo) * 0.4 - length / 2))
        var excerpt = snapshot.video
        excerpt.trimStart = start
        excerpt.trimEnd = start + length
        var job = fullJob
        job.video = excerpt
        let out = try await MediaEngine.process(job, progress: progress)
        defer { try? FileManager.default.removeItem(at: out) }
        try Task.checkCancellation()

        let excerptDuration = MediaEngine.effectiveDuration(info.duration, excerpt)
        let estimate = Int64(Double(out.fileSize) * full / max(0.01, excerptDuration))
        var image: CGImage?
        var w = 0, h = 0
        if format.kind == .video || format.kind == .image {
            image = await videoFrame(out, at: excerptDuration / 2)
            w = image?.width ?? 0; h = image?.height ?? 0
        }
        var side = PreviewSide(image: image, bytes: estimate, formatName: format.name, pixelWidth: w, pixelHeight: h, estimated: true)
        side.note = "Estimé sur un extrait de \(Int(length.rounded())) s"
        return PreviewOutcome(after: side, elapsed: Date().timeIntervalSince(started))
    }

    // MARK: After (existing file)

    static func existing(_ url: URL, kind: MediaKind, formatName: String? = nil) async -> PreviewSide {
        let name = formatName ?? FileDetection.sameFormat(for: url)?.name ?? url.pathExtension.uppercased()
        if kind == .video {
            let p = await MediaEngine.probe(url)
            return PreviewSide(image: await videoFrame(url, at: p.duration * 0.4), bytes: url.fileSize, formatName: name, pixelWidth: p.width, pixelHeight: p.height)
        }
        let (w, h) = pixelSize(url)
        let img = await loadImage(url)
        return PreviewSide(image: img, bytes: url.fileSize, formatName: name, pixelWidth: w > 0 ? w : img?.width ?? 0, pixelHeight: h > 0 ? h : img?.height ?? 0)
    }

    // MARK: Loading

    static func pixelSize(_ url: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = p[kCGImagePropertyPixelWidth] as? Int, var h = p[kCGImagePropertyPixelHeight] as? Int else { return (0, 0) }
        if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        return (w, h)
    }

    /// Oriented decode, capped at 8K per side. ImageIO first, ImageMagick for exotic formats, Quick Look last.
    static func loadImage(_ url: URL) async -> CGImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(src) > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDisplayPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        }
        if Tool.magick.isAvailable {
            let tmp = cacheDir.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            if (try? await ProcessRunner.check(.magick, [url.path + "[0]", "-auto-orient", tmp.path], timeout: 60)) != nil,
               let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return img
            }
        }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 2048, height: 2048), scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).cgImage
    }

    static func videoFrame(_ url: URL, at seconds: Double) async -> CGImage? {
        guard Tool.ffmpeg.isAvailable else { return nil }
        let tmp = cacheDir.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let args = ["-hide_banner", "-nostdin", "-y", "-ss", String(format: "%.3f", max(0, seconds)), "-i", url.path,
                    "-frames:v", "1", "-f", "image2", "-c:v", "png", tmp.path]
        guard (try? await ProcessRunner.check(.ffmpeg, args, timeout: 60)) != nil else { return nil }
        guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: Difference map

    /// |after − before|, amplified ×8 so compression losses jump out (black = identical).
    static func difference(before: CGImage, after: CGImage) -> CGImage? {
        let a = CIImage(cgImage: after)
        var b = CIImage(cgImage: before)
        let sx = a.extent.width / b.extent.width, sy = a.extent.height / b.extent.height
        if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
            b = b.transformed(by: CGAffineTransform(scaleX: sx, y: sy), highQualityDownsample: true)
        }
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
        let amp: CGFloat = 8
        let boosted = diff.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amp, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amp, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amp, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: a.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(boosted, from: a.extent)
    }
}
