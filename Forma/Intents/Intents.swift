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
        let batch = UUID()
        for (i, u) in Pipeline.expand(urls).enumerated() {
            let r = try await Pipeline.run(input: u, mode: mode, snapshot: snapshot, index: i + 1, targetOverride: target, origin: .shortcut, batch: batch) { _ in }
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

// MARK: - Recipes, undo, clipboard (Forma 1.3)

struct RecipeOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] { PreferencesStore.loadSnapshot().recipes.map(\.name) }
}

struct ApplyRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Appliquer une recette Forma"
    static let description = IntentDescription("Applique une recette (format, qualité, taille, métadonnées, destination) à des fichiers.")
    static let openAppWhenRun = false

    @Parameter(title: "Fichiers", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Recette", optionsProvider: RecipeOptionsProvider())
    var recipe: String

    static var parameterSummary: some ParameterSummary {
        Summary("Appliquer \(\.$recipe) à \(\.$files)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let prefs = PreferencesStore.loadSnapshot()
        guard let r = prefs.recipes.named(recipe) else { throw ToolError("Recette inconnue : \(recipe)") }
        var request = ExternalRequest(source: .shortcut, action: .recipe, paths: try IntentRunner.urls(from: files).map(\.path))
        request.recipe = r.id
        let plan = try RequestPlanner.plan(request, prefs: prefs)
        var out: [IntentFile] = []
        let batch = UUID()
        for (i, f) in plan.files.enumerated() {
            let res = try await Pipeline.run(input: f.url, mode: plan.mode, snapshot: plan.snapshot, index: i + 1, targetOverride: f.target,
                                             outputFolder: f.outputFolder, origin: .shortcut, batch: batch) { _ in }
            if let drop = plan.drop {
                for o in res.outputs { _ = try? await DropUploader.upload(o, options: drop, prefs: prefs.drop, origin: .shortcut, batch: batch, entry: res.historyID) }
            }
            out += (res.outputs.isEmpty ? [f.url] : res.outputs).map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: UTType(filenameExtension: $0.pathExtension)) }
        }
        return .result(value: out)
    }
}

enum ShortcutDropExpiry: String, AppEnum {
    case settings, never, hour, day, week, month
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Expiration du lien"
    static let caseDisplayRepresentations: [ShortcutDropExpiry: DisplayRepresentation] = [
        .settings: "Selon les réglages Drop", .never: "Jamais", .hour: "1 heure", .day: "1 jour", .week: "7 jours", .month: "30 jours",
    ]
    var expiry: DropExpiry? { self == .settings ? nil : DropExpiry(rawValue: rawValue) }
}

struct SendToDropIntent: AppIntent {
    static let title: LocalizedStringResource = "Envoyer sur Drop"
    static let description = IntentDescription("Envoie des fichiers tels quels sur votre serveur Drop et renvoie les liens de partage.")
    static let openAppWhenRun = false

    @Parameter(title: "Fichiers", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Expiration", default: .settings)
    var expiry: ShortcutDropExpiry

    @Parameter(title: "Copier le lien", default: true)
    var copyLink: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Envoyer \(\.$files) sur Drop") {
            \.$expiry
            \.$copyLink
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[URL]> {
        let prefs = PreferencesStore.loadSnapshot().drop
        guard DropServer.isConfigured(prefs) else { throw DropError.notConfigured }
        var options = DropOptions()
        options.expiry = expiry.expiry
        let batch = UUID()
        var links: [URL] = []
        for u in try IntentRunner.urls(from: files) {
            let up = try await DropUploader.upload(u, options: options, prefs: prefs, origin: .shortcut, batch: batch)
            if let link = URL(string: up.url) { links.append(link) }
        }
        if copyLink, !links.isEmpty { await MainActor.run { DropUploader.copy(links.map(\.absoluteString)) } }
        return .result(value: links)
    }
}

struct UndoLastBatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Annuler le dernier traitement Forma"
    static let description = IntentDescription("Met les derniers résultats à la Corbeille et remet les originaux en place.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let all = HistoryStore.shared.fetch()
        guard let first = all.first(where: { !$0.isUndone }) else { return .result(value: "Rien à annuler.") }
        let batch = first.batch.map { b in all.filter { $0.batch == b && !$0.isUndone } } ?? [first]
        var done: [UUID] = []
        for e in batch { if (try? HistoryUndo.undo(e)) != nil { done.append(e.id) } }
        HistoryStore.shared.markUndone(done)
        let remote = DropUploader.records(forEntries: done).filter { !$0.isDeleted }
        if !remote.isEmpty { await DropUploader.delete(remote, prefs: PreferencesStore.loadSnapshot().drop) }
        return .result(value: "\(done.count) traitement\(done.count > 1 ? "s" : "") annulé\(done.count > 1 ? "s" : "").")
    }
}

struct OptimizeClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Optimiser le presse-papiers avec Forma"
    static let description = IntentDescription("Applique les règles de l'optimiseur à l'image du presse-papiers.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        ClipboardOptimizer.shared.optimizeNow()
        return .result()
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
        AppShortcut(intent: ApplyRecipeIntent(), phrases: ["Appliquer une recette \(.applicationName)", "Apply a \(.applicationName) recipe"],
                    shortTitle: "Recette", systemImageName: "wand.and.stars")
        AppShortcut(intent: SendToDropIntent(), phrases: ["Envoyer sur Drop avec \(.applicationName)", "Send to Drop with \(.applicationName)"],
                    shortTitle: "Envoyer sur Drop", systemImageName: "arrow.up.circle")
        AppShortcut(intent: UndoLastBatchIntent(), phrases: ["Annuler le dernier traitement \(.applicationName)", "Undo last \(.applicationName) batch"],
                    shortTitle: "Annuler", systemImageName: "arrow.uturn.backward")
        AppShortcut(intent: OptimizeClipboardIntent(), phrases: ["Optimiser le presse-papiers avec \(.applicationName)"],
                    shortTitle: "Presse-papiers", systemImageName: "doc.on.clipboard")
    }
}
