import Foundation

/// Content of `menu.json`: everything the extensions need to build their menus without opening the preferences
/// (which they cannot read from the sandbox). Written by the app whenever a relevant setting or the history changes.
struct MenuConfig: Codable, Equatable, Sendable {
    var version = 1
    var enabled = true
    /// Favourite output formats per input kind (`MediaKind.rawValue` → FormatCatalog ids), in menu order.
    var favorites: [String: [String]] = MenuConfig.defaultFavorites
    /// Most used output formats per input kind, from the history (only used when `rankByHabits`).
    var ranked: [String: [String]] = [:]
    var rankByHabits = true
    var showCompress = true
    var showCompressPresets = true
    var showUpscale = true
    var showRecipes = true
    var showUndo = true
    var showOpenInForma = true
    var showIcons = true
    /// Favourites shown directly in the context menu, outside the Forma submenu (0…3).
    var topLevelCount = 0
    /// Current image compression preset (shown in the "Compresser" title).
    var compressPreset: CompressionPreset = .balanced
    var libreOffice = false
    var upscaleAvailable = true
    /// Where the Share extension's "dossier des partages" points (Downloads by default).
    var sharesFolder: String?
    var recipes: [RecipeSummary] = []
    /// Last batch started from the Finder or the Share menu that can still be undone.
    var lastBatch: BatchSummary?

    static let defaultFavorites: [String: [String]] = [
        MediaKind.image.rawValue: ["JPEG", "WEBP", "PNG"],
        MediaKind.document.rawValue: ["PNG", "JPEG"],
        MediaKind.video.rawValue: ["MP4", "GIFV"],
        MediaKind.audio.rawValue: ["MP3", "M4A"],
        MediaKind.office.rawValue: ["PDFDOC", "DOCX", "MD"],
    ]

    func favorites(for kind: MediaKind) -> [String] { favorites[kind.rawValue] ?? Self.defaultFavorites[kind.rawValue] ?? [] }
}

struct RecipeSummary: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var mode: ProcessMode
    /// Kinds the recipe accepts (empty = every kind).
    var kinds: [MediaKind]
    var showInFinder: Bool
    var showInShare: Bool

    func accepts(_ kind: MediaKind) -> Bool {
        kinds.isEmpty || kinds.contains(kind) || (kind == .document && kinds.contains(.image))
    }
}

struct BatchSummary: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var date: Date
    var count: Int
}

enum MenuConfigStore {
    static func encode(_ c: MenuConfig) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try? e.encode(c)
    }

    static func decode(_ data: Data) -> MenuConfig? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(MenuConfig.self, from: data)
    }

    /// Reads menu.json, re-reading only when the file changed since the last call.
    final class Reader: @unchecked Sendable {
        private var cached = MenuConfig()
        private var stamp: Date?
        private let lock = NSLock()

        var config: MenuConfig {
            lock.lock(); defer { lock.unlock() }
            guard let url = GroupContainer.menuConfigURL else { return cached }
            let m = url.modificationDate
            if m != stamp, let data = try? Data(contentsOf: url), let c = MenuConfigStore.decode(data) {
                cached = c
                stamp = m
            }
            return cached
        }

        func invalidate() { lock.lock(); stamp = nil; lock.unlock() }
    }
}
