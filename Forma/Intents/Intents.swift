import AppIntents
import Foundation
import UniformTypeIdentifiers

struct FormatOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] { FormatCatalog.all.map(\.id) }
}

enum ShortcutCompressionPreset: String, AppEnum {
    case maximum_quality, high_quality, balanced, web_optimized, social_media, maximum_compression, custom
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Préréglage de compression"
    static let caseDisplayRepresentations: [ShortcutCompressionPreset: DisplayRepresentation] = [
        .maximum_quality: "Qualité maximale",
        .high_quality: "Haute qualité",
        .balanced: "Équilibré",
        .web_optimized: "Optimisé web",
        .social_media: "Réseaux sociaux",
        .maximum_compression: "Compression maximale",
        .custom: "Personnalisé",
    ]
}

enum IntentRunner {
    static func urls(from files: [IntentFile]) throws -> [URL] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-Intents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return try files.map { f in
            if let u = f.fileURL { return u }
            let u = tmp.appendingPathComponent(f.filename)
            try f.data.write(to: u)
            return u
        }
    }

    static func run(_ urls: [URL], mode: ProcessMode, snapshot: ProcessingSnapshot, target: FormatDescriptor?) async throws -> [IntentFile] {
        var out: [IntentFile] = []
        for (i, u) in Pipeline.expand(urls).enumerated() {
            let r = try await Pipeline.run(input: u, mode: mode, snapshot: snapshot, index: i + 1, targetOverride: target) { _ in }
            let files = r.outputs.isEmpty ? [u] : r.outputs
            out += files.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: UTType(filenameExtension: $0.pathExtension)) }
        }
        return out
    }
}

struct ConvertFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convertir des fichiers"
    static let description = IntentDescription("Convertit images, vidéos et audio localement avec Forma.")
    static let openAppWhenRun = false

    @Parameter(title: "Fichiers", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Format de sortie", optionsProvider: FormatOptionsProvider())
    var outputFormat: String

    @Parameter(title: "Qualité (1–100)", inclusiveRange: (1, 100))
    var quality: Int?

    @Parameter(title: "Supprimer les métadonnées", default: false)
    var removeMetadata: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Convertir \(\.$files) en \(\.$outputFormat)") {
            \.$quality
            \.$removeMetadata
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard let format = FormatCatalog.resolve(outputFormat) else { throw ToolError("Format inconnu : \(outputFormat)") }
        var snap = PreferencesStore.loadSnapshot().processing
        if let quality {
            snap.image.preset = .custom; snap.image.customQuality = quality
            snap.video.preset = .custom; snap.video.quality = quality
            snap.compressWhileConverting = true
        }
        if removeMetadata { snap.image.metadata = .stripAll }
        let result = try await IntentRunner.run(try IntentRunner.urls(from: files), mode: .convert, snapshot: snap, target: format)
        return .result(value: result)
    }
}

struct CompressFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compresser des fichiers"
    static let description = IntentDescription("Réduit la taille des images, vidéos, audio et PDF avec Forma.")
    static let openAppWhenRun = false

    @Parameter(title: "Fichiers", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Préréglage", default: .balanced)
    var preset: ShortcutCompressionPreset

    @Parameter(title: "Qualité personnalisée", inclusiveRange: (1, 100))
    var customQuality: Int?

    @Parameter(title: "Supprimer les métadonnées", default: false)
    var removeMetadata: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Compresser \(\.$files) (\(\.$preset))") {
            \.$customQuality
            \.$removeMetadata
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        var snap = PreferencesStore.loadSnapshot().processing
        snap.image.preset = CompressionPreset(rawValue: preset.rawValue) ?? .balanced
        if let customQuality { snap.image.preset = .custom; snap.image.customQuality = customQuality }
        if removeMetadata { snap.image.metadata = .stripAll }
        snap.output.replaceOriginals = false
        let result = try await IntentRunner.run(try IntentRunner.urls(from: files), mode: .compress, snapshot: snap, target: nil)
        return .result(value: result)
    }
}

struct UpscaleImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Agrandir des images ×2"
    static let description = IntentDescription("Double la définition des images par super-résolution IA, sur le Neural Engine, avec Forma.")
    static let openAppWhenRun = false

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var files: [IntentFile]

    @Parameter(title: "Format de sortie", description: "Laisser vide pour garder le format d'origine.", optionsProvider: FormatOptionsProvider())
    var format: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Agrandir \(\.$files) ×2") { \.$format }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        var snap = PreferencesStore.loadSnapshot().processing
        snap.output.replaceOriginals = false
        let target = format.flatMap(FormatCatalog.resolve).flatMap { $0.kind == .image ? $0 : nil }
        let result = try await IntentRunner.run(try IntentRunner.urls(from: files), mode: .upscale, snapshot: snap, target: target)
        return .result(value: result)
    }
}

struct FormaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertFilesIntent(), phrases: ["Convertir avec \(.applicationName)", "Convert files with \(.applicationName)"],
                    shortTitle: "Convertir", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: CompressFilesIntent(), phrases: ["Compresser avec \(.applicationName)", "Compress files with \(.applicationName)"],
                    shortTitle: "Compresser", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: UpscaleImagesIntent(), phrases: ["Agrandir avec \(.applicationName)", "Upscale images with \(.applicationName)"],
                    shortTitle: "Agrandir ×2", systemImageName: "sparkles")
    }
}
