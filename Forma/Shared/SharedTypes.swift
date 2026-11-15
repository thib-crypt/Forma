import Foundation

// Types shared by the app, the Finder extension and the Share extension (no AppKit/SwiftUI here).

enum CompressionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case maximumQuality = "maximum_quality", highQuality = "high_quality", balanced, webOptimized = "web_optimized"
    case socialMedia = "social_media", maximumCompression = "maximum_compression", custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .maximumQuality: "Qualité maximale"
        case .highQuality: "Haute qualité"
        case .balanced: "Équilibré"
        case .webOptimized: "Optimisé web"
        case .socialMedia: "Réseaux sociaux"
        case .maximumCompression: "Compression maximale"
        case .custom: "Personnalisé"
        }
    }
    var detail: String {
        switch self {
        case .maximumQuality: "Archivage, impression, masters"
        case .highQuality: "Sites pro et portfolios"
        case .balanced: "Usage web général, documentation"
        case .webOptimized: "Sites au chargement rapide"
        case .socialMedia: "Instagram, X, Facebook (≤ 2048 px)"
        case .maximumCompression: "E-mails, connexions lentes"
        case .custom: "Qualité choisie manuellement"
        }
    }
    /// Quality 0…100
    func quality(custom: Int) -> Int {
        switch self {
        case .maximumQuality: 92
        case .highQuality: 85
        case .balanced: 78
        case .webOptimized: 70
        case .socialMedia: 75
        case .maximumCompression: 55
        case .custom: custom
        }
    }
    var maxDimension: Int? { self == .socialMedia ? 2048 : nil }
}

enum MetadataMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepAll, keepEssential, stripAll
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keepAll: "Tout conserver"
        case .keepEssential: "Essentiel seulement"
        case .stripAll: "Tout supprimer"
        }
    }
    var help: String {
        switch self {
        case .keepAll: "Conserve EXIF, GPS, auteur, profil colorimétrique."
        case .keepEssential: "Garde date, appareil, copyright et profil couleur ; retire le GPS et le reste."
        case .stripAll: "Fichiers les plus légers, sans appareil, date ni copyright."
        }
    }
}

enum ProcessMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case convert, compress, upscale
    var id: String { rawValue }
    var label: String {
        switch self {
        case .convert: "Convertir"
        case .compress: "Compresser"
        case .upscale: "Agrandir"
        }
    }
    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .upscale: "arrow.up.left.and.arrow.down.right"
        }
    }
    /// Past participle used in summaries and notifications.
    var doneLabel: String {
        switch self {
        case .convert: "Conversion terminée"
        case .compress: "Compression terminée"
        case .upscale: "Agrandissement terminé"
        }
    }
}
