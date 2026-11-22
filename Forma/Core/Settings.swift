import Foundation
import SwiftUI

// MARK: - Image settings

enum ResizeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, fit, width, height, exact, fill, percent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Ne pas redimensionner"
        case .fit: "Tenir dans un cadre"
        case .width: "Largeur fixe"
        case .height: "Hauteur fixe"
        case .exact: "Dimensions exactes (marges)"
        case .fill: "Étirer aux dimensions"
        case .percent: "Pourcentage"
        }
    }
    var help: String {
        switch self {
        case .none: "Les dimensions d'origine sont conservées."
        case .fit: "Réduit chaque image jusqu'à ce qu'elle tienne dans le cadre (les petites images ne sont pas agrandies)."
        case .width: "La hauteur est calculée pour garder les proportions."
        case .height: "La largeur est calculée pour garder les proportions."
        case .exact: "Tient dans les dimensions exactes, avec un fond pour compléter."
        case .fill: "Étire/compresse aux dimensions exactes (peut déformer)."
        case .percent: "Met l'image à l'échelle d'un pourcentage."
        }
    }
}

enum OrientationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case autoFix, keepTag
    var id: String { rawValue }
    var label: String { self == .autoFix ? "Corriger automatiquement" : "Conserver le tag" }
    var help: String {
        self == .autoFix ? "Pivote physiquement les pixels et retire le tag d'orientation." : "Garde le tag d'orientation d'origine dans les métadonnées."
    }
}

enum ColorSpaceTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, sRGB, displayP3, adobeRGB, proPhoto, rec709, rec2020, gray
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: "Conserver"
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB (1998)"
        case .proPhoto: "ProPhoto RGB"
        case .rec709: "Rec. 709"
        case .rec2020: "Rec. 2020"
        case .gray: "Niveaux de gris"
        }
    }
    var detail: String {
        switch self {
        case .keep: "Aucune conversion"
        case .sRGB: "Web et la plupart des écrans"
        case .displayP3: "Gamut large des écrans Apple"
        case .adobeRGB: "Espace pro pour l'impression"
        case .proPhoto: "Gamut très large, photographie"
        case .rec709: "Standard HDTV et vidéo"
        case .rec2020: "UHD / HDR"
        case .gray: "Noir et blanc"
        }
    }
    var cgName: CFString? {
        switch self {
        case .keep: nil
        case .sRGB: CGColorSpace.sRGB
        case .displayP3: CGColorSpace.displayP3
        case .adobeRGB: CGColorSpace.adobeRGB1998
        case .proPhoto: CGColorSpace.rommrgb
        case .rec709: CGColorSpace.itur_709
        case .rec2020: CGColorSpace.itur_2020
        case .gray: CGColorSpace.genericGrayGamma2_2
        }
    }
}

enum RenderingIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case perceptual, relative, saturation, absolute
    var id: String { rawValue }
    var label: String {
        switch self {
        case .perceptual: "Perceptuel"
        case .relative: "Colorimétrique relatif"
        case .saturation: "Saturation"
        case .absolute: "Colorimétrique absolu"
        }
    }
    var cg: CGColorRenderingIntent {
        switch self {
        case .perceptual: .perceptual
        case .relative: .relativeColorimetric
        case .saturation: .saturation
        case .absolute: .absoluteColorimetric
        }
    }
}

enum WatermarkPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight, tiled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: "Haut gauche"
        case .top: "Haut"
        case .topRight: "Haut droite"
        case .left: "Gauche"
        case .center: "Centre"
        case .right: "Droite"
        case .bottomLeft: "Bas gauche"
        case .bottom: "Bas"
        case .bottomRight: "Bas droite"
        case .tiled: "Mosaïque"
        }
    }
}

struct WatermarkSettings: Codable, Equatable, Sendable {
    var enabled = false
    var imagePath: String? = nil
    var opacity: Double = 0.6          // 0…1
    var relativeSize: Double = 0.18     // fraction of the image width
    var margin: Double = 0.03           // fraction of the shortest side
    var position: WatermarkPosition = .bottomRight
    var applyToVideos = false
}

struct ImageSettings: Codable, Equatable, Sendable {
    var preset: CompressionPreset = .balanced
    var customQuality: Int = 80
    var targetFileSizeKB: Int? = nil                // compress until ≤ target
    var lossyPNG = true                              // pngquant (when installed)
    var progressiveJPEG = true
    var useMozJPEG = true
    var effort: Int = 6                              // WebP/AVIF/JXL effort 1…9

    var resizeMode: ResizeMode = .none
    var width: Int = 1920
    var height: Int = 1080
    var percent: Int = 50
    var upscale = false

    var dpi: Int? = nil                              // tag only
    var colorSpace: ColorSpaceTarget = .keep
    var renderingIntent: RenderingIntent = .perceptual
    var orientation: OrientationMode = .autoFix
    var metadata: MetadataMode = .keepEssential
    var backgroundHex: String = "#FFFFFF"            // used when flattening alpha
    var copyrightEnabled = false
    var copyright: String = ""
    var artist: String = ""
    var watermark = WatermarkSettings()
    var pdfPerPage = true                           // PDF → image: one file per page
    var pdfDPI: Int = 200
    var animatedFrames = true                        // keep animation when possible

    func quality() -> Int { preset.quality(custom: customQuality) }
}

// MARK: - Video settings

enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264, hevc, av1, vp9, prores
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .prores: "ProRes 422"
        }
    }
    var hardware: String? {
        switch self {
        case .h264: "h264_videotoolbox"
        case .hevc: "hevc_videotoolbox"
        case .prores: "prores_videotoolbox"
        default: nil
        }
    }
    var software: String {
        switch self {
        case .h264: "libx264"
        case .hevc: "libx265"
        case .av1: "libsvtav1"
        case .vp9: "libvpx-vp9"
        case .prores: "prores_ks"
        }
    }
}

enum EncodingSpeed: String, Codable, CaseIterable, Identifiable, Sendable {
    case ultrafast, veryfast, fast, medium, slow, slower
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ultrafast: "Ultra-rapide"
        case .veryfast: "Très rapide"
        case .fast: "Rapide"
        case .medium: "Moyen (équilibré)"
        case .slow: "Lent"
        case .slower: "Plus lent (meilleure qualité)"
        }
    }
    var svtPreset: Int { [12, 10, 8, 6, 4, 3][EncodingSpeed.allCases.firstIndex(of: self)!] }
    var vpxSpeed: Int { [8, 6, 4, 2, 1, 0][EncodingSpeed.allCases.firstIndex(of: self)!] }
}

enum VideoResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, p2160, p1440, p1080, p720, p480, p360
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Originale"
        case .p2160: "4K (2160p)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        }
    }
    var height: Int? { ["original": nil, "p2160": 2160, "p1440": 1440, "p1080": 1080, "p720": 720, "p480": 480, "p360": 360][rawValue]! }
}

enum VideoPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case best, excellent, good, minimum, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: "Meilleure qualité"
        case .excellent: "Excellente"
        case .good: "Bonne (recommandé)"
        case .minimum: "Taille minimale"
        case .custom: "Personnalisé"
        }
    }
    var detail: String {
        switch self {
        case .best: "HEVC, qualité maximale, encodage lent"
        case .excellent: "HEVC, excellente qualité"
        case .good: "HEVC, bon équilibre qualité/poids"
        case .minimum: "HEVC, fichier le plus petit"
        case .custom: "Codec et qualité choisis manuellement"
        }
    }
    /// Quality 0…100 (100 = visually lossless)
    var quality: Int? { [ "best": 80, "excellent": 68, "good": 58, "minimum": 42, "custom": nil ][rawValue]! }
}

struct VideoSettings: Codable, Equatable, Sendable {
    var preset: VideoPreset = .good
    var codec: VideoCodec = .hevc
    var quality: Int = 60                     // 0…100
    var speed: EncodingSpeed = .medium
    var hardwareAcceleration = true
    var resolution: VideoResolution = .original
    var frameRate: Int? = nil                 // nil = keep
    var playbackSpeed: Double = 1.0           // 0.25…4
    var removeAudio = false
    var audioBitrate: Int = 160
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    var burnSubtitles = false                 // otherwise soft-mux when container allows
    var autoAttachSubtitles = true            // pick up foo.srt/foo.vtt next to foo.mp4
    var gifFPS: Int = 15
    var gifWidth: Int = 640
    var gifColors: Int = 256
    var gifLoop = true

    var effectiveQuality: Int { preset.quality ?? quality }
    var effectiveCodec: VideoCodec { preset == .custom ? codec : .hevc }
}

// MARK: - Audio settings

enum AudioBitrateMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cbr, vbr, abr
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cbr: "CBR (débit constant)"
        case .vbr: "VBR (débit variable)"
        case .abr: "ABR (débit moyen)"
        }
    }
}

enum AudioPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case voice, standard, cd, high, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .voice: "Mémo vocal"
        case .standard: "Standard"
        case .cd: "Qualité CD"
        case .high: "Haute qualité"
        case .custom: "Personnalisé"
        }
    }
    var detail: String {
        switch self {
        case .voice: "64 kb/s mono, idéal pour la parole"
        case .standard: "128 kb/s, bonne qualité et taille"
        case .cd: "192 kb/s, 44,1 kHz"
        case .high: "256 kb/s, transparent"
        case .custom: "Débit choisi manuellement"
        }
    }
    var bitrate: Int? { ["voice": 64, "standard": 128, "cd": 192, "high": 256, "custom": nil][rawValue]! }
}

struct AudioSettings: Codable, Equatable, Sendable {
    var preset: AudioPreset = .standard
    var bitrate: Int = 192
    var mode: AudioBitrateMode = .vbr
    var sampleRate: Int? = nil              // nil = keep
    var mono = false
    var normalize = false
    var embedCoverArt = true                // cover.jpg/folder.jpg from the source folder
    var skipIfArtwork = true
    var compressCodec: String = "AAC"       // codec used by "compress" for audio

    var effectiveBitrate: Int { preset.bitrate ?? bitrate }
    var effectiveMono: Bool { preset == .voice ? true : mono }
}

// MARK: - Output

enum OutputDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case alongside, subfolder, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alongside: "À côté de l'original"
        case .subfolder: "Dans un sous-dossier"
        case .custom: "Dans un dossier précis"
        }
    }
}

enum ConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case rename, overwrite, skip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rename: "Renommer (ajouter un numéro)"
        case .overwrite: "Écraser"
        case .skip: "Ignorer le fichier"
        }
    }
}

struct OutputSettings: Codable, Equatable, Sendable {
    var destination: OutputDestination = .alongside
    var subfolderName = "Forma"
    var customFolderPath: String? = nil
    var convertPattern = "{original}"
    var compressPattern = "{original}_compressed"
    var upscalePattern = "{original}@2x"
    var samePatternForCompress = false
    var conflict: ConflictPolicy = .rename
    var replaceOriginals = false            // compress in place (original goes to the Trash)
    var deleteOriginals = false             // move originals to Trash after success
    var preserveDates = true
    var revealWhenDone = false
}

/// Per-input-format override for conversions, e.g. "HEIC → JPEG", "MOV → MP4".
struct FormatMapping: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var input: String      // lowercase extension
    var output: String     // format id
}

// MARK: - Presets

struct NamedPreset<T: Codable & Equatable & Sendable>: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var value: T
}

// MARK: - Watched folders / schedule

struct WatchedFolder: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var path: String
    var enabled = true
    var mode: ProcessMode = .compress
    var imageTarget = "WEBP"
    var videoTarget = "MP4"
    var audioTarget = "M4A"
    var officeTarget: String? = nil       // optional: folders saved before documents were supported
    var includeSubfolders = false
    var processExisting = false
    var outputSubfolder = "Forma"
    var lastRun: Date? = nil
    var processedCount = 0
}

struct ScheduledJob: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var paths: [String]
    var mode: ProcessMode
    var date: Date
    var snapshot: ProcessingSnapshot
}

/// Everything a pipeline run needs. Snapshotted when a batch starts so changing settings mid-run is safe.
struct ProcessingSnapshot: Codable, Equatable, Sendable {
    var image = ImageSettings()
    var video = VideoSettings()
    var audio = AudioSettings()
    var output = OutputSettings()
    var imageTarget = "JPEG"
    var videoTarget = "MP4"
    var audioTarget = "MP3"
    var mappings: [FormatMapping] = []
    var compressWhileConverting = false
    var compressAfterConverting = false
    var upscaleTarget = "SAME"          // "SAME" keeps the original format when it can be written losslessly enough
    /// Optional on disk so snapshots saved by older versions (scheduled jobs) still decode.
    var documentTarget: String? = nil
    var officeTarget: String {
        get { documentTarget ?? "PDFDOC" }
        set { documentTarget = newValue }
    }

    func target(for url: URL, kind: MediaKind, mode: ProcessMode) -> FormatDescriptor? {
        if mode == .upscale {
            guard kind == .image else { return nil }
            if upscaleTarget != "SAME", let f = FormatCatalog.format(upscaleTarget) { return f }
            if let f = FileDetection.sameFormat(for: url), f.kind == .image, Self.upscaleKeepable.contains(f.id) { return f }
            return FormatCatalog.format("PNG")
        }
        if mode == .compress {
            if kind == .audio, let f = FormatDescriptor.audioCompressTarget(for: url, codec: audio.compressCodec) { return f }
            return FileDetection.sameFormat(for: url) ?? (kind == .document ? FormatCatalog.format("PDF") : nil)
        }
        let ext = url.pathExtension.lowercased()
        if let m = mappings.first(where: { $0.input == ext }), let f = FormatCatalog.format(m.output) { return f }
        switch kind {
        case .image, .document: return FormatCatalog.format(imageTarget)
        case .video: return FormatCatalog.format(videoTarget)
        case .audio: return FormatCatalog.format(audioTarget)
        case .office: return FormatCatalog.format(officeTarget)
        }
    }
}

extension ProcessingSnapshot {
    /// Formats an upscaled image may keep (raster, single image, good quality writer). Others become PNG.
    static let upscaleKeepable: Set<String> = ["JPEG", "PNG", "HEIC", "TIFF", "WEBP", "AVIF", "JXL", "JP2", "BMP", "PSD", "TGA"]
    static let upscaleChoices = ["SAME", "PNG", "HEIC", "JPEG", "TIFF", "WEBP", "AVIF", "JXL"]
}

extension FormatDescriptor {
    /// Audio compression: lossless sources keep their container when lossy compression makes no sense.
    static func audioCompressTarget(for url: URL, codec: String) -> FormatDescriptor? {
        let ext = url.pathExtension.lowercased()
        if ["mp3", "ogg", "opus", "m4a", "aac"].contains(ext) { return FileDetection.sameFormat(for: url) }
        return FormatCatalog.format(codec)
    }
}

// MARK: - App preferences (persisted)

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { ["system": "Système", "light": "Clair", "dark": "Sombre"][rawValue]! }
}

struct Preferences: Codable, Equatable, Sendable {
    var processing = ProcessingSnapshot()
    var imagePresets: [NamedPreset<ImageSettings>] = []
    var videoPresets: [NamedPreset<VideoSettings>] = []
    var audioPresets: [NamedPreset<AudioSettings>] = []
    var watchedFolders: [WatchedFolder] = []
    var scheduledJobs: [ScheduledJob] = []

    var lastMode: ProcessMode = .convert
    var autoStartOnDrop = false
    var autoCopyResult = false
    var notifyWhenDone = true
    var showInMenuBar = true
    var launchAtLogin = false
    var appearance: AppearanceMode = .system
    var showProgressDetails = false
    var maxParallelImages = 0     // 0 = auto (performance cores)
    var maxParallelVideos = 2

    // Forma 1.1 clipboard settings: only read to migrate into `clipboard`.
    var clipboardEnabled = false
    var clipboardTarget = "WEBP"  // or "SAME"
    var clipboardMaxDimension: Int? = 2560
    var clipboardQuality = 80
    var clipboard = ClipboardSettings()

    var historyEnabled = true
    var historyRetentionDays = 90   // 0 = forever

    // Forma 1.3: Finder & Share integration, recipes.
    var finder = FinderPreferences()
    var recipes: [Recipe] = Recipe.examples

    // Forma 1.4: Drop (self-hosted S3 share service).
    var drop = DropPreferences()

    // Forma 1.5: where Forma lives (Dock / menu bar), what a launch shows, global shortcut.
    var dockIcon: DockIconMode = .always
    var showWindowAtLaunch = true
    var globalHotKey: GlobalHotKey? = nil
    var hotKeyAction: HotKeyAction = .menuBarPanel

    /// The Dock rule actually applied: Forma must stay reachable, so without the menu bar item it can at most
    /// hide its Dock icon while no window is open.
    var effectiveDockIcon: DockIconMode {
        !showInMenuBar && dockIcon == .never ? .withWindows : dockIcon
    }
}

/// When Forma shows an icon in the Dock.
enum DockIconMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case always, withWindows, never
    var id: String { rawValue }
}

/// What the global shortcut does.
enum HotKeyAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case menuBarPanel, mainWindow
    var id: String { rawValue }
    var label: String { self == .menuBarPanel ? "Le panneau de la barre des menus" : "La fenêtre principale" }
}

/// A system-wide shortcut (Carbon key code + Carbon modifier mask), with its display string ("⌃⌥F").
struct GlobalHotKey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
}

/// How jobs started outside the main window report progress.
enum JobFeedback: String, Codable, CaseIterable, Identifiable, Sendable {
    case hud, notification, silent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hud: "Panneau de progression"
        case .notification: "Notification à la fin"
        case .silent: "Rien (icône de la barre des menus)"
        }
    }
}

/// Settings of the Finder menu, the Share extension and the Services (Settings › Finder).
struct FinderPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var favorites: [String: [String]] = MenuConfig.defaultFavorites
    var rankByHabits = true
    var showCompress = true
    var showCompressPresets = true
    var showUpscale = true
    var showRecipes = true
    var showUndo = true
    var showOpenInForma = true
    var showIcons = true
    var topLevelCount = 0
    /// Where results of Finder / Share / Services jobs go (`.standard` = the Output settings).
    var destination: RequestDestination = .standard
    var feedback: JobFeedback = .hud
    var revealWhenDone = false
    /// Results of items shared without a file on disk (Safari, Photos…). nil = Downloads.
    var sharesFolder: String? = nil
    /// Forma ≤ 1.4 "mode discret" (no Dock icon while no window is open). Only read to migrate into `dockIcon`.
    var hideDockIconWithoutWindows = false

    func favorites(for kind: MediaKind) -> [String] { favorites[kind.rawValue] ?? MenuConfig.defaultFavorites[kind.rawValue] ?? [] }

    var sharesFolderURL: URL {
        sharesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}

@MainActor
@Observable
final class PreferencesStore {
    static let shared = PreferencesStore()
    private let key = "forma.preferences.v1"

    var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            save()
            if prefs.showInMenuBar != menuBarVisible { menuBarVisible = prefs.showInMenuBar }
            if prefs.appearance != appearance { appearance = prefs.appearance }
            if prefs.historyEnabled != oldValue.historyEnabled { HistoryStore.shared.enabled = prefs.historyEnabled }
            if prefs.effectiveDockIcon != oldValue.effectiveDockIcon {
                DispatchQueue.main.async { LaunchContext.updateDockPolicy(animated: true) }
            }
            if prefs.globalHotKey != oldValue.globalHotKey {
                DispatchQueue.main.async { GlobalHotKeyCenter.shared.reload() }
            }
        }
    }
    /// Mirrors used by scene-level code so the App body doesn't re-evaluate on every settings change.
    var menuBarVisible: Bool
    var appearance: AppearanceMode

    var colorScheme: ColorScheme? { appearance == .system ? nil : appearance == .dark ? .dark : .light }

    private init() {
        var loaded = Preferences()
        if let data = UserDefaults.standard.data(forKey: key), let p = Self.decode(data) {
            loaded = p
            // First launch with rules: carry over the old single-setting optimizer.
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], raw["clipboard"] == nil {
                loaded.clipboard = ClipboardSettings.migrated(enabled: p.clipboardEnabled, target: p.clipboardTarget,
                                                              maxDimension: p.clipboardMaxDimension, quality: p.clipboardQuality)
            }
            // 1.5: the Finder tab's "mode discret" became the Dock setting of the General tab.
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], raw["dockIcon"] == nil,
               p.finder.hideDockIconWithoutWindows {
                loaded.dockIcon = .withWindows
            }
        }
        prefs = loaded
        menuBarVisible = loaded.showInMenuBar
        appearance = loaded.appearance
    }

    private var pendingSave: DispatchWorkItem?
    private func save() {
        pendingSave?.cancel()
        let snapshot = prefs
        let work = DispatchWorkItem { [key] in
            if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: key) }
        }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Read-only access for non-main contexts (CLI, intents).
    nonisolated static func loadSnapshot() -> Preferences {
        // CFPreferences with an explicit domain works even when launched through the CLI symlink.
        if let data = CFPreferencesCopyAppValue("forma.preferences.v1" as CFString, "com.thibault.forma" as CFString) as? Data,
           let p = decode(data) { return p }
        return Preferences()
    }

    /// Tolerant decoding: stored values are merged over the defaults, so settings added in a later
    /// version (missing keys) never reset the user's preferences.
    nonisolated static func decode(_ data: Data) -> Preferences? {
        if let p = try? JSONDecoder().decode(Preferences.self, from: data) { return p }
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(Preferences()),
              let defaults = try? JSONSerialization.jsonObject(with: defData) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: merge(defaults, stored)) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: merged)
    }

    nonisolated private static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] { out[k] = merge(b, o) } else { out[k] = v }
        }
        return out
    }
}
