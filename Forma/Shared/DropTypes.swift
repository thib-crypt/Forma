import Foundation

// Types shared with the Finder and Share extensions: they only describe *what* to send to Drop.
// The network code lives in Core/Drop.swift (app and CLI only).

/// How long a link stays valid (Drop deletes the file once expired).
enum DropExpiry: String, Codable, CaseIterable, Identifiable, Sendable {
    case never, hour, day, week, month

    var id: String { rawValue }

    var seconds: Int? {
        switch self {
        case .never: nil
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    var label: String {
        switch self {
        case .never: "Jamais"
        case .hour: "1 heure"
        case .day: "1 jour"
        case .week: "7 jours"
        case .month: "30 jours"
        }
    }

    /// "1h", "1d", "7d", "30d", "never" (CLI) — also accepts "3600", "2h", "12h", "90m".
    static func parse(_ s: String) -> DropExpiry? {
        let v = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let e = DropExpiry(rawValue: v) { return e }
        switch v {
        case "0", "none", "no", "jamais", "off": return .never
        case "1h", "60m", "hour", "heure": return .hour
        case "1d", "24h", "day", "jour": return .day
        case "7d", "1w", "week", "semaine": return .week
        case "30d", "1m", "month", "mois": return .month
        default: return nil
        }
    }
}

/// What a request or a recipe asks for once the files are ready: send them to Drop. `nil` fields = Settings › Drop.
struct DropOptions: Codable, Hashable, Sendable {
    var expiry: DropExpiry?
    var copyLink: Bool?
    var openLink: Bool?

    init(expiry: DropExpiry? = nil, copyLink: Bool? = nil, openLink: Bool? = nil) {
        self.expiry = expiry
        self.copyLink = copyLink
        self.openLink = openLink
    }
}

/// What the menus need to know about Drop (written into menu.json by the app).
struct DropMenuConfig: Codable, Equatable, Sendable {
    var finder = true
    var share = true
    var expiry: DropExpiry = .never
    var host = ""
}

enum DropLinkStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `https://drop…/<clé>`: the share page in a browser, the raw file for everything else (Drop negotiates).
    case page
    /// `https://drop…/<clé>?raw`: always the raw bytes (to embed an image, a video…).
    case direct
    var id: String { rawValue }
    var label: String { self == .page ? "Page de partage" : "Fichier direct" }
}

/// Building and reading Drop URLs (shared so the tests cover it).
enum DropLinks {
    private static let allowed: CharacterSet = {
        var a = CharacterSet.alphanumerics
        a.insert(charactersIn: "-_.!~*'()")
        return a
    }()

    /// Same encoding as the dashboard (`encodeURIComponent` per segment, slashes kept).
    static func encode(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
    }

    static func url(base: URL, key: String, style: DropLinkStyle) -> String {
        base.absoluteString + "/" + encode(key) + (style == .direct ? "?raw" : "")
    }

    /// Recovers the key from a Drop URL (`https://drop…/Ab3dEf/photo.png?raw`), or returns the text as a key.
    static func key(from text: String, base: URL?) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: s), url.scheme != nil, url.host() != nil {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            s = (comps?.percentEncodedPath ?? url.path)
            if s.hasPrefix("/") { s.removeFirst() }
            if s.hasPrefix("v/") || s.hasPrefix("f/") { s.removeFirst(2) }
        }
        return s.removingPercentEncoding ?? s
    }
}
