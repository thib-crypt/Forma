import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

// MARK: - Settings

/// An app referenced by a rule (bundle id + display name, so the UI stays readable).
struct AppRef: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

enum ClipboardTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, manual
    var id: String { rawValue }
    var label: String { self == .automatic ? "À chaque copie d'image" : "Seulement à la demande" }
    var help: String {
        self == .automatic
            ? "Chaque image copiée est optimisée selon les règles, dans la demi-seconde."
            : "Rien n'est modifié tout seul : ⌥⌘V dans Forma, le menu, ou « Coller optimisé » dans Copia."
    }
}

enum ClipboardContentFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, photo, graphic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: "Toutes les images"
        case .photo: "Photos"
        case .graphic: "Captures et graphiques"
        }
    }
    var symbol: String {
        switch self {
        case .any: "photo.on.rectangle"
        case .photo: "camera"
        case .graphic: "macwindow"
        }
    }
}

enum ClipboardOutput: String, Codable, CaseIterable, Identifiable, Sendable {
    case imageAndFile, imageOnly, fileOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .imageAndFile: "Image + fichier"
        case .imageOnly: "Image seulement"
        case .fileOnly: "Fichier seulement"
        }
    }
    var help: String {
        switch self {
        case .imageAndFile: "Se colle partout : dans une app comme image, dans le Finder ou un formulaire web comme fichier (garde l'extension .webp, .jpg…)."
        case .imageOnly: "Comme une capture classique. Les formats que l'app cible ne lit pas (WebP, AVIF) seront convertis par elle."
        case .fileOnly: "Idéal pour les formulaires d'envoi web et le Finder."
        }
    }
}

/// What a rule does to the image.
struct ClipboardAction: Codable, Equatable, Sendable {
    /// Leave the clipboard untouched.
    var skip = false
    /// "AUTO" (PNG for graphics and transparency, JPEG for photos), "SAME", or a format id.
    var format = "AUTO"
    var quality = 80
    /// Longest side, nil = keep.
    var maxDimension: Int? = 2560
    /// Retina screenshots (144 dpi) are halved to their on-screen size.
    var retinaToStandard = false
    var stripMetadata = true
    /// pngquant for PNG output (much smaller, near-lossless).
    var lossyPNG = true

    static let choices = ["AUTO", "SAME", "WEBP", "JPEG", "PNG", "HEIC", "AVIF", "JXL"]

    var summary: String {
        if skip { return "Ne pas toucher" }
        var parts = [format == "AUTO" ? "Auto" : format == "SAME" ? "Même format" : (FormatCatalog.format(format)?.name ?? format)]
        if format != "PNG" || !lossyPNG { parts.append("qualité \(quality)") }
        if let m = maxDimension { parts.append("≤ \(m) px") }
        if retinaToStandard { parts.append("Retina ÷2") }
        if stripMetadata { parts.append("sans métadonnées") }
        return parts.joined(separator: " · ")
    }
}

struct ClipboardRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var enabled = true
    /// Source apps (empty = any app).
    var apps: [AppRef] = []
    var content: ClipboardContentFilter = .any
    /// Only images at least this heavy (0 = any).
    var minSizeKB = 0
    var action = ClipboardAction()

    var conditionSummary: String {
        var parts: [String] = []
        parts.append(apps.isEmpty ? "Toutes les apps" : apps.map(\.name).joined(separator: ", "))
        if content != .any { parts.append(content.label.lowercased()) }
        if minSizeKB > 0 { parts.append("≥ \(minSizeKB) Ko") }
        return parts.joined(separator: " · ")
    }
}

struct ClipboardSettings: Codable, Equatable, Sendable {
    var enabled = false
    var trigger: ClipboardTrigger = .automatic
    /// Evaluated top to bottom; the first enabled rule that matches wins, otherwise `fallback`.
    var rules: [ClipboardRule] = ClipboardSettings.defaultRules
    var fallback = ClipboardAction()
    /// Images smaller than this are never touched automatically.
    var minSizeKB = 40
    /// Keep the original when the gain is smaller than this.
    var minGainPercent = 10
    var output: ClipboardOutput = .imageAndFile
    /// Optimized files are kept this long (so clipboard managers like Copia can still paste them).
    var fileRetentionDays = 7
    var ignoreClipboardManagers = true
    var showToast = true
    var playSound = false
    var pausedUntil: Date? = nil

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    static let defaultRules: [ClipboardRule] = [
        ClipboardRule(name: "Outils de design : ne pas toucher", enabled: true,
                      apps: [AppRef(bundleID: "com.figma.Desktop", name: "Figma"),
                             AppRef(bundleID: "com.bohemiancoding.sketch3", name: "Sketch"),
                             AppRef(bundleID: "com.pixelmatorteam.pixelmator.x", name: "Pixelmator Pro")],
                      action: ClipboardAction(skip: true)),
        ClipboardRule(name: "Photos", content: .photo,
                      action: ClipboardAction(format: "JPEG", quality: 82, maxDimension: 2560, stripMetadata: true)),
        ClipboardRule(name: "Captures d'écran", content: .graphic,
                      action: ClipboardAction(format: "PNG", quality: 80, maxDimension: nil, retinaToStandard: false, lossyPNG: true)),
    ]

    /// Bundle ids of clipboard managers that restore past items (their writes are not "new copies").
    static let clipboardManagers: Set<String> = ["com.thibault.copia", "com.fiplab.copyclip2", "com.fiplab.clipboard",
                                                 "org.p0deje.Maccy", "com.sindresorhus.Pasteboard-Viewer", "com.raycast.macos"]

    /// Old single-setting optimizer (Forma 1.1) → fallback rule.
    static func migrated(enabled: Bool, target: String, maxDimension: Int?, quality: Int) -> ClipboardSettings {
        var s = ClipboardSettings()
        s.enabled = enabled
        s.fallback = ClipboardAction(format: target, quality: quality, maxDimension: maxDimension, stripMetadata: true)
        return s
    }
}

// MARK: - Rule matching (pure)

enum ClipboardRules {
    struct Match: Sendable, Equatable {
        var ruleName: String
        var ruleID: UUID?
        var action: ClipboardAction
    }

    static func match(_ s: ClipboardSettings, sourceApp: String?, isPhoto: Bool, bytes: Int64) -> Match {
        for r in s.rules where r.enabled {
            if !r.apps.isEmpty && !r.apps.contains(where: { $0.bundleID == sourceApp }) { continue }
            if r.content == .photo && !isPhoto { continue }
            if r.content == .graphic && isPhoto { continue }
            if r.minSizeKB > 0 && bytes < Int64(r.minSizeKB) * 1024 { continue }
            return Match(ruleName: r.name, ruleID: r.id, action: r.action)
        }
        return Match(ruleName: "Règle par défaut", ruleID: nil, action: s.fallback)
    }

    // MARK: Content analysis

    struct Analysis: Sendable {
        var width: Int
        var height: Int
        var hasAlpha: Bool
        var isPhoto: Bool
        var dpi: Double
    }

    /// Photo vs. graphic: UI captures and drawings are made of large flat areas; photos almost never are.
    static func analyze(_ url: URL) -> Analysis? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let alpha = (p[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let dpi = (p[kCGImagePropertyDPIWidth] as? Double) ?? 72
        var photo = false
        if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            photo = flatness(thumb) < 0.45
        }
        return Analysis(width: w, height: h, hasAlpha: alpha, isPhoto: photo, dpi: dpi)
    }

    /// Share of pixels identical to their right neighbour (after a light quantization).
    static func flatness(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 1, h > 0 else { return 1 }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var same = 0, total = 0
        for y in 0..<h {
            var i = y * w * 4
            for _ in 0..<(w - 1) {
                let j = i + 4
                if buf[i] >> 3 == buf[j] >> 3 && buf[i + 1] >> 3 == buf[j + 1] >> 3 && buf[i + 2] >> 3 == buf[j + 2] >> 3 { same += 1 }
                total += 1
                i = j
            }
        }
        return total == 0 ? 1 : Double(same) / Double(total)
    }

    // MARK: Pasteboard contract (shared with Copia)

    /// Pasteboard type Forma adds to optimized clipboard images (JSON, see `ClipboardStamp`).
    static let stampType = "com.thibault.forma.clipboard"
    /// Copia's preference order for image types: hashing the same representation lets Copia find the original clip.
    static let copiaImageTypes = ["public.png", "public.heic", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "public.avif", "public.jpeg-xl", "public.tiff"]

    /// Same digest as Copia's `ClipHasher.hash(data:prefix:"img:")` (SHA-256, first 16 bytes, hex).
    static func copiaHash(_ data: Data) -> String {
        "img:" + SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Metadata attached to the clipboard next to an optimized image.
struct ClipboardStamp: Codable, Sendable {
    var version = 1
    /// Copia-compatible hash of the image that was replaced.
    var originalHash: String?
    var originalBytes: Int64
    var bytes: Int64
    var format: String
    var ext: String
    var rule: String
    var savingsPercent: Int
    var sourceApp: String?
    var file: String?
}
