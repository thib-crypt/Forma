import Foundation

// A job handed to Forma by the Finder extension, the Share extension, a Service, the CLI or a `forma://` URL.
// Written as JSON into the App Group inbox; only the request id travels in the URL.

enum RequestSource: String, Codable, Sendable {
    case finder, share, service, url, cli, menuBar, shortcut
}

enum RequestAction: String, Codable, Sendable {
    case process        // convert / compress / upscale with `mode` + `target`
    case recipe         // apply `recipe`
    case open           // add the files to the main window (the old behaviour)
    case undo           // undo `batch` (or the last batch started outside the window)
    case watch          // watch `paths[0]` (opens the Automation settings, pre-filled)
    case clipboard      // run the clipboard optimizer now
    case showApp        // bring Forma to the front
    case settings       // open the Finder settings tab
    case upload         // send the files as they are to Drop (any type, folders are zipped)
    case refresh        // re-publish the menu configuration (after `forma drop login`)
}

enum RequestDestination: Codable, Hashable, Sendable {
    case standard               // the output settings of the app
    case alongside              // next to each original
    case folder(String)
    case clipboard              // next to the original (or the shares folder) + copied to the clipboard

    var label: String {
        switch self {
        case .standard: "Réglages de sortie"
        case .alongside: "À côté de l'original"
        case .folder(let p): (p as NSString).lastPathComponent
        case .clipboard: "Presse-papiers"
        }
    }
}

/// Settings a request (or a recipe) changes on top of the current preferences. `nil` = keep the preference.
struct RequestOverrides: Codable, Hashable, Sendable {
    var preset: CompressionPreset?
    var quality: Int?                 // 1…100, images and video
    var maxDimension: Int?            // fit within N × N (images)
    var targetSizeKB: Int?            // images: compress until ≤ target
    var metadata: MetadataMode?
    var compressWhileConverting: Bool?
    var replaceOriginals: Bool?       // compression in place (originals go to the Trash)
    var watermark: Bool?

    var isEmpty: Bool { self == RequestOverrides() }
}

struct ExternalRequest: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var source: RequestSource
    var action: RequestAction = .process
    var mode: ProcessMode = .convert
    /// FormatCatalog id. `nil` = the default target of each file's kind.
    var target: String?
    /// Only process files of these kinds (mixed selections, "les images du dossier").
    var kinds: [MediaKind]?
    var recipe: UUID?
    var batch: UUID?
    var paths: [String] = []
    /// Folders are expanded recursively unless `false` ("les images de ce dossier").
    var recursive: Bool?
    /// Copies made by the Share extension for items that had no file on disk. Deleted after the job.
    var stagedDirectory: String?
    var overrides: RequestOverrides?
    var destination: RequestDestination?
    /// Select the results in the Finder when done. `nil` = Finder settings.
    var reveal: Bool?
    /// Send the results (or, for `.upload`, the files themselves) to Drop. `nil` = don't.
    var drop: DropOptions?

    init(source: RequestSource, action: RequestAction = .process, mode: ProcessMode = .convert, target: String? = nil,
         paths: [String] = []) {
        self.source = source
        self.action = action
        self.mode = mode
        self.target = target
        self.paths = paths
    }
}

enum RequestCodec {
    static func encode(_ r: ExternalRequest) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(r)
    }
    static func decode(_ data: Data) throws -> ExternalRequest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ExternalRequest.self, from: data)
    }
}
