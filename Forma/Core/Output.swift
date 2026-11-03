import Foundation
import ImageIO

/// File-name patterns: {original} {date} {datetime} {year} {month} {day} {time} {camera} {width} {height} {format} {index}
enum NamePattern {
    static let tokens: [(token: String, help: String)] = [
        ("{original}", "Nom d'origine"), ("{date}", "Date (AAAA-MM-JJ)"), ("{datetime}", "Date et heure"),
        ("{year}", "Année"), ("{month}", "Mois"), ("{day}", "Jour"), ("{time}", "Heure (HH-mm-ss)"),
        ("{camera}", "Appareil photo"), ("{width}", "Largeur"), ("{height}", "Hauteur"),
        ("{format}", "Format de sortie"), ("{index}", "Numéro dans le lot"),
    ]

    struct Context {
        var original: String
        var date: Date
        var camera: String?
        var width: Int?
        var height: Int?
        var format: String
        var index: Int
    }

    static func context(for url: URL, format: FormatDescriptor, index: Int) -> Context {
        var date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var camera: String?
        var w: Int?, h: Int?
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = props[kCGImagePropertyPixelWidth] as? Int
            h = props[kCGImagePropertyPixelHeight] as? Int
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                camera = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
                if let d = f.date(from: s) { date = d }
            }
        }
        return Context(original: url.deletingPathExtension().lastPathComponent, date: date, camera: camera,
                       width: w, height: h, format: format.ext, index: index)
    }

    static func render(_ pattern: String, _ c: Context) -> String {
        func f(_ s: String) -> String { let d = DateFormatter(); d.dateFormat = s; return d.string(from: c.date) }
        var out = pattern.isEmpty ? "{original}" : pattern
        let map: [String: String?] = [
            "{original}": c.original, "{date}": f("yyyy-MM-dd"), "{datetime}": f("yyyy-MM-dd_HH-mm-ss"),
            "{year}": f("yyyy"), "{month}": f("MM"), "{day}": f("dd"), "{time}": f("HH-mm-ss"),
            "{camera}": c.camera, "{width}": c.width.map(String.init), "{height}": c.height.map(String.init),
            "{format}": c.format, "{index}": String(format: "%03d", c.index),
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v ?? "") }
        // Unknown tokens are removed.
        out = out.replacingOccurrences(of: #"\{[a-z]+\}"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        return out.isEmpty ? c.original : out
    }
}

enum OutputResolver {
    /// Where the result of `input` should go. Returns nil when the policy says to skip.
    static func destination(for input: URL, format: FormatDescriptor, mode: ProcessMode,
                            settings: OutputSettings, index: Int, suffix: String? = nil,
                            overrideFolder: URL? = nil) throws -> URL? {
        let fm = FileManager.default
        var folder: URL
        if let overrideFolder {
            folder = overrideFolder
        } else {
            switch settings.destination {
            case .alongside: folder = input.deletingLastPathComponent()
            case .subfolder: folder = input.deletingLastPathComponent().appendingPathComponent(settings.subfolderName.isEmpty ? "Forma" : settings.subfolderName)
            case .custom:
                guard let p = settings.customFolderPath else { throw ToolError("Dossier de sortie personnalisé non configuré.") }
                folder = URL(fileURLWithPath: p)
            }
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let pattern: String
        if mode == .compress && !settings.samePatternForCompress { pattern = settings.compressPattern }
        else { pattern = settings.convertPattern }
        var base = NamePattern.render(pattern, NamePattern.context(for: input, format: format, index: index))
        if let suffix { base += suffix }
        var url = folder.appendingPathComponent(base).appendingPathExtension(format.ext)

        // Never overwrite the source itself (unless "replace originals", handled by the pipeline via a temp file).
        if url.standardizedFileURL.path == input.standardizedFileURL.path {
            url = folder.appendingPathComponent(base + (mode == .compress ? "_compressed" : "_converted")).appendingPathExtension(format.ext)
        }
        guard fm.fileExists(atPath: url.path) else { return url }
        switch settings.conflict {
        case .overwrite: return url
        case .skip: return nil
        case .rename:
            var n = 2
            while true {
                let candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(format.ext)
                if !fm.fileExists(atPath: candidate.path) { return candidate }
                n += 1
            }
        }
    }

    /// A unique temp file in the same volume as `near` (so the final move is atomic and instant).
    static func tempURL(ext: String, near: URL) -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: near, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("Forma", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("forma-\(UUID().uuidString)").appendingPathExtension(ext)
    }

    static func copyDates(from src: URL, to dst: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: src.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate] { keep[.creationDate] = c }
        if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
        try? FileManager.default.setAttributes(keep, ofItemAtPath: dst.path)
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension URL {
    var fileSize: Int64 { Int64((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
}
