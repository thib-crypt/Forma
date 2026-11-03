import Foundation
import CoreGraphics
import ImageIO

/// PDF / EPS / Illustrator handling: CoreGraphics renders PDF pages natively, Ghostscript handles
/// PostScript and PDF recompression.
enum DocumentEngine {

    // MARK: PDF compression & document ↔ document

    static func rewrite(_ job: ImageEngine.Job, progress: @escaping ImageEngine.Progress) async throws -> ProducedFile {
        let out = OutputResolver.tempURL(ext: job.format.ext, near: job.near)
        let inExt = job.input.pathExtension.lowercased()
        progress(0.15)

        if job.format.id == "PDF" || job.format.id == "AI" {
            // Same-format PDF compression, or EPS/AI → PDF (vector preserved).
            guard Tool.gs.isAvailable else {
                if inExt == "pdf" || inExt == "ai" { try FileManager.default.copyItem(at: job.input, to: out); return ProducedFile(url: out) }
                throw ToolError("Ghostscript est nécessaire (`brew install ghostscript`).")
            }
            var args = ["-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6",
                        "-dDetectDuplicateImages=true", "-dCompressFonts=true", "-dSubsetFonts=true"]
            if job.compress {
                let q = job.settings.quality()
                let (preset, dpi): (String, Int) = q >= 90 ? ("/prepress", 300) : q >= 80 ? ("/printer", 220) : q >= 65 ? ("/ebook", 150) : ("/screen", 96)
                args += ["-dPDFSETTINGS=\(preset)", "-dColorImageResolution=\(dpi)", "-dGrayImageResolution=\(dpi)",
                         "-dDownsampleColorImages=true", "-dDownsampleGrayImages=true", "-dColorImageDownsampleThreshold=1.1",
                         "-dJPEGQ=\(q)"]
            }
            if ["eps", "ps", "epsf", "epsi"].contains(inExt) { args += ["-dEPSCrop"] }
            args += ["-sOutputFile=\(out.path)", job.input.path]
            try await ProcessRunner.check(.gs, args, timeout: 900)
            return ProducedFile(url: out)
        }

        // PDF / AI → EPS (first page)
        try await ProcessRunner.check(.gs, ["-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=eps2write", "-dFirstPage=1", "-dLastPage=1",
                                           "-sOutputFile=\(out.path)", job.input.path], timeout: 600)
        return ProducedFile(url: out)
    }

    // MARK: PDF / EPS / AI → raster

    static func rasterize(_ job: ImageEngine.Job, progress: @escaping ImageEngine.Progress,
                          encode: (String?, CGImage, [CFString: Any]) async throws -> ProducedFile) async throws -> [ProducedFile] {
        var pdfURL = job.input
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        var doc = CGPDFDocument(job.input as CFURL)
        if doc == nil || job.inputClass == .postscript && (doc?.numberOfPages ?? 0) == 0 {
            // EPS / legacy AI: Ghostscript → PDF first (vector preserved), then native rendering.
            let tmp = OutputResolver.tempURL(ext: "pdf", near: job.near)
            try await ProcessRunner.check(.gs, ["-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-dEPSCrop",
                                               "-sOutputFile=\(tmp.path)", job.input.path], timeout: 600)
            pdfURL = tmp; cleanup = tmp
            doc = CGPDFDocument(pdfURL as CFURL)
        }
        guard let doc else { throw ToolError("Impossible d'ouvrir le PDF.") }
        if doc.isEncrypted && !doc.isUnlocked { throw ToolError("Ce PDF est protégé par mot de passe. Déverrouillez-le d'abord.") }

        let count = doc.numberOfPages
        let pages = job.settings.pdfPerPage ? Array(1...max(1, count)) : [1]
        var results: [ProducedFile] = []
        for (i, n) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = doc.page(at: n) else { continue }
            let img = try renderPage(page, dpi: Double(job.settings.pdfDPI), transparent: job.format.supportsAlpha)
            let suffix = pages.count > 1 ? "-p\(n)" : nil
            let rendered = try ImageEngine.render(img, settings: job.settings, format: job.format,
                                                  target: ImageEngine.targetSize(sourceW: img.width, sourceH: img.height, settings: job.settings, format: job.format, compress: job.compress))
            let props: [CFString: Any] = [kCGImagePropertyDPIWidth: job.settings.pdfDPI, kCGImagePropertyDPIHeight: job.settings.pdfDPI]
            results.append(try await encode(suffix, rendered, props))
            progress(Double(i + 1) / Double(pages.count))
        }
        return results
    }

    static func renderPage(_ page: CGPDFPage, dpi: Double, transparent: Bool) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let rotation = page.rotationAngle % 360
        let swap = rotation == 90 || rotation == 270
        let scale = dpi / 72.0
        var w = Int((swap ? box.height : box.width) * scale), h = Int((swap ? box.width : box.height) * scale)
        // Guard against absurd page sizes (posters at 600 dpi): cap at 16k px.
        let cap = 16_000.0
        let f = min(1, cap / Double(max(w, h)))
        w = max(1, Int(Double(w) * f)); h = max(1, Int(Double(h) * f))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)
        else { throw ToolError("Mémoire insuffisante pour rendre cette page.") }
        if !transparent { ctx.setFillColor(CGColor.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.perceptual)
        let t = page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(t)
        ctx.drawPDFPage(page)
        guard let img = ctx.makeImage() else { throw ToolError("Le rendu de la page a échoué.") }
        return img
    }

    // MARK: raster → EPS / AI

    static func imageToPostscript(_ png: URL, device: String, ext: String, near: URL) async throws -> URL {
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ToolError("Impossible de lire l'image.")
        }
        let pdf = OutputResolver.tempURL(ext: "pdf", near: near)
        try ImageEngine.writePDF([img], dpi: 72, quality: 92, to: pdf)
        if device == "pdfwrite" { // AI = PDF-compatible Illustrator file
            let out = OutputResolver.tempURL(ext: ext, near: near)
            try FileManager.default.moveItem(at: pdf, to: out)
            return out
        }
        defer { try? FileManager.default.removeItem(at: pdf) }
        let out = OutputResolver.tempURL(ext: ext, near: near)
        try await ProcessRunner.check(.gs, ["-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=\(device)", "-sOutputFile=\(out.path)", pdf.path], timeout: 600)
        return out
    }
}
