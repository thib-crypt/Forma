import Foundation
import AppKit
import PDFKit
import Vision

/// Text documents, e-books, spreadsheets and presentations.
///
/// Routing, fastest and most faithful first:
/// - LibreOffice (when installed) for Office ↔ Office and Office → PDF: the only engine that keeps the real layout.
/// - Pandoc for anything structural (Word ↔ Markdown, EPUB, LaTeX, HTML…): keeps headings, lists, tables, images, notes.
/// - Cocoa's text system for RTF / .doc / plain text / web archives, and for PDF output: pandoc renders a styled
///   HTML, TextKit paginates it straight into a vector PDF (no LaTeX, no browser).
enum OfficeEngine {

    struct Job: Sendable {
        var input: URL
        var format: FormatDescriptor        // kind == .office
        var image: ImageSettings            // used to recompress pictures embedded in DOCX / PPTX / EPUB…
        var mode: ProcessMode
        var compress: Bool
        var near: URL
    }

    enum Family { case text, sheet, slides }

    // MARK: - Format knowledge

    /// Pandoc readers by input extension.
    static let pandocReaders: [String: String] = [
        "md": "markdown", "markdown": "markdown", "mdown": "markdown", "mkd": "markdown",
        "docx": "docx", "docm": "docx", "dotx": "docx", "odt": "odt", "epub": "epub", "fb2": "fb2",
        "html": "html", "htm": "html", "xhtml": "html", "rtf": "rtf",
        "tex": "latex", "latex": "latex", "rst": "rst", "org": "org", "adoc": "asciidoc", "asciidoc": "asciidoc",
        "typ": "typst", "textile": "textile", "wiki": "mediawiki", "mediawiki": "mediawiki", "dbk": "docbook",
        "opml": "opml", "ipynb": "ipynb", "djot": "djot", "csv": "csv", "tsv": "tsv", "xlsx": "xlsx", "pptx": "pptx",
    ]
    /// Pandoc writers by output format id.
    static let pandocWriters: [String: String] = [
        "DOCX": "docx", "ODT": "odt", "RTF": "rtf", "TXT": "plain", "MD": "gfm", "HTML": "html5", "EPUB": "epub3",
        "TEX": "latex", "TYP": "typst", "RST": "rst", "ADOC": "asciidoc", "ORG": "org", "WIKI": "mediawiki",
        "FB2": "fb2", "PPTX": "pptx",
    ]
    /// Cocoa writers by output format id.
    static let nativeWriters: [String: NSAttributedString.DocumentType] = [
        "DOCX": .officeOpenXML, "ODT": .openDocument, "RTF": .rtf, "TXT": .plain, "HTML": .html,
        "DOC": .docFormat, "WEBARCHIVE": .webArchive,
    ]
    /// Inputs whose look lives in direct formatting (fonts, colours): read by Cocoa, not through pandoc's semantic model.
    static let nativePreferred: Set<String> = ["txt", "text", "rtf", "rtfd", "doc", "webarchive"]
    /// Outputs where Cocoa's writer is better than pandoc's.
    static let nativeWriterPreferred: Set<String> = ["RTF", "DOC", "WEBARCHIVE"]
    /// Inputs only LibreOffice can open.
    static let officeOnlyInputs: Set<String> = ["xls", "xlsm", "ods", "numbers", "ppt", "pps", "ppsx", "odp", "key", "pages", "wpd", "ott"]
    /// Outputs only LibreOffice can write.
    static let officeOnlyOutputs: Set<String> = ["XLSX", "ODS", "CSV", "ODP"]
    /// Markup outputs whose pictures are extracted into a folder next to the result.
    static let mediaExtractingOutputs: Set<String> = ["MD", "TEX", "TYP", "RST", "ADOC", "ORG", "WIKI"]
    /// ZIP-based packages whose embedded pictures can be recompressed.
    static let zipPackages: Set<String> = ["docx", "docm", "dotx", "xlsx", "xlsm", "pptx", "ppsx", "odt", "ott", "ods", "odp", "epub"]
    /// Inputs LibreOffice can open (everything but the markup / e-book formats).
    static let libreOfficeReadable: Set<String> = [
        "doc", "docx", "docm", "dotx", "odt", "ott", "rtf", "txt", "text", "pages", "wpd", "html", "htm", "xhtml",
        "xlsx", "xlsm", "xls", "ods", "csv", "tsv", "numbers", "pptx", "ppt", "pps", "ppsx", "odp", "key",
    ]
    static let wordLike: Set<String> = ["doc", "docx", "docm", "dotx", "odt", "ott", "rtf", "wpd", "pages"]

    static func family(ofExt ext: String) -> Family {
        switch ext {
        case "xlsx", "xlsm", "xls", "ods", "csv", "tsv", "numbers": .sheet
        case "pptx", "ppt", "pps", "ppsx", "odp", "key": .slides
        default: .text
        }
    }

    /// What LibreOffice can export for each kind of document.
    static func libreOfficeWritable(_ family: Family) -> Set<String> {
        switch family {
        case .text: ["PDFDOC", "DOCX", "ODT", "DOC", "RTF", "HTML", "TXT", "EPUB"]
        case .sheet: ["PDFDOC", "XLSX", "ODS", "CSV", "HTML"]
        case .slides: ["PDFDOC", "PPTX", "ODP", "HTML"]
        }
    }

    static let libreOfficeFilters: [String: String] = [
        "PDFDOC": "pdf", "DOCX": "docx:MS Word 2007 XML", "ODT": "odt", "DOC": "doc:MS Word 97", "RTF": "rtf",
        "HTML": "html", "TXT": "txt:Text (encoded):UTF8", "EPUB": "epub",
        "XLSX": "xlsx:Calc MS Excel 2007 XML", "ODS": "ods", "CSV": "csv:Text - txt - csv (StarCalc):44,34,76,1",
        "PPTX": "pptx:Impress MS PowerPoint 2007 XML", "ODP": "odp",
    ]

    // MARK: - Entry point

    static func process(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> [ProducedFile] {
        try Task.checkCancellation()
        let fm = FileManager.default
        let out = job.format
        let inExt = job.input.pathExtension.lowercased()
        let work = OutputResolver.tempURL(ext: "work", near: job.near)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        // Results live outside `work` so they survive the cleanup; the pipeline moves them into place.
        let result = OutputResolver.tempURL(ext: "out", near: job.near)
        try fm.createDirectory(at: result, withIntermediateDirectories: true)
        let dest = result.appendingPathComponent("\(job.input.deletingPathExtension().lastPathComponent).\(out.ext)")
        progress(0.05)

        // Same format: compression = recompress the pictures inside the package.
        if inExt == out.ext || (out.id == "HTML" && ["htm", "xhtml"].contains(inExt)) {
            if job.compress, zipPackages.contains(inExt) {
                return [ProducedFile(url: try await repack(job.input, to: dest, settings: job.image, work: work, progress: progress))]
            }
            try fm.copyItem(at: job.input, to: dest)
            return [ProducedFile(url: dest)]
        }

        var companion: URL?
        try await convert(job.input, ext: inExt, to: out, dest: dest, work: work, companion: &companion, progress: progress)
        try Task.checkCancellation()
        guard fm.fileExists(atPath: dest.path) else { throw ToolError("Le document n'a pas été créé.") }

        if job.compress, zipPackages.contains(out.ext) {
            let packed = result.appendingPathComponent("packed-\(dest.lastPathComponent)")
            let r = try await repack(dest, to: packed, settings: job.image, work: work) { progress(0.8 + $0 * 0.2) }
            if r == packed { try fm.removeItem(at: dest); try fm.moveItem(at: packed, to: dest) }
        }
        progress(1)
        return [ProducedFile(url: dest, companion: companion)]
    }

    // MARK: - Routing

    private static func convert(_ input: URL, ext inExt: String, to out: FormatDescriptor, dest: URL, work: URL,
                                companion: inout URL?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let srcFamily = family(ofExt: inExt)
        let outFamily: Family? = ["XLSX", "ODS", "CSV"].contains(out.id) ? .sheet : out.id == "ODP" ? .slides : nil

        // 1. LibreOffice: real Office layout, spreadsheets and presentations.
        if officeOnlyOutputs.contains(out.id) {
            guard libreOfficeReadable.contains(inExt), outFamily == srcFamily else {
                throw ToolError("Impossible de convertir un \(familyName(srcFamily)) (.\(inExt)) en \(out.name).")
            }
            guard Tool.soffice.isAvailable else { throw libreOfficeMissing(out.name) }
        }
        if Tool.soffice.isAvailable, libreOfficeReadable.contains(inExt), libreOfficeWritable(srcFamily).contains(out.id),
           officeOnlyOutputs.contains(out.id) || officeOnlyInputs.contains(inExt)
            || srcFamily != .text && out.id == "PDFDOC"
            || wordLike.contains(inExt) && ["PDFDOC", "DOCX", "ODT", "DOC", "RTF"].contains(out.id) {
            progress(0.2)
            try await libreOffice(input, filter: libreOfficeFilters[out.id]!, to: dest, work: work)
            return
        }

        // 2. Formats only LibreOffice opens: go through the matching OOXML file, then continue below.
        var source = input, srcExt = inExt
        if officeOnlyInputs.contains(inExt) {
            guard Tool.soffice.isAvailable else { throw libreOfficeMissing(".\(inExt)") }
            let inter = srcFamily == .sheet ? "xlsx" : srcFamily == .slides ? "pptx" : "docx"
            let tmp = work.appendingPathComponent("intermediate.\(inter)")
            try await libreOffice(input, filter: inter, to: tmp, work: work)
            source = tmp; srcExt = inter
            progress(0.4)
        }

        // 3. PDF: styled attributed text, paginated by TextKit.
        if out.id == "PDFDOC" {
            let text = try await attributed(source, ext: srcExt, work: work)
            progress(0.6)
            try renderPDF(text, to: dest, title: input.deletingPathExtension().lastPathComponent)
            return
        }

        // 4. Pandoc, straight from source to target.
        if let reader = pandocReaders[srcExt], let writer = pandocWriters[out.id],
           !nativeWriterPreferred.contains(out.id), !(nativePreferred.contains(srcExt) && nativeWriters[out.id] != nil) {
            progress(0.2)
            companion = try await pandoc(source, from: reader, to: writer, format: out, dest: dest, title: input.deletingPathExtension().lastPathComponent)
            return
        }

        // 5. Cocoa: read into attributed text, write natively or hand an HTML rendition to pandoc.
        let text = try await attributed(source, ext: srcExt, work: work)
        progress(0.6)
        if let type = nativeWriters[out.id] {
            try writeNative(text, type: type, to: dest)
        } else if let writer = pandocWriters[out.id] {
            let html = work.appendingPathComponent("bridge.html")
            try writeNative(text, type: .html, to: html)
            companion = try await pandoc(html, from: "html", to: writer, format: out, dest: dest, title: input.deletingPathExtension().lastPathComponent)
        } else {
            throw ToolError("Conversion en \(out.name) non prise en charge pour ce fichier.")
        }
    }

    private static func familyName(_ f: Family) -> String {
        switch f { case .text: "document texte"; case .sheet: "classeur"; case .slides: "diaporama" }
    }

    private static func libreOfficeMissing(_ what: String) -> ToolError {
        ToolError("\(what) demande LibreOffice — `brew install --cask libreoffice`, puis relancez Forma.")
    }

    // MARK: - Pandoc

    /// Runs pandoc. Returns the folder of extracted pictures for markup outputs, if any.
    @discardableResult
    static func pandoc(_ input: URL, from reader: String, to writer: String, format: FormatDescriptor?, dest: URL,
                       title: String, extraArgs: [String] = []) async throws -> URL? {
        guard Tool.pandoc.isAvailable else {
            throw ToolError("Pandoc est nécessaire pour ce format — `brew install pandoc`.")
        }
        let dir = dest.deletingLastPathComponent()
        var args = [input.path, "-f", reader, "-t", writer, "-o", dest.path,
                    "--resource-path=\(input.deletingLastPathComponent().path)"]
        switch writer {
        case "html5":
            args += ["--standalone", "--embed-resources", "-M", "pagetitle=\(title)"]
        case "epub3":
            let meta = dir.appendingPathComponent("forma-meta.yaml")
            try "title: \(jsonString(title))\nlang: fr-FR\n".write(to: meta, atomically: true, encoding: .utf8)
            args += ["--metadata-file=\(meta.path)"]
        case "rtf", "latex", "typst":
            args += ["--standalone"]
        case "gfm", "plain", "rst", "org", "asciidoc", "mediawiki":
            args += ["--wrap=none"]
        default: break
        }
        var cleanup: [URL] = []
        if writer == "gfm" {
            // Plain `![alt](path)` instead of raw HTML <figure> blocks with inline sizes.
            let filter = dir.appendingPathComponent("forma-figures.lua")
            try """
            function Figure(f)
              local img
              f:walk({ Image = function(i) img = i end })
              if img then img.attributes = {}; return pandoc.Para({ img }) end
            end
            function Image(i) i.attributes = {}; return i end
            """.write(to: filter, atomically: true, encoding: .utf8)
            args += ["--lua-filter=\(filter.path)"]
            cleanup.append(filter)
        }
        var media: String?
        if let format, mediaExtractingOutputs.contains(format.id) {
            media = "\(dest.deletingPathExtension().lastPathComponent)_images"
            args += ["--extract-media=\(media!)"]
        }
        args += extraArgs
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        try await ProcessRunner.check(.pandoc, args, cwd: dir, timeout: 300)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("forma-meta.yaml"))
        if let media {
            let folder = dir.appendingPathComponent(media)
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
        }
        return nil
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    // MARK: - LibreOffice

    /// LibreOffice refuses concurrent instances on one profile: conversions go through one at a time.
    private static let libreOfficeGate = SerialGate()

    static func libreOffice(_ input: URL, filter: String, to dest: URL, work: URL) async throws {
        let profile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forma/LibreOffice", isDirectory: true)
        let outDir = work.appendingPathComponent("lo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = try await libreOfficeGate.run {
            try await ProcessRunner.check(.soffice, [
                "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--invisible", "--norestore",
                "--nologo", "--nodefault", "--nolockcheck", "--convert-to", filter, "--outdir", outDir.path, input.path,
            ], timeout: 600)
        }
        let produced = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        guard let file = produced.first(where: { !$0.lastPathComponent.hasPrefix(".") }) else {
            throw ToolError("LibreOffice n'a pas pu convertir ce fichier.")
        }
        try FileManager.default.moveItem(at: file, to: dest)
    }

    // MARK: - Attributed text

    /// HTML import goes through WebKit: one at a time keeps memory and helper processes in check.
    private static let htmlGate = SerialGate()

    /// Template used to give pandoc's HTML a clean, Apple-like look before TextKit paginates it.
    private static let printTemplate = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>$pagetitle$</title>
    <style>
    body { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.4; color: #1d1d1f; }
    h1 { font-size: 21pt; margin: 18pt 0 8pt; } h2 { font-size: 16pt; margin: 16pt 0 6pt; }
    h3 { font-size: 13pt; margin: 12pt 0 4pt; } h4, h5, h6 { font-size: 11pt; margin: 10pt 0 4pt; }
    h1.title { font-size: 26pt; text-align: center; margin-bottom: 4pt; }
    p.author, p.date { text-align: center; color: #6e6e73; margin: 0; }
    p { margin: 0 0 7pt; } a { color: #0060df; }
    table { border-collapse: collapse; margin: 6pt 0 10pt; }
    th, td { border: 0.5pt solid #c7c7cc; padding: 3pt 7pt; vertical-align: top; }
    th { background: #f2f2f7; font-weight: 600; }
    blockquote { color: #515154; border-left: 2.5pt solid #d2d2d7; margin: 6pt 0; padding-left: 10pt; }
    code { font-family: Menlo, monospace; font-size: 9.5pt; }
    pre { font-family: Menlo, monospace; font-size: 9pt; background: #f5f5f7; padding: 7pt; }
    figcaption, .caption { color: #6e6e73; font-size: 9.5pt; }
    hr { border: none; border-top: 0.5pt solid #d2d2d7; }
    </style></head><body>
    $if(title)$<h1 class="title">$title$</h1>$endif$
    $for(author)$<p class="author">$author$</p>$endfor$
    $if(date)$<p class="date">$date$</p>$endif$
    $body$
    </body></html>
    """

    static func attributed(_ url: URL, ext: String, work: URL) async throws -> NSAttributedString {
        portableFonts(try await loadAttributed(url, ext: ext, work: work))
    }

    /// macOS private UI fonts (".SFNS…") must never end up in a .docx / .rtf / PDF text layer read elsewhere.
    private static func portableFonts(_ text: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let fm = NSFontManager.shared
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            guard let font = value as? NSFont, font.fontName.hasPrefix(".") else { return }
            let traits = fm.traits(of: font).intersection([.boldFontMask, .italicFontMask])
            let mono = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            let base = NSFont(name: mono ? "Menlo-Regular" : "HelveticaNeue", size: font.pointSize) ?? NSFont.systemFont(ofSize: font.pointSize)
            m.addAttribute(.font, value: fm.convert(base, toHaveTrait: traits), range: range)
        }
        return m
    }

    private static func loadAttributed(_ url: URL, ext: String, work: URL) async throws -> NSAttributedString {
        if ext == "pdf" { return try await pdfText(url) }
        if ["txt", "text"].contains(ext) { return try plainText(url) }
        let readsNatively = nativePreferred.contains(ext) || ["html", "htm", "xhtml"].contains(ext) || pandocReaders[ext] == nil
        if readsNatively {
            return try await htmlGate.run { try NSAttributedString(url: url, options: [:], documentAttributes: nil) }
        }
        guard let reader = pandocReaders[ext] else { throw ToolError("Format .\(ext) non pris en charge.") }
        let template = work.appendingPathComponent("print-template.html")
        try printTemplate.write(to: template, atomically: true, encoding: .utf8)
        let html = work.appendingPathComponent("print-\(UUID().uuidString).html")
        try await pandoc(url, from: reader, to: "html5", format: nil, dest: html, title: url.deletingPathExtension().lastPathComponent,
                         extraArgs: ["--template=\(template.path)"])
        let data = try Data(contentsOf: html)
        return try await htmlGate.run {
            try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                         .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        }
    }

    private static func plainText(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        style.paragraphSpacing = 3
        return NSAttributedString(string: text, attributes: [.font: NSFont(name: "HelveticaNeue", size: 11) ?? NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
                                                             .paragraphStyle: style])
    }

    /// PDF → text. Native text layer first; scanned PDFs go through Vision's OCR.
    static func pdfText(_ url: URL) async throws -> NSAttributedString {
        guard let doc = PDFDocument(url: url) else { throw ToolError("Impossible d'ouvrir le PDF.") }
        if doc.isLocked { throw ToolError("Ce PDF est protégé par mot de passe. Déverrouillez-le d'abord.") }
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let s = page.attributedString else { continue }
            out.append(s)
            if i < doc.pageCount - 1 { out.append(NSAttributedString(string: "\n\n")) }
        }
        if out.string.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 * max(1, doc.pageCount) / 2 { return out }

        // No text layer: OCR every page (French + English, language correction on).
        let ocr = NSMutableAttributedString()
        let font = NSFont(name: "HelveticaNeue", size: 11) ?? NSFont.systemFont(ofSize: 11)
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let ref = doc.page(at: i)?.pageRef else { continue }
            let img = try DocumentEngine.renderPage(ref, dpi: 220, transparent: false)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["fr-FR", "en-US"]
            try VNImageRequestHandler(cgImage: img).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            ocr.append(NSAttributedString(string: lines.joined(separator: "\n") + (i < doc.pageCount - 1 ? "\n\n" : ""), attributes: [.font: font]))
        }
        guard !ocr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("Aucun texte trouvé dans ce PDF.")
        }
        return ocr
    }

    static func writeNative(_ text: NSAttributedString, type: NSAttributedString.DocumentType, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .plain { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try text.data(from: range, documentAttributes: attrs)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - PDF rendering

    /// US-style regions print on Letter, everyone else on A4.
    static var pageSize: CGSize {
        let letter: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "CR", "PR"]
        return letter.contains(Locale.current.region?.identifier ?? "") ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    /// Paginates attributed text into a vector PDF with TextKit (no print panel, no main thread, no WebKit view).
    static func renderPDF(_ text: NSAttributedString, to url: URL, title: String) throws {
        let page = pageSize
        let margin = CGPoint(x: 64, y: 62)
        let content = CGSize(width: page.width - 2 * margin.x, height: page.height - 2 * margin.y)
        let storage = NSTextStorage(attributedString: fitAttachments(text, in: content))
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        repeat {
            try Task.checkCancellation()
            let c = NSTextContainer(size: content)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            layout.ensureLayout(for: c)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 10_000

        var box = CGRect(origin: .zero, size: page)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Forma"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ToolError("Impossible de créer le PDF.")
        }
        let footer: [NSAttributedString.Key: Any] = [.font: NSFont(name: "HelveticaNeue", size: 8.5) ?? NSFont.systemFont(ofSize: 8.5),
                                                     .foregroundColor: NSColor(white: 0.55, alpha: 1)]
        for (i, c) in containers.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let range = layout.glyphRange(for: c)
            layout.drawBackground(forGlyphRange: range, at: margin)
            layout.drawGlyphs(forGlyphRange: range, at: margin)
            if containers.count > 1 {
                let n = NSAttributedString(string: "\(i + 1) / \(containers.count)", attributes: footer)
                n.draw(at: CGPoint(x: (page.width - n.size().width) / 2, y: page.height - margin.y / 2 - 6))
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Pictures wider than the text column (or taller than a page) are scaled down to fit.
    private static func fitAttachments(_ text: NSAttributedString, in content: CGSize) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let a = value as? NSTextAttachment else { return }
            var image = a.image
            if image == nil, let data = a.fileWrapper?.regularFileContents { image = NSImage(data: data) }
            if image == nil, let cell = a.attachmentCell as? NSTextAttachmentCell { image = cell.image }
            guard let image, image.size.width > 0, image.size.height > 0 else { return }
            var size = a.bounds.size.width > 0 ? a.bounds.size : image.size
            let f = min(1, content.width / size.width, content.height * 0.92 / size.height)
            size = CGSize(width: floor(size.width * f), height: floor(size.height * f))
            let scaled = NSImage(size: size)
            scaled.addRepresentations(image.representations)
            let replacement = NSTextAttachment()
            replacement.attachmentCell = NSTextAttachmentCell(imageCell: scaled)
            m.addAttribute(.attachment, value: replacement, range: range)
        }
        return m
    }

    // MARK: - Package compression (DOCX, PPTX, XLSX, ODT, EPUB…)

    /// Recompresses the pictures inside a ZIP-based document. Returns `dest`, or `input` when nothing was gained.
    static func repack(_ input: URL, to dest: URL, settings: ImageSettings, work: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let dir = work.appendingPathComponent("pkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let unzip = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", input.path, dir.path], timeout: 300)
        guard unzip.status == 0 else { throw ToolError("Document illisible (archive ZIP invalide).") }

        var pictures: [URL] = []
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in e where ["jpg", "jpeg", "png"].contains(f.pathExtension.lowercased()) && f.fileSize >= 24_000 {
                pictures.append(f)
            }
        }
        var s = settings
        s.watermark.enabled = false
        s.targetFileSizeKB = nil
        s.metadata = .stripAll
        s.upscale = false
        if s.resizeMode == .none { s.resizeMode = .fit; s.width = 2560; s.height = 2560 }
        let imgSettings = s
        var gained = false
        if !pictures.isEmpty {
            let total = Double(pictures.count)
            gained = await withTaskGroup(of: Bool.self) { group in
                var next = 0
                var done = 0.0, any = false
                func add() {
                    guard next < pictures.count else { return }
                    let f = pictures[next]; next += 1
                    group.addTask { await recompress(f, settings: imgSettings) }
                }
                for _ in 0..<min(4, pictures.count) { add() }
                while let r = await group.next() {
                    any = any || r; done += 1
                    progress(0.1 + 0.75 * done / total)
                    add()
                }
                return any
            }
        }
        try Task.checkCancellation()
        guard gained else {
            if input != dest { try fm.copyItem(at: input, to: dest) }
            return dest
        }

        // Rezip. ODF / EPUB require an uncompressed `mimetype` entry first.
        let tmpZip = work.appendingPathComponent("repack-\(UUID().uuidString).zip")
        if fm.fileExists(atPath: dir.appendingPathComponent("mimetype").path) {
            _ = try await ProcessRunner.run("/usr/bin/zip", ["-X", "-0", "-q", tmpZip.path, "mimetype"], cwd: dir)
        }
        let z = try await ProcessRunner.run("/usr/bin/zip", ["-X", "-9", "-q", "-r", "-D", tmpZip.path, ".", "-x", "mimetype", "-x", ".*"], cwd: dir, timeout: 300)
        guard z.status == 0 else { throw ToolError("Recompression du document impossible.") }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmpZip, to: dest)
        progress(1)
        return dest
    }

    /// One embedded picture, same format and name (the document references it by path). True if it got smaller.
    private static func recompress(_ file: URL, settings: ImageSettings) async -> Bool {
        let isPNG = file.pathExtension.lowercased() == "png"
        guard let format = FormatCatalog.format(isPNG ? "PNG" : "JPEG") else { return false }
        let job = ImageEngine.Job(input: file, inputClass: .raster, format: format, settings: settings, mode: .compress,
                                  compress: true, near: file.deletingLastPathComponent())
        guard let produced = try? await ImageEngine.process(job, progress: { _ in }).first?.url else { return false }
        let before = file.fileSize, after = produced.fileSize
        if after > 0, after < before * 95 / 100, (try? FileManager.default.replaceItemAt(file, withItemAt: produced)) != nil {
            return true
        }
        try? FileManager.default.removeItem(at: produced)
        return false
    }
}

/// Async mutual exclusion: callers queue up instead of blocking a cooperative thread.
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }   // ownership handed over
    }

    nonisolated func run<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let r = try await operation()
            await release()
            return r
        } catch {
            await release()
            throw error
        }
    }
}
