import Foundation

/// A complete, reusable action ("Web", "E-mail", "Archive"…): mode, output format per kind, setting overrides and
/// destination. Shown in the Finder menu, the Share panel, the menu bar, `forma run <nom>` and Shortcuts.
struct Recipe: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var symbol = "wand.and.stars"
    var mode: ProcessMode = .convert
    /// `MediaKind.rawValue` → FormatCatalog id. Convert mode: kinds without a target are left alone.
    var targets: [String: String] = [:]
    var overrides = RequestOverrides()
    var destination: RequestDestination = .standard
    var showInFinder = true
    var showInShare = true
    var showInMenuBar = true

    /// Kinds this recipe processes (empty = all).
    var kinds: [MediaKind] {
        switch mode {
        case .upscale: [.image]
        case .compress: targets.isEmpty ? [] : targets.keys.compactMap(MediaKind.init(rawValue:))
        case .convert: MediaKind.allCases.filter { targets[$0.rawValue] != nil }
        }
    }

    func target(for kind: MediaKind) -> FormatDescriptor? {
        let id = targets[kind.rawValue] ?? (kind == .document ? targets[MediaKind.image.rawValue] : nil)
        return id.flatMap(FormatCatalog.format)
    }

    var summary: RecipeSummary {
        RecipeSummary(id: id, name: name, symbol: symbol, mode: mode, kinds: kinds, showInFinder: showInFinder, showInShare: showInShare)
    }

    /// One line describing what the recipe does ("Images → WebP · 1920 px · sans métadonnées").
    var detail: String {
        var parts: [String] = []
        switch mode {
        case .convert:
            let t = MediaKind.allCases.compactMap { k in targets[k.rawValue].flatMap(FormatCatalog.format).map { "\(k.label) → \($0.name)" } }
            parts.append(t.isEmpty ? "Conversion" : t.joined(separator: ", "))
        case .compress: parts.append("Compression")
        case .upscale: parts.append("Agrandissement ×2")
        }
        let o = overrides
        if let p = o.preset { parts.append(p.label) }
        if let q = o.quality { parts.append("qualité \(q)") }
        if let d = o.maxDimension { parts.append("≤ \(d) px") }
        if let k = o.targetSizeKB { parts.append(k >= 1024 ? "≤ \(k / 1024) Mo" : "≤ \(k) Ko") }
        if let m = o.metadata { parts.append(m == .stripAll ? "sans métadonnées" : m == .keepAll ? "métadonnées conservées" : "métadonnées essentielles") }
        if o.replaceOriginals == true { parts.append("remplace les originaux") }
        if destination != .standard { parts.append(destination.label.lowercased()) }
        return parts.joined(separator: " · ")
    }

    /// Fixed ids: until the preferences are saved again, every process (app, CLI, extensions' menu.json) sees the same recipes.
    static let examples: [Recipe] = [
        Recipe(id: UUID(uuidString: "6F0A1E2B-0001-4F6D-9A3B-7C1E5D2A9B01")!, name: "Web", symbol: "globe", mode: .convert, targets: [MediaKind.image.rawValue: "WEBP", MediaKind.video.rawValue: "MP4"],
               overrides: RequestOverrides(preset: .webOptimized, maxDimension: 1920, metadata: .stripAll)),
        Recipe(id: UUID(uuidString: "6F0A1E2B-0002-4F6D-9A3B-7C1E5D2A9B02")!, name: "E-mail", symbol: "envelope", mode: .convert, targets: [MediaKind.image.rawValue: "JPEG", MediaKind.office.rawValue: "PDFDOC"],
               overrides: RequestOverrides(maxDimension: 2048, targetSizeKB: 500, metadata: .keepEssential)),
        Recipe(id: UUID(uuidString: "6F0A1E2B-0003-4F6D-9A3B-7C1E5D2A9B03")!, name: "Archive", symbol: "archivebox", mode: .convert, targets: [MediaKind.image.rawValue: "HEIC"],
               overrides: RequestOverrides(preset: .maximumQuality, metadata: .keepAll), showInShare: false),
    ]

    static let symbols = ["wand.and.stars", "globe", "envelope", "archivebox", "photo", "film", "music.note", "doc.text", "paperplane",
                          "bolt", "star", "heart", "tag", "camera", "printer", "iphone", "display", "leaf", "flame", "briefcase"]
}

extension Array where Element == Recipe {
    func named(_ name: String) -> Recipe? {
        let n = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return first { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == n }
            ?? first { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).hasPrefix(n) }
    }
}
