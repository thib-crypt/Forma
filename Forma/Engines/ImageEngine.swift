import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AppKit

/// One produced file (still in a temp location). `suffix` distinguishes pages ("-p2").
struct ProducedFile: Sendable {
    var url: URL
    var suffix: String?
    var aiUpscaled: Bool? = nil     // set by the upscale mode (false = Lanczos fallback)
    var companion: URL? = nil       // folder placed next to the result (pictures extracted from a document)
}

/// Image pipeline. Native ImageIO / CoreGraphics first (hardware-accelerated decode, downsampled thumbnails,
/// single-pass render), external encoders only where macOS can't write the format.
enum ImageEngine {

    struct Job: Sendable {
        var input: URL
        var inputClass: InputClass
        var format: FormatDescriptor
        var settings: ImageSettings
        var mode: ProcessMode
        var compress: Bool          // apply the compression preset (compress mode, or "compress while converting")
        var near: URL               // volume used for temp files
    }

    typealias Progress = @Sendable (Double) -> Void

    static func process(_ job: Job, progress: @escaping Progress) async throws -> [ProducedFile] {
        try Task.checkCancellation()
        let fmt = job.format
        if job.mode == .upscale { return [try await upscale(job, progress: progress)] }

        // ---- Documents & vector sources -------------------------------------------------
        switch job.inputClass {
        case .pdf, .postscript:
            if fmt.id == "PDF" || fmt.id == "AI" || fmt.id == "EPS" {
                return [try await DocumentEngine.rewrite(job, progress: progress)]
            }
            return try await DocumentEngine.rasterize(job, progress: progress) { page, image, props in
                try await encodeImage(image, sourceProps: props, job: job, suffix: page)
            }
        case .svg where fmt.id == "SVG":
            return [ProducedFile(url: try SVGMinifier.minify(job.input, near: job.near))]
        default: break
        }

        // ---- Animated sources → animated targets ---------------------------------------
        if job.settings.animatedFrames, ["GIF", "WEBP", "APNG"].contains(fmt.id), isAnimated(job.input) {
            return [ProducedFile(url: try await animatedPassThrough(job, progress: progress))]
        }

        // ---- Postscript-family writers -----------------------------------------------------
        if case .postscript(let device) = fmt.writer {
            let png = try await decodeToNativeImage(job).map { try writeTemp($0.image, props: $0.props, type: .png, near: job.near) }
            guard let png else { throw ToolError("Impossible de lire l'image.") }
            defer { try? FileManager.default.removeItem(at: png) }
            return [ProducedFile(url: try await DocumentEngine.imageToPostscript(png, device: device, ext: fmt.ext, near: job.near))]
        }

        // ---- Raster pipeline ----------------------------------------------------------------
        progress(0.1)
        guard let decoded = try await decodeToNativeImage(job) else {
            throw ToolError("Impossible de lire l'image. Elle est peut-être corrompue ou dans un format non pris en charge.")
        }
        try Task.checkCancellation()
        progress(0.45)
        let produced = try await encodeImage(decoded.image, sourceProps: decoded.props, job: job, suffix: nil)
        progress(0.75)
        return [try await postOptimize(produced, job: job)]
    }

    // MARK: Upscale ×2 (AI super-resolution)

    /// Full-resolution decode (oriented) → AI ×2 → colour/alpha render → high-quality encode.
    /// Resize and watermark settings are ignored here: this mode exists to enlarge.
    static func upscale(_ job: Job, progress: @escaping Progress) async throws -> ProducedFile {
        var job = job
        job.settings.resizeMode = .none
        job.settings.watermark.enabled = false
        job.compress = false
        job.settings.targetFileSizeKB = nil
        progress(0.03)

        // Decode at full size (vector/PDF/exotic sources go through the usual intermediate).
        guard let decoded = try await decodeToNativeImage(job) else {
            throw ToolError("Impossible de lire l'image. Elle est peut-être corrompue ou dans un format non pris en charge.")
        }
        try Task.checkCancellation()
        progress(0.08)
        let result = try await Upscaler.upscale2x(decoded.image) { p in progress(0.08 + p * 0.8) }
        try Task.checkCancellation()

        // Colour-space conversion / alpha flattening for the output format, at the new size.
        let target = TargetSize(canvasW: result.image.width, canvasH: result.image.height,
                                drawW: result.image.width, drawH: result.image.height, padded: false)
        let rendered = try render(result.image, settings: job.settings, format: job.format, target: target)
        var props = decoded.props
        props[kCGImagePropertyOrientation] = 1   // pixels are already upright
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, job.settings.dpi == nil {   // same print size, twice the detail
            props[kCGImagePropertyDPIWidth] = dpi * 2
            props[kCGImagePropertyDPIHeight] = (props[kCGImagePropertyDPIHeight] as? Double ?? dpi) * 2
        }
        progress(0.9)
        var produced = try await encodeImage(rendered, sourceProps: props, job: job, suffix: nil)
        produced.aiUpscaled = result.ai
        return produced
    }

    // MARK: Decode

    struct Decoded {
        var image: CGImage
        var props: [CFString: Any]
    }

    /// Decodes with downsampling + orientation in one hardware-accelerated pass.
    static func decodeToNativeImage(_ job: Job) async throws -> Decoded? {
        var url = job.input
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        // Formats ImageIO can't read: let ImageMagick produce a lossless intermediate.
        if job.inputClass == .exotic || job.inputClass == .svg || (job.inputClass == .raw && !nativeCanRead(url)) {
            let tmp = OutputResolver.tempURL(ext: "png", near: job.near)
            var args = [url.path + "[0]"]
            if job.inputClass == .svg { args = ["-background", "none", "-density", "\(max(96, job.settings.pdfDPI))", url.path] }
            args += ["-auto-orient", "PNG64:" + tmp.path]
            try await ProcessRunner.check(.magick, args, timeout: 600)
            url = tmp; cleanup = tmp
        }

        return try autoreleasepool { () throws -> Decoded? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(src) > 0 else { return nil }
            let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let swap = orientation >= 5 && job.settings.orientation == .autoFix
            let (ow, oh) = swap ? (h, w) : (w, h)

            let target = targetSize(sourceW: ow, sourceH: oh, settings: job.settings, format: job.format, compress: job.compress)
            let needsTransform = job.settings.orientation == .autoFix && orientation != 1
            let maxSide = max(target.drawW, target.drawH)
            let isDownscale = maxSide > 0 && maxSide < max(ow, oh)

            var image: CGImage?
            if isDownscale || needsTransform || job.inputClass == .raw {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: job.settings.orientation == .autoFix,
                    kCGImageSourceThumbnailMaxPixelSize: isDownscale ? maxSide : max(ow, oh, 1),
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }
            if image == nil {
                image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            guard var img = image else { return nil }
            img = try render(img, settings: job.settings, format: job.format, target: target)
            return Decoded(image: img, props: props)
        }
    }

    static func nativeCanRead(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0 && CGImageSourceGetStatus(src) == .statusComplete
    }

    static func isAnimated(_ url: URL) -> Bool {
        guard ["gif", "webp", "png", "apng"].contains(url.pathExtension.lowercased()),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    // MARK: Geometry

    struct TargetSize {
        var canvasW: Int, canvasH: Int     // final pixel size
        var drawW: Int, drawH: Int         // size of the image inside the canvas
        var padded: Bool
    }

    static func targetSize(sourceW: Int, sourceH: Int, settings s: ImageSettings, format: FormatDescriptor, compress: Bool) -> TargetSize {
        guard sourceW > 0, sourceH > 0 else { return TargetSize(canvasW: 0, canvasH: 0, drawW: 0, drawH: 0, padded: false) }
        let sw = Double(sourceW), sh = Double(sourceH)
        var w = sw, h = sh
        var padded = false
        var cw: Double? = nil, ch: Double? = nil

        func fit(_ maxW: Double, _ maxH: Double) {
            let r = min(maxW / w, maxH / h)
            if r < 1 || s.upscale { w = (w * r).rounded(); h = (h * r).rounded() }
        }
        switch s.resizeMode {
        case .none: break
        case .fit: fit(Double(s.width), Double(s.height))
        case .width:
            let r = Double(s.width) / sw
            if r < 1 || s.upscale { w = Double(s.width); h = (sh * r).rounded() }
        case .height:
            let r = Double(s.height) / sh
            if r < 1 || s.upscale { h = Double(s.height); w = (sw * r).rounded() }
        case .percent:
            let r = Double(max(1, s.percent)) / 100
            w = (sw * r).rounded(); h = (sh * r).rounded()
        case .exact:
            let r = min(Double(s.width) / sw, Double(s.height) / sh)
            w = (sw * r).rounded(); h = (sh * r).rounded()
            cw = Double(s.width); ch = Double(s.height); padded = true
        case .fill:
            w = Double(s.width); h = Double(s.height)
        }
        if compress, let m = s.preset.maxDimension { let r = min(1, Double(m) / max(w, h)); w = (w * r).rounded(); h = (h * r).rounded() }
        // Format constraints
        if format.id == "ICO" || format.id == "ICNS" {   // icons must be square
            let side = min(format.id == "ICO" ? 256 : 512, max(w, h))
            let r = side / max(w, h); w = (w * r).rounded(); h = (h * r).rounded()
            cw = side; ch = side; padded = w != h
        }
        let iw = max(1, Int(w)), ih = max(1, Int(h))
        return TargetSize(canvasW: Int(cw ?? w), canvasH: Int(ch ?? h), drawW: iw, drawH: ih, padded: padded)
    }

    // MARK: Render (single pass: resize-to-exact, color space, alpha flatten, watermark)

    static func render(_ image: CGImage, settings s: ImageSettings, format: FormatDescriptor, target: TargetSize) throws -> CGImage {
        let needsCanvas = target.padded || s.resizeMode == .fill || (target.drawW != image.width || target.drawH != image.height)
        let needsColor = s.colorSpace != .keep
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let needsFlatten = hasAlpha && !format.supportsAlpha
        let watermark = s.watermark.enabled ? WatermarkCache.image(at: s.watermark.imagePath) : nil
        guard needsCanvas || needsColor || needsFlatten || watermark != nil else { return image }

        let cw = target.canvasW > 0 ? target.canvasW : image.width
        let ch = target.canvasH > 0 ? target.canvasH : image.height
        let space: CGColorSpace = {
            if let n = s.colorSpace.cgName, let cs = CGColorSpace(name: n) { return cs }
            if let cs = image.colorSpace, cs.model == .rgb || cs.model == .monochrome { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let gray = space.model == .monochrome
        let wide = image.bitsPerComponent > 8
        let bpc = wide ? 16 : 8
        let opaque = needsFlatten || (!hasAlpha && !target.padded)
        var info: UInt32
        if gray { info = opaque ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue }
        else { info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue }
        if wide { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        if gray && !opaque { // gray+alpha contexts are limited: render RGB then let the encoder convert
            return try render(image, settings: { var c = s; c.colorSpace = .sRGB; return c }(), format: format, target: target)
        }
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: bpc, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else {
            throw ToolError("Impossible de créer le contexte graphique.")
        }
        ctx.setRenderingIntent(s.renderingIntent.cg)
        ctx.interpolationQuality = .high
        if needsFlatten || target.padded {
            let bg = NSColor(hex: s.backgroundHex) ?? .white
            ctx.setFillColor((target.padded && !needsFlatten && format.supportsAlpha) ? CGColor.clear : bg.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        }
        let dw = s.resizeMode == .fill ? cw : target.drawW
        let dh = s.resizeMode == .fill ? ch : target.drawH
        let rect = CGRect(x: (cw - dw) / 2, y: (ch - dh) / 2, width: dw, height: dh)
        ctx.draw(image, in: rect)
        if let watermark { drawWatermark(watermark, in: ctx, size: CGSize(width: cw, height: ch), settings: s.watermark) }
        guard let out = ctx.makeImage() else { throw ToolError("Le rendu de l'image a échoué.") }
        return out
    }

    static func drawWatermark(_ wm: CGImage, in ctx: CGContext, size: CGSize, settings w: WatermarkSettings) {
        let ww = max(8, size.width * w.relativeSize)
        let wh = ww * CGFloat(wm.height) / CGFloat(max(1, wm.width))
        let m = min(size.width, size.height) * w.margin
        ctx.saveGState()
        ctx.setAlpha(w.opacity)
        if w.position == .tiled {
            var y: CGFloat = m
            while y < size.height {
                var x: CGFloat = m
                while x < size.width { ctx.draw(wm, in: CGRect(x: x, y: y, width: ww, height: wh)); x += ww * 2 }
                y += wh * 2.5
            }
        } else {
            let x: CGFloat, y: CGFloat
            switch w.position {
            case .topLeft, .left, .bottomLeft: x = m
            case .top, .center, .bottom: x = (size.width - ww) / 2
            default: x = size.width - ww - m
            }
            switch w.position {   // CG origin is bottom-left
            case .topLeft, .top, .topRight: y = size.height - wh - m
            case .left, .center, .right: y = (size.height - wh) / 2
            default: y = m
            }
            ctx.draw(wm, in: CGRect(x: x, y: y, width: ww, height: wh))
        }
        ctx.restoreGState()
    }

    // MARK: Metadata

    static func outputProperties(source: [CFString: Any], settings s: ImageSettings, quality: Int?, lossless: Bool) -> [CFString: Any] {
        var p: [CFString: Any] = [:]
        switch s.metadata {
        case .keepAll:
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary] {
                if let v = source[key] { p[key] = v }
            }
        case .keepEssential:
            if let exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                let keep = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifLensModel,
                            kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureTime, kCGImagePropertyExifISOSpeedRatings,
                            kCGImagePropertyExifFocalLength, kCGImagePropertyExifOffsetTimeOriginal]
                p[kCGImagePropertyExifDictionary] = exif.filter { keep.contains($0.key) }
            }
            if let tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let keep = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFCopyright,
                            kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFDateTime]
                p[kCGImagePropertyTIFFDictionary] = tiff.filter { keep.contains($0.key) }
            }
        case .stripAll: break
        }
        if s.orientation == .keepTag, let o = source[kCGImagePropertyOrientation] { p[kCGImagePropertyOrientation] = o }
        else { p[kCGImagePropertyOrientation] = 1
            if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; p[kCGImagePropertyTIFFDictionary] = tiff }
        }
        if let dpi = s.dpi { p[kCGImagePropertyDPIWidth] = dpi; p[kCGImagePropertyDPIHeight] = dpi }
        else if s.metadata != .stripAll { p[kCGImagePropertyDPIWidth] = source[kCGImagePropertyDPIWidth]; p[kCGImagePropertyDPIHeight] = source[kCGImagePropertyDPIHeight] }
        if s.copyrightEnabled {
            var tiff = (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            var iptc = (p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            if !s.copyright.isEmpty { tiff[kCGImagePropertyTIFFCopyright] = s.copyright; iptc[kCGImagePropertyIPTCCopyrightNotice] = s.copyright }
            if !s.artist.isEmpty { tiff[kCGImagePropertyTIFFArtist] = s.artist; iptc[kCGImagePropertyIPTCByline] = [s.artist] }
            p[kCGImagePropertyTIFFDictionary] = tiff; p[kCGImagePropertyIPTCDictionary] = iptc
        }
        if let q = quality, !lossless { p[kCGImageDestinationLossyCompressionQuality] = Double(q) / 100 }
        if lossless { p[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        return p
    }

    // MARK: Encode

    static func effectiveQuality(_ job: Job) -> Int {
        if job.mode == .upscale { return max(job.settings.quality(), 95) }
        return job.compress ? job.settings.quality() : max(job.settings.quality(), 90)
    }

    /// Encodes a CGImage into the job's output format. Native writers run inline; external
    /// encoders are awaited (never blocking a cooperative thread).
    static func encodeImage(_ image: CGImage, sourceProps: [CFString: Any], job: Job, suffix: String?) async throws -> ProducedFile {
        let fmt = job.format
        let q = effectiveQuality(job)
        switch fmt.writer {
        case .native(let type):
            let out = OutputResolver.tempURL(ext: fmt.ext, near: job.near)
            if let target = job.settings.targetFileSizeKB, job.compress, ["public.jpeg", "public.heic", "public.avif", "public.jpeg-2000"].contains(type) {
                try encodeToTargetSize(image, props: sourceProps, settings: job.settings, type: type, bytes: target * 1024, out: out)
            } else if type == "com.microsoft.ico" || type == "com.apple.icns" {
                try writeIconFamily(image, type: type, to: out)
            } else {
                let lossless = !job.compress && ["public.tiff", "public.png"].contains(type)
                var props = outputProperties(source: sourceProps, settings: job.settings, quality: q, lossless: lossless)
                if type == "public.jpeg" && job.settings.progressiveJPEG { props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
                if type == "public.tiff" && job.compress { props[kCGImagePropertyTIFFDictionary] = mergeDict(props[kCGImagePropertyTIFFDictionary], [kCGImagePropertyTIFFCompression: 5]) } // LZW
                if type == "public.png", job.compress { props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: 5] }
                try writeNative(image, props: props, type: type, to: out)
            }
            return ProducedFile(url: out, suffix: suffix)

        case .nativePDF:
            let out = OutputResolver.tempURL(ext: "pdf", near: job.near)
            try writePDF([image], dpi: job.settings.dpi ?? 72, quality: q, to: out)
            return ProducedFile(url: out, suffix: suffix)

        case .animated(let kind) where kind == "gif":
            let out = OutputResolver.tempURL(ext: "gif", near: job.near)
            try writeNative(image, props: outputProperties(source: sourceProps, settings: job.settings, quality: nil, lossless: true), type: UTType.gif.identifier, to: out)
            return ProducedFile(url: out, suffix: suffix)

        case .animated:  // APNG from a still image = PNG
            let out = OutputResolver.tempURL(ext: "png", near: job.near)
            try writeNative(image, props: outputProperties(source: sourceProps, settings: job.settings, quality: nil, lossless: true), type: UTType.png.identifier, to: out)
            return ProducedFile(url: out, suffix: suffix)

        case .webp:
            let tiff = try writeTemp(image, props: sourceProps.isEmpty ? [:] : outputProperties(source: sourceProps, settings: job.settings, quality: nil, lossless: true), type: .tiff, near: job.near)
            defer { try? FileManager.default.removeItem(at: tiff) }
            let out = OutputResolver.tempURL(ext: "webp", near: job.near)
            if Tool.cwebp.isAvailable {
                var args = ["-quiet", "-mt", "-m", "\(min(6, max(0, job.settings.effort - 3)))", "-metadata", job.settings.metadata == .stripAll ? "none" : "all"]
                if let t = job.settings.targetFileSizeKB, job.compress { args += ["-size", "\(t * 1024)", "-pass", "6"] }
                else if !job.compress && q >= 100 { args += ["-lossless"] }
                else { args += ["-q", "\(q)", "-alpha_q", "\(min(100, q + 10))", "-sharp_yuv"] }
                args += [tiff.path, "-o", out.path]
                try await ProcessRunner.check(.cwebp, args)
            } else {
                try await ProcessRunner.check(.magick, [tiff.path, "-quality", "\(q)", "-define", "webp:method=\(min(6, job.settings.effort))", "WEBP:" + out.path])
            }
            return ProducedFile(url: out, suffix: suffix)

        case .jxl:
            let out = OutputResolver.tempURL(ext: "jxl", near: job.near)
            // Lossless JPEG → JXL transcoding (~20 % smaller, bit-exact) when nothing alters the pixels.
            let untouched = job.settings.resizeMode == .none && !job.settings.watermark.enabled && job.settings.colorSpace == .keep && !job.compress
            if Tool.cjxl.isAvailable, untouched, ["jpg", "jpeg"].contains(job.input.pathExtension.lowercased()) {
                try await ProcessRunner.check(.cjxl, [job.input.path, out.path, "--lossless_jpeg=1", "-e", "\(min(9, job.settings.effort))", "--quiet"])
                return ProducedFile(url: out, suffix: suffix)
            }
            let png = try writeTemp(image, props: outputProperties(source: sourceProps, settings: job.settings, quality: nil, lossless: true), type: .png, near: job.near)
            defer { try? FileManager.default.removeItem(at: png) }
            if Tool.cjxl.isAvailable {
                try await ProcessRunner.check(.cjxl, [png.path, out.path, "-q", "\(q)", "-e", "\(min(9, job.settings.effort))", "--quiet"])
            } else {
                try await ProcessRunner.check(.magick, [png.path, "-quality", "\(q)", "JXL:" + out.path])
            }
            return ProducedFile(url: out, suffix: suffix)

        case .magick("SVG"):
            let out = OutputResolver.tempURL(ext: "svg", near: job.near)
            try writeEmbeddedSVG(image, quality: q, to: out)
            return ProducedFile(url: out, suffix: suffix)

        case .magick(let coder):
            let tiff = try writeTemp(image, props: outputProperties(source: sourceProps, settings: job.settings, quality: nil, lossless: true), type: .tiff, near: job.near)
            defer { try? FileManager.default.removeItem(at: tiff) }
            let out = OutputResolver.tempURL(ext: fmt.ext, near: job.near)
            var args = [tiff.path]
            if job.settings.metadata == .stripAll { args += ["-strip"] }
            if fmt.supportsQuality { args += ["-quality", "\(q)"] }
            if ["PBM", "XBM", "WBMP", "FAX"].contains(fmt.id) { args += ["-threshold", "50%"] }
            if fmt.id == "PTIF" { args += ["-define", "tiff:tile-geometry=256x256"] }
            args += ["\(coder):\(out.path)"]
            try await ProcessRunner.check(.magick, args, timeout: 900)
            return ProducedFile(url: out, suffix: suffix)

        case .postscript(let device):
            let png = try writeTemp(image, props: [:], type: .png, near: job.near)
            defer { try? FileManager.default.removeItem(at: png) }
            let out = try await DocumentEngine.imageToPostscript(png, device: device, ext: fmt.ext, near: job.near)
            return ProducedFile(url: out, suffix: suffix)

        case .audio, .video, .office:
            throw ToolError("Format de sortie incompatible avec une image.")
        }
    }

    static func mergeDict(_ a: Any?, _ b: [CFString: Any]) -> [CFString: Any] {
        var d = (a as? [CFString: Any]) ?? [:]
        b.forEach { d[$0] = $1 }
        return d
    }

    static func writeNative(_ image: CGImage, props: [CFString: Any], type: String, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ToolError("macOS ne sait pas écrire ce format.")
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("L'encodage de l'image a échoué.") }
    }

    /// Multi-resolution .ico / .icns from a square image.
    static func writeIconFamily(_ image: CGImage, type: String, to url: URL) throws {
        let sizes = (type == "com.microsoft.ico" ? [16, 32, 48, 64, 128, 256] : [16, 32, 64, 128, 256, 512]).filter { $0 <= image.width }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, max(1, sizes.count), nil) else {
            throw ToolError("macOS ne sait pas écrire ce format.")
        }
        for side in sizes.isEmpty ? [image.width] : sizes {
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            if let img = ctx.makeImage() { CGImageDestinationAddImage(dest, img, nil) }
        }
        guard CGImageDestinationFinalize(dest) else { throw ToolError("L'encodage de l'icône a échoué.") }
    }

    /// Raster → SVG: the image is embedded (JPEG when opaque, PNG otherwise) in a minimal SVG wrapper.
    static func writeEmbeddedSVG(_ image: CGImage, quality: Int, to url: URL) throws {
        let opaque = [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        let type = opaque ? UTType.jpeg.identifier : UTType.png.identifier
        guard let data = encodeData(image, props: [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100], type: type) else {
            throw ToolError("L'encodage SVG a échoué.")
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(image.width)" height="\(image.height)" viewBox="0 0 \(image.width) \(image.height)"><image width="\(image.width)" height="\(image.height)" xlink:href="data:\(opaque ? "image/jpeg" : "image/png");base64,\(data.base64EncodedString())"/></svg>
        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    static func encodeData(_ image: CGImage, props: [CFString: Any], type: String) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func writeTemp(_ image: CGImage, props: [CFString: Any], type: UTType, near: URL) throws -> URL {
        let url = OutputResolver.tempURL(ext: type.preferredFilenameExtension ?? "tiff", near: near)
        var p = props
        if type == .tiff { p[kCGImagePropertyTIFFDictionary] = mergeDict(p[kCGImagePropertyTIFFDictionary], [kCGImagePropertyTIFFCompression: 1]) }
        try writeNative(image, props: p, type: type.identifier, to: url)
        return url
    }

    /// Binary search on quality (in memory), then progressive downscale if even the lowest quality is too big.
    static func encodeToTargetSize(_ image: CGImage, props source: [CFString: Any], settings: ImageSettings, type: String, bytes: Int, out: URL) throws {
        var img = image
        for _ in 0..<6 {
            var lo = 5, hi = 95
            var best: Data?
            while lo <= hi {
                let mid = (lo + hi) / 2
                guard let d = encodeData(img, props: outputProperties(source: source, settings: settings, quality: mid, lossless: false), type: type) else { break }
                if d.count <= bytes { best = d; lo = mid + 1 } else { hi = mid - 1 }
            }
            if let best { try best.write(to: out, options: .atomic); return }
            // Too big even at minimum quality: shrink by 15 % and retry.
            let w = Int(Double(img.width) * 0.85), h = Int(Double(img.height) * 0.85)
            guard w > 16, h > 16,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { break }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let smaller = ctx.makeImage() else { break }
            img = smaller
        }
        try writeNative(img, props: outputProperties(source: source, settings: settings, quality: 5, lossless: false), type: type, to: out)
    }

    static func writePDF(_ images: [CGImage], dpi: Int, quality: Int, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw ToolError("Impossible de créer le PDF.") }
        var box = CGRect.zero
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ToolError("Impossible de créer le PDF.") }
        for img in images {
            let scale = 72.0 / Double(max(1, dpi))
            var page = CGRect(x: 0, y: 0, width: Double(img.width) * scale, height: Double(img.height) * scale)
            ctx.beginPage(mediaBox: &page)
            // JPEG-encode photos inside the PDF to keep it small.
            if let d = encodeData(img, props: [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100], type: UTType.jpeg.identifier),
               img.alphaInfo == .none || img.alphaInfo == .noneSkipLast || img.alphaInfo == .noneSkipFirst,
               let provider = CGDataProvider(data: d as CFData),
               let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                ctx.draw(jpeg, in: page)
            } else {
                ctx.draw(img, in: page)
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: Post-optimizers (pngquant / oxipng / MozJPEG jpegtran / gifsicle)

    static func postOptimize(_ file: ProducedFile, job: Job) async throws -> ProducedFile {
        guard job.compress else { return file }
        let url = file.url
        switch job.format.id {
        case "PNG":
            if job.settings.lossyPNG, job.settings.quality() < 95, Tool.pngquant.isAvailable {
                let q = job.settings.quality()
                let r = try await ProcessRunner.run(Tool.pngquant.path!, ["--quality=\(max(0, q - 20))-\(q)", "--speed", "3", "--force",
                                                                         "--skip-if-larger", "--ext", ".png", job.settings.metadata == .stripAll ? "--strip" : "--force", "--", url.path])
                _ = r // 98/99 = quality too low / larger: keep the lossless file
            }
            if Tool.oxipng.isAvailable {
                var args = ["-o", "3", "-q", "--fast"]
                args += job.settings.metadata == .stripAll ? ["--strip", "all"] : ["--strip", "safe"]
                try? await ProcessRunner.check(.oxipng, args + [url.path], timeout: 300)
            } else if Tool.magick.isAvailable && !Tool.pngquant.isAvailable {
                let tmp = OutputResolver.tempURL(ext: "png", near: job.near)
                if (try? await ProcessRunner.check(.magick, [url.path, "-define", "png:compression-level=9", "-define", "png:compression-filter=5", "PNG:" + tmp.path])) != nil,
                   tmp.fileSize > 0, tmp.fileSize < url.fileSize {
                    _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
                } else { try? FileManager.default.removeItem(at: tmp) }
            }
        case "JPEG":
            if job.settings.useMozJPEG, let cjpeg = Tool.mozjpeg.path {
                let jpegtran = URL(fileURLWithPath: cjpeg).deletingLastPathComponent().appendingPathComponent("jpegtran").path
                let tmp = OutputResolver.tempURL(ext: "jpg", near: job.near)
                let r = try await ProcessRunner.run(jpegtran, ["-copy", job.settings.metadata == .stripAll ? "none" : "all", "-optimize",
                                                               job.settings.progressiveJPEG ? "-progressive" : "-optimize", "-outfile", tmp.path, url.path])
                if r.status == 0, tmp.fileSize > 0, tmp.fileSize < url.fileSize { _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp) }
                else { try? FileManager.default.removeItem(at: tmp) }
            }
        case "GIF":
            if Tool.gifsicle.isAvailable {
                try? await ProcessRunner.check(.gifsicle, ["-O3", "--lossy=\(max(0, 100 - job.settings.quality()) * 2)", "-b", url.path])
            }
        default: break
        }
        return file
    }

    // MARK: Animated GIF / WebP / APNG

    static func animatedPassThrough(_ job: Job, progress: @escaping Progress) async throws -> URL {
        let out = OutputResolver.tempURL(ext: job.format.ext, near: job.near)
        let q = effectiveQuality(job)
        let inExt = job.input.pathExtension.lowercased()
        if job.format.id == "GIF", inExt == "gif", Tool.gifsicle.isAvailable {
            var args = ["-O3", "--lossy=\(max(0, 100 - q) * 2)"]
            if job.settings.resizeMode == .fit || job.settings.resizeMode == .width {
                args += ["--resize-fit", "\(job.settings.width)x\(job.settings.resizeMode == .fit ? job.settings.height : 100000)"]
            }
            if job.compress && q < 70 { args += ["--colors", "128"] }
            args += [job.input.path, "-o", out.path]
            try await ProcessRunner.check(.gifsicle, args)
            return out
        }
        if job.format.id == "WEBP", inExt == "gif", job.settings.resizeMode == .none, Tool.gif2webp.isAvailable {
            try await ProcessRunner.check(.gif2webp, ["-q", "\(q)", "-m", "4", "-mt", "-mixed", "-quiet", job.input.path, "-o", out.path])
            return out
        }
        // ffmpeg handles every animated combination with high quality palettes.
        let filters = MediaEngine.scaleFilter(width: job.settings.resizeMode == .none ? nil : job.settings.width)
        var args = ["-hide_banner", "-y", "-i", job.input.path]
        switch job.format.id {
        case "GIF":
            args += ["-filter_complex", "\(filters)split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a", "-loop", "0"]
        case "WEBP":
            args += ["-vf", String(filters.dropLast()), "-c:v", "libwebp_anim", "-quality", "\(q)", "-loop", "0", "-compression_level", "4"]
        default:
            args += ["-vf", String(filters.dropLast()), "-f", "apng", "-plays", "0"]
        }
        if filters.isEmpty, job.format.id != "GIF" { args.removeAll { $0 == "-vf" || $0 == "" } }
        args += [out.path]
        progress(0.3)
        try await ProcessRunner.check(.ffmpeg, args)
        return out
    }

}

// MARK: - Helpers

enum WatermarkCache {
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()
    static func image(at path: String?) -> CGImage? {
        guard let path else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[path] { return c }
        let url = URL(fileURLWithPath: path)
        var img: CGImage?
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) { img = CGImageSourceCreateImageAtIndex(src, 0, nil) }
        if img == nil, let ns = NSImage(contentsOf: url) { img = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if let img { cache[path] = img }
        return img
    }
}

enum SVGMinifier {
    /// Lightweight SVG optimisation: strips comments, metadata, editor namespaces and redundant whitespace.
    static func minify(_ url: URL, near: URL) throws -> URL {
        var s = try String(contentsOf: url, encoding: .utf8)
        let patterns = [
            #"<!--[\s\S]*?-->"#, #"<metadata[\s\S]*?</metadata>"#, #"<sodipodi:namedview[\s\S]*?(/>|</sodipodi:namedview>)"#,
            #"\s(inkscape|sodipodi|sketch|serif|xmlns:(inkscape|sodipodi|sketch|serif|dc|cc|rdf))(:[a-zA-Z-]+)?="[^"]*""#,
            #"<\?xml[^>]*\?>"#, #"<!DOCTYPE[^>]*>"#,
        ]
        for p in patterns { s = s.replacingOccurrences(of: p, with: "", options: .regularExpression) }
        s = s.replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // Round long decimals: 12.3456789 → 12.346
        s = s.replacingOccurrences(of: #"(\d+\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let out = OutputResolver.tempURL(ext: "svg", near: near)
        try s.trimmingCharacters(in: .whitespacesAndNewlines).write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
