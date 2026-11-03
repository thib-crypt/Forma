import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import VideoToolbox

/// AI super-resolution ×2 built on Apple's on-device model (VideoToolbox `VTFrameProcessor`, Neural Engine + GPU).
///
/// The system model only runs at ×4 on Apple silicon and accepts at most 1920 px per side, so the image is
/// processed in overlapping tiles at ×4, each tile is reduced to ×2 with a Lanczos filter (supersampling: sharper
/// and cleaner than a native ×2), and only the centre of every tile is kept so no seam is visible.
enum Upscaler {
    static let modelScale = 4
    /// Model limit is 1920 px per side; smaller tiles on Macs with little memory (output tile is 16× larger, half-float).
    static let tileSide = ProcessInfo.processInfo.physicalMemory >= 15 << 30 ? 1920 : 1280
    static let margin = 32              // input px of context discarded on each inner tile edge
    static let maxInputPixels = 50_000_000

    enum ModelState: Equatable { case unsupported, needsDownload, downloading(Double), ready }

    /// Serialises access: the Neural Engine is shared, parallel sessions only add memory pressure.
    private static let limiter = AsyncLimiter(1)

    static var isSupported: Bool { VTSuperResolutionScalerConfiguration.isSupported }

    private static func configuration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: modelScale,
                                             inputType: .image, usePrecomputedFlow: false,
                                             qualityPrioritization: .normal, revision: .revision1)
    }

    static var modelState: ModelState {
        guard isSupported, let c = configuration(width: tileSide, height: tileSide) else { return .unsupported }
        switch c.configurationModelStatus {
        case .ready: return .ready
        case .downloading: return .downloading(Double(c.configurationModelPercentageAvailable))
        default: return .needsDownload
        }
    }

    /// Downloads Apple's super-resolution model (system asset, done once).
    static func prepareModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard isSupported, let c = configuration(width: tileSide, height: tileSide) else {
            throw ToolError("La super-résolution IA n'est pas disponible sur ce Mac.")
        }
        if c.configurationModelStatus == .ready { return }
        let poll = Task {
            while !Task.isCancelled {
                progress?(Double(c.configurationModelPercentageAvailable))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poll.cancel() }
        let error: Error? = await withCheckedContinuation { cont in
            c.downloadConfigurationModel { cont.resume(returning: $0) }
        }
        // The callback can report a benign error when another process finished the download first.
        if c.configurationModelStatus != .ready {
            throw ToolError("Téléchargement du modèle IA impossible\(error.map { " : \($0.localizedDescription)" } ?? ".")")
        }
        progress?(1)
    }

    /// Returns the image enlarged ×2. Falls back to Lanczos when the AI model is unavailable.
    static func upscale2x(_ image: CGImage, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (image: CGImage, ai: Bool) {
        guard image.width * image.height <= maxInputPixels else {
            throw ToolError("Image trop grande pour l'agrandissement (max. 50 Mpx).")
        }
        if isSupported {
            if modelState != .ready { try await prepareModel() }
            let result: Result<CGImage, Error> = await limiter.run {
                do { return .success(try await aiUpscale(image, progress: progress)) }
                catch { return .failure(error) }
            }
            return (try result.get(), true)
        }
        return (try lanczos2x(image), false)
    }

    // MARK: - AI path

    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false,
                                                       .workingFormat: CIFormat.RGBAh])

    private static func aiUpscale(_ image: CGImage, progress: (@Sendable (Double) -> Void)?) async throws -> CGImage {
        let W = image.width, H = image.height
        let space = workingSpace(for: image)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)

        let tw = tileLength(for: W), th = tileLength(for: H)
        guard let config = configuration(width: tw, height: th) else { throw ToolError("Configuration IA refusée.") }
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }

        let srcPool = try makePool(config.sourcePixelBufferAttributes)
        let dstPool = try makePool(config.destinationPixelBufferAttributes)

        // Source, alpha removed (the model works on colour), clamped so edge tiles see repeated pixels, not black.
        let source = CIImage(cgImage: image, options: [.colorSpace: space])
        let opaque = (hasAlpha ? source.unpremultiplyingAlpha().settingAlphaOne(in: source.extent) : source)
            .clampedToExtent()

        // Output bitmap at ×2.
        let OW = W * 2, OH = H * 2
        let wide = image.bitsPerComponent > 8
        var info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        if wide { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let out = CGContext(data: nil, width: OW, height: OH, bitsPerComponent: wide ? 16 : 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else {
            throw ToolError("Mémoire insuffisante pour l'image agrandie.")
        }
        out.interpolationQuality = .none
        out.setBlendMode(.copy)

        let xs = tiles(length: W, tile: tw), ys = tiles(length: H, tile: th)
        let total = Double(xs.count * ys.count)
        var done = 0.0

        for ty in ys {
            for tx in xs {
                try Task.checkCancellation()
                guard let src = buffer(from: srcPool), let dst = buffer(from: dstPool) else {
                    throw ToolError("Mémoire insuffisante (tampons IA).")
                }
                // 1. Fill the source tile and run the model.
                autoreleasepool {
                    let crop = opaque.transformed(by: CGAffineTransform(translationX: -CGFloat(tx.origin), y: -CGFloat(ty.origin)))
                        .cropped(to: CGRect(x: 0, y: 0, width: tw, height: th))
                    ciContext.render(crop, to: src, bounds: CGRect(x: 0, y: 0, width: tw, height: th), colorSpace: space)
                }
                try await runModel(processor, src: src, dst: dst)

                // 2. ×4 → ×2 with Lanczos, keep only the tile core.
                try autoreleasepool {
                    let up = CIImage(cvPixelBuffer: dst, options: [.colorSpace: space])
                        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1.0])
                    let core = CGRect(x: (tx.keep.lowerBound - tx.origin) * 2, y: (ty.keep.lowerBound - ty.origin) * 2,
                                      width: tx.keep.count * 2, height: ty.keep.count * 2)
                    guard let piece = ciContext.createCGImage(up, from: core, format: wide ? .RGBA16 : .RGBA8, colorSpace: space) else {
                        throw ToolError("Le rendu d'une tuile a échoué.")
                    }
                    out.draw(piece, in: CGRect(x: tx.keep.lowerBound * 2, y: ty.keep.lowerBound * 2,
                                               width: tx.keep.count * 2, height: ty.keep.count * 2))
                }
                done += 1
                progress?(done / total)
            }
        }

        // Alpha: enlarged separately with Lanczos, then applied to the AI colour.
        if hasAlpha, let rgb = out.makeImage() {
            let alpha = source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2.0, kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: OW, height: OH))
            let combined = CIImage(cgImage: rgb, options: [.colorSpace: space])
                .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                       kCIInputMaskImageKey: alpha])
            guard let result = ciContext.createCGImage(combined, from: CGRect(x: 0, y: 0, width: OW, height: OH),
                                                       format: wide ? .RGBA16 : .RGBA8, colorSpace: space) else {
                throw ToolError("La fusion de la transparence a échoué.")
            }
            return result
        }
        guard let result = out.makeImage() else { throw ToolError("Le rendu de l'image agrandie a échoué.") }
        return result
    }

    private static func runModel(_ processor: VTFrameProcessor, src: CVPixelBuffer, dst: CVPixelBuffer) async throws {
        guard let s = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: .zero),
              let d = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: .zero),
              let params = VTSuperResolutionScalerParameters(sourceFrame: s, previousFrame: nil, previousOutputFrame: nil,
                                                             opticalFlow: nil, submissionMode: .random, destinationFrame: d) else {
            throw ToolError("Paramètres IA invalides.")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            processor.process(parameters: params) { _, error in
                if let error { cont.resume(throwing: ToolError("Super-résolution : \(error.localizedDescription)")) }
                else { cont.resume() }
            }
        }
    }

    /// Tile placement along one axis. Tiles extend `margin` px beyond the image (clamped pixels) so the model never
    /// sees a hard border, and the `keep` ranges partition [0, length) exactly — every kept pixel has ≥ margin of context.
    struct Span { var origin: Int; var keep: Range<Int> }

    /// Smallest number of tiles the model limit allows, then the smallest tile that covers them evenly.
    static func tileLength(for length: Int) -> Int {
        let n = max(1, Int((Double(length) / Double(tileSide - 2 * margin)).rounded(.up)))
        let t = Int((Double(length) / Double(n)).rounded(.up)) + 2 * margin
        return min(tileSide, max(64, (t + 15) / 16 * 16))
    }

    static func tiles(length: Int, tile: Int) -> [Span] {
        let inner = tile - 2 * margin
        let n = max(1, Int((Double(length) / Double(inner)).rounded(.up)))
        let step = Double(length) / Double(n)
        return (0..<n).map { i in
            let a = Int((Double(i) * step).rounded()), b = i == n - 1 ? length : Int((Double(i + 1) * step).rounded())
            let origin = min(max(-margin, (a + b) / 2 - tile / 2), length + margin - tile)
            return Span(origin: origin, keep: a..<b)
        }
    }

    // MARK: - Helpers

    private static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private static func makePool(_ attrs: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 1] as CFDictionary, attrs as CFDictionary, &pool)
        guard let pool else { throw ToolError("Impossible d'allouer les tampons IA.") }
        return pool
    }

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b)
        return b
    }

    /// Non-AI fallback (Intel Macs): Lanczos ×2 + light unsharp mask.
    static func lanczos2x(_ image: CGImage) throws -> CGImage {
        let space = workingSpace(for: image)
        let ci = CIImage(cgImage: image, options: [.colorSpace: space])
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2.0, kCIInputAspectRatioKey: 1.0])
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.2, kCIInputIntensityKey: 0.35])
        let rect = CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2)
        guard let out = ciContext.createCGImage(ci.cropped(to: rect), from: rect,
                                                format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8, colorSpace: space) else {
            throw ToolError("L'agrandissement a échoué.")
        }
        return out
    }
}
