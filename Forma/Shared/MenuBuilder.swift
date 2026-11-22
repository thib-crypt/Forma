import Foundation

/// What a menu entry does once clicked (turned into an `ExternalRequest` with the clicked paths).
struct MenuEntry: Hashable, Sendable {
    var action: RequestAction
    var mode: ProcessMode = .convert
    var target: String?
    var kinds: [MediaKind]?
    var recipe: UUID?
    var preset: CompressionPreset?
    var batch: UUID?
    var recursive: Bool?
    /// Send to Drop (after processing for `.process`, as is for `.upload`).
    var drop: DropOptions?
    /// Acts on the folder the menu was opened in (window background), not on the selection.
    var usesContainer = false
}

indirect enum MenuNode: Sendable {
    case item(title: String, symbol: String?, entry: MenuEntry)
    case submenu(title: String, symbol: String?, children: [MenuNode])
    case header(String)
    case separator

    var title: String? {
        switch self {
        case .item(let t, _, _), .submenu(let t, _, _), .header(let t): t
        case .separator: nil
        }
    }
    var children: [MenuNode] { if case .submenu(_, _, let c) = self { c } else { [] } }
    /// Every actionable entry below this node, depth first (used by tests and `forma finder menu`).
    var entries: [(path: [String], entry: MenuEntry)] {
        switch self {
        case .item(let t, _, let e): [([t], e)]
        case .submenu(let t, _, let c): c.flatMap { $0.entries.map { ([t] + $0.path, $0.entry) } }
        default: []
        }
    }
}

enum MenuPlace: Sendable { case items, container, toolbar, sidebar }

/// What is selected, classified by extension only (no file is opened: the menu must appear instantly).
struct SelectionSummary: Sendable, Equatable {
    var counts: [MediaKind: Int] = [:]
    var folders = 0
    var unsupported = 0
    var exts: Set<String> = []
    var scanned = 0
    var truncated = false

    var fileCount: Int { counts.values.reduce(0, +) }
    var kinds: [MediaKind] { MenuBuilder.kindOrder.filter { (counts[$0] ?? 0) > 0 } }
    var isEmpty: Bool { fileCount == 0 && folders == 0 }
}

enum MenuBuilder {
    static let maxScanned = 2000
    static let kindOrder: [MediaKind] = [.image, .document, .video, .audio, .office]
    /// Directory bundles that are documents, not folders.
    static let packageExts: Set<String> = ["rtfd", "pages", "key", "numbers", "webarchive"]
    // Mirrors OfficeEngine (kept here because the extensions don't link the engines).
    static let officeOnlyInputs: Set<String> = ["xls", "xlsm", "ods", "numbers", "ppt", "pps", "ppsx", "odp", "key", "pages", "wpd", "ott"]
    static let officeOnlyOutputs: Set<String> = ["XLSX", "ODS", "CSV", "ODP"]
    static let zipPackages: Set<String> = ["docx", "docm", "dotx", "xlsx", "xlsm", "pptx", "ppsx", "odt", "ott", "ods", "odp", "epub"]
    static let sheetExts: Set<String> = ["xlsx", "xlsm", "xls", "ods", "csv", "tsv", "numbers"]
    static let slideExts: Set<String> = ["pptx", "ppt", "pps", "ppsx", "odp", "key"]

    // MARK: Selection

    static func summarize(_ urls: [URL]) -> SelectionSummary {
        var s = SelectionSummary()
        for url in urls.prefix(maxScanned) {
            s.scanned += 1
            let ext = url.pathExtension.lowercased()
            if isFolder(url, ext: ext) { s.folders += 1; continue }
            if let kind = FileDetection.classify(url).mediaKind {
                s.counts[kind, default: 0] += 1
                s.exts.insert(ext)
            } else {
                s.unsupported += 1
            }
        }
        s.truncated = urls.count > maxScanned
        return s
    }

    static func isFolder(_ url: URL, ext: String) -> Bool {
        if packageExts.contains(ext) { return false }
        if url.hasDirectoryPath { return FileDetection.classify(url) == .unsupported || ext.isEmpty }
        // Finder normally adds the trailing slash; check the disk only for extension-less names.
        guard ext.isEmpty else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: Building

    /// Root-level nodes: the "Forma" submenu, preceded by promoted favourites if enabled.
    static func build(_ sel: SelectionSummary, config: MenuConfig, place: MenuPlace) -> [MenuNode] {
        guard config.enabled else { return [] }
        switch place {
        case .toolbar:
            var nodes = sel.isEmpty ? [] : body(sel, config: config, container: false)
            if !nodes.isEmpty { nodes.append(.separator) }
            nodes.append(.item(title: "Optimiser le presse-papiers", symbol: "doc.on.clipboard", entry: MenuEntry(action: .clipboard)))
            nodes.append(.item(title: "Ouvrir Forma", symbol: "macwindow", entry: MenuEntry(action: .showApp)))
            nodes.append(.item(title: "Réglages du menu Finder…", symbol: "gearshape", entry: MenuEntry(action: .settings)))
            return nodes
        case .container:
            let children = body(SelectionSummary(folders: 1), config: config, container: true)
            return children.isEmpty ? [] : [.submenu(title: "Forma", symbol: "wand.and.sparkles", children: children)]
        case .items, .sidebar:
            let children = body(sel, config: config, container: false)
            guard !children.isEmpty else { return [] }
            var root: [MenuNode] = promoted(sel, config: config)
            root.append(.submenu(title: "Forma", symbol: "wand.and.sparkles", children: children))
            return root
        }
    }

    private static func body(_ sel: SelectionSummary, config: MenuConfig, container: Bool) -> [MenuNode] {
        if sel.folders > 0 || container { return folderMenu(sel, config: config, container: container) }
        let kinds = sel.kinds
        guard !kinds.isEmpty else { return sel.unsupported > 0 ? dropNodes(sel, config: config) : [] }
        return kinds.count == 1 ? singleKindMenu(kinds[0], sel, config: config) : mixedMenu(kinds, sel, config: config)
    }

    // MARK: One kind

    private static func singleKindMenu(_ kind: MediaKind, _ sel: SelectionSummary, config: MenuConfig) -> [MenuNode] {
        var sections: [[MenuNode]] = []
        let outputs = convertOutputs(for: kind, sel: sel, config: config)
        if !outputs.isEmpty {
            var convert: [MenuNode] = topFormats(for: kind, sel: sel, config: config, among: outputs).map { f in
                .item(title: "Convertir en \(f.name)", symbol: kind == .office ? "doc" : ProcessMode.convert.symbol,
                      entry: MenuEntry(action: .process, mode: .convert, target: f.id))
            }
            convert.append(.submenu(title: "Convertir en…", symbol: "ellipsis.circle", children: grouped(outputs, entry: { f in
                MenuEntry(action: .process, mode: .convert, target: f.id)
            })))
            sections.append(convert)
        }

        var process: [MenuNode] = []
        if config.showCompress, canCompress(kind, sel) {
            let title = kind == .image ? "Compresser · \(config.compressPreset.label)" : "Compresser"
            process.append(.item(title: title, symbol: ProcessMode.compress.symbol, entry: MenuEntry(action: .process, mode: .compress)))
            if kind == .image, config.showCompressPresets {
                process.append(.submenu(title: "Compresser avec…", symbol: "slider.horizontal.3", children: presetItems()))
            }
        }
        if config.showUpscale, kind == .image {
            process.append(.item(title: "Agrandir ×2 (IA)", symbol: ProcessMode.upscale.symbol, entry: MenuEntry(action: .process, mode: .upscale)))
        }
        sections.append(process)
        sections.append(dropNodes(sel, config: config, compress: canCompress(kind, sel) ? "Compresser" : nil))
        sections.append(recipeNodes(config, accepting: [kind]))
        sections.append(tail(config))
        return join(sections)
    }

    // MARK: Several kinds

    private static func mixedMenu(_ kinds: [MediaKind], _ sel: SelectionSummary, config: MenuConfig) -> [MenuNode] {
        var sections: [[MenuNode]] = []
        for kind in kinds {
            let outputs = convertOutputs(for: kind, sel: sel, config: config)
            let tops = topFormats(for: kind, sel: sel, config: config, among: outputs).prefix(3)
            guard !tops.isEmpty else { continue }
            let n = sel.counts[kind] ?? 0
            sections.append(tops.map { f in
                .item(title: "\(kind.shortLabel(n)) → \(f.name)", symbol: kind.symbol,
                      entry: MenuEntry(action: .process, mode: .convert, target: f.id, kinds: [kind]))
            })
        }
        if !sections.isEmpty {
            sections.append([.item(title: "Convertir chaque type avec ses réglages par défaut", symbol: ProcessMode.convert.symbol,
                                   entry: MenuEntry(action: .process, mode: .convert))])
        }
        var process: [MenuNode] = []
        if config.showCompress {
            process.append(.item(title: "Compresser les \(sel.fileCount) fichiers", symbol: ProcessMode.compress.symbol,
                                 entry: MenuEntry(action: .process, mode: .compress)))
        }
        if config.showUpscale, kinds.contains(.image) {
            process.append(.item(title: "Agrandir les images ×2 (IA)", symbol: ProcessMode.upscale.symbol,
                                 entry: MenuEntry(action: .process, mode: .upscale, kinds: [.image])))
        }
        sections.append(process)
        sections.append(dropNodes(sel, config: config, compress: "Compresser"))
        sections.append(recipeNodes(config, accepting: kinds))
        sections.append(tail(config))
        return join(sections)
    }

    // MARK: Folders

    private static func folderMenu(_ sel: SelectionSummary, config: MenuConfig, container: Bool) -> [MenuNode] {
        let recursive: Bool? = container ? false : nil
        let scope = container ? "de ce dossier" : sel.folders + sel.fileCount > 1 ? "de la sélection" : "du dossier"
        var convert: [MenuNode] = []
        for kind in [MediaKind.image, .video, .audio, .office] {
            let outputs = FormatCatalog.outputs(for: kind).filter { config.libreOffice || !officeOnlyOutputs.contains($0.id) }
            var children: [MenuNode] = config.favorites(for: kind).compactMap(FormatCatalog.format).map { f in
                .item(title: f.name, symbol: nil, entry: MenuEntry(action: .process, mode: .convert, target: f.id, kinds: [kind],
                                                                   recursive: recursive, usesContainer: container))
            }
            children.append(.separator)
            children.append(.submenu(title: "Tous les formats", symbol: nil, children: grouped(outputs, entry: { f in
                MenuEntry(action: .process, mode: .convert, target: f.id, kinds: [kind], recursive: recursive, usesContainer: container)
            })))
            convert.append(.submenu(title: "Convertir les \(kind.plural) \(scope) en", symbol: kind.symbol, children: children))
        }
        var process: [MenuNode] = []
        if config.showCompress {
            process.append(.item(title: "Compresser les fichiers \(scope)", symbol: ProcessMode.compress.symbol,
                                 entry: MenuEntry(action: .process, mode: .compress, recursive: recursive, usesContainer: container)))
        }
        if config.showUpscale {
            process.append(.item(title: "Agrandir les images \(scope) ×2 (IA)", symbol: ProcessMode.upscale.symbol,
                                 entry: MenuEntry(action: .process, mode: .upscale, kinds: [.image], recursive: recursive, usesContainer: container)))
        }
        var drop = dropNodes(sel, config: config, container: container)
        if container { drop = drop.map { $0.retargeted(container: true, recursive: false) } }
        var recipes = recipeNodes(config, accepting: MediaKind.allCases)
        if container { recipes = recipes.map { $0.retargeted(container: true, recursive: false) } }
        var extra: [MenuNode] = []
        if container || (sel.folders == 1 && sel.fileCount == 0) {
            extra.append(.item(title: "Surveiller ce dossier avec Forma…", symbol: "eye",
                               entry: MenuEntry(action: .watch, usesContainer: container)))
        }
        var t = tail(config)
        if container { t.removeAll { if case .item(_, _, let e) = $0 { e.action == .open } else { false } } }
        return join([convert, process, drop, recipes, extra, t])
    }

    // MARK: Pieces

    /// Outputs offered for a kind, filtered by what can actually be produced from the selected extensions.
    static func convertOutputs(for kind: MediaKind, sel: SelectionSummary, config: MenuConfig) -> [FormatDescriptor] {
        var list = FormatCatalog.outputs(for: kind)
        if kind == .office {
            if !config.libreOffice {
                if !sel.exts.isDisjoint(with: officeOnlyInputs) { return [] }
                list.removeAll { officeOnlyOutputs.contains($0.id) }
            }
            if sel.exts.isSubset(of: sheetExts) {
                list = list.filter { ["PDFDOC", "HTML", "XLSX", "ODS", "CSV"].contains($0.id) }
            } else if sel.exts.isSubset(of: slideExts) {
                list = list.filter { ["PDFDOC", "PPTX", "ODP"].contains($0.id) }
            } else {
                list.removeAll { ["XLSX", "ODS", "CSV"].contains($0.id) }
            }
        }
        return list
    }

    /// Favourites (and habits), minus the format the files are already in.
    static func topFormats(for kind: MediaKind, sel: SelectionSummary, config: MenuConfig, among outputs: [FormatDescriptor]) -> [FormatDescriptor] {
        let allowed = Set(outputs.map(\.id))
        // Every selected file already in one format (jpg + jpeg count as one): don't offer it.
        let sameIDs = Set(sel.exts.map { FileDetection.sameFormat(for: URL(fileURLWithPath: "x.\($0)"))?.id ?? "?\($0)" })
        let same = sameIDs.count == 1 ? sameIDs.first : nil
        let favs = config.favorites(for: kind)
        var ids = config.rankByHabits ? Array((config.ranked[kind.rawValue] ?? []).prefix(2)) + favs : favs
        if ids.isEmpty { ids = outputs.filter(\.popular).prefix(3).map(\.id) }
        var seen = Set<String>()
        var out: [FormatDescriptor] = []
        for id in ids where !seen.contains(id) && allowed.contains(id) && id != same {
            seen.insert(id)
            if let f = FormatCatalog.format(id) { out.append(f) }
        }
        return Array(out.prefix(max(3, favs.count)))
    }

    private static func promoted(_ sel: SelectionSummary, config: MenuConfig) -> [MenuNode] {
        guard config.topLevelCount > 0, sel.folders == 0, sel.kinds.count == 1, let kind = sel.kinds.first else { return [] }
        let outputs = convertOutputs(for: kind, sel: sel, config: config)
        return topFormats(for: kind, sel: sel, config: config, among: outputs).prefix(min(3, config.topLevelCount)).map { f in
            .item(title: "Forma : convertir en \(f.name)", symbol: "wand.and.sparkles",
                  entry: MenuEntry(action: .process, mode: .convert, target: f.id))
        }
    }

    private static func canCompress(_ kind: MediaKind, _ sel: SelectionSummary) -> Bool {
        kind != .office || sel.exts.isSubset(of: zipPackages)
    }

    private static func presetItems() -> [MenuNode] {
        CompressionPreset.allCases.filter { $0 != .custom }.map { p in
            .item(title: p.label, symbol: nil, entry: MenuEntry(action: .process, mode: .compress, preset: p))
        }
    }

    /// "Envoyer sur Drop", with an expiry submenu, and "Compresser et envoyer" when the selection can be compressed.
    /// Works on any file and on folders (zipped): no media type is required.
    private static func dropNodes(_ sel: SelectionSummary, config: MenuConfig, compress: String? = nil, container: Bool = false) -> [MenuNode] {
        guard let d = config.drop, d.finder else { return [] }
        let many = sel.fileCount + sel.folders + sel.unsupported > 1
        let title = container ? "Envoyer ce dossier sur Drop" : many ? "Envoyer la sélection sur Drop" : sel.folders == 1 ? "Envoyer le dossier sur Drop" : "Envoyer sur Drop"
        var nodes: [MenuNode] = [
            .item(title: title, symbol: "arrow.up.circle", entry: MenuEntry(action: .upload, drop: DropOptions(), usesContainer: container)),
        ]
        if compress != nil, !container, sel.folders == 0 {
            nodes.append(.item(title: "Compresser et envoyer sur Drop", symbol: "arrow.up.circle.badge.clock",
                               entry: MenuEntry(action: .process, mode: .compress, drop: DropOptions())))
        }
        let expiries: [DropExpiry] = [.hour, .day, .week, .month]
        nodes.append(.submenu(title: "Envoyer sur Drop, expire dans…", symbol: "timer", children: expiries.map { e in
            .item(title: e.label, symbol: nil, entry: MenuEntry(action: .upload, drop: DropOptions(expiry: e), usesContainer: container))
        }))
        return nodes
    }

    private static func recipeNodes(_ config: MenuConfig, accepting kinds: [MediaKind]) -> [MenuNode] {
        guard config.showRecipes else { return [] }
        let list = config.recipes.filter { r in r.showInFinder && kinds.contains { r.accepts($0) } }
        guard !list.isEmpty else { return [] }
        let items: [MenuNode] = list.map { r in
            .item(title: r.name, symbol: r.symbol, entry: MenuEntry(action: .recipe, recipe: r.id))
        }
        return list.count <= 2 ? items : [.submenu(title: "Recettes", symbol: "list.bullet.rectangle", children: items)]
    }

    private static func tail(_ config: MenuConfig) -> [MenuNode] {
        var t: [MenuNode] = []
        if config.showOpenInForma {
            t.append(.item(title: "Ouvrir dans Forma…", symbol: "macwindow", entry: MenuEntry(action: .open)))
        }
        if config.showUndo, let b = config.lastBatch, Date().timeIntervalSince(b.date) < 24 * 3600 {
            t.append(.item(title: "Annuler « \(b.title) »", symbol: "arrow.uturn.backward", entry: MenuEntry(action: .undo, batch: b.id)))
        }
        return t
    }

    /// Formats split by catalog group, one submenu per group when there are several.
    private static func grouped(_ formats: [FormatDescriptor], entry: (FormatDescriptor) -> MenuEntry) -> [MenuNode] {
        var order: [String] = []
        var byGroup: [String: [FormatDescriptor]] = [:]
        for f in formats {
            if byGroup[f.group] == nil { order.append(f.group) }
            byGroup[f.group, default: []].append(f)
        }
        func item(_ f: FormatDescriptor) -> MenuNode { .item(title: f.name, symbol: nil, entry: entry(f)) }
        if order.count == 1 { return formats.map(item) }
        // The first group (Populaires) stays at the top level, the others go in submenus.
        var nodes = (byGroup[order[0]] ?? []).map(item)
        nodes.append(.separator)
        for g in order.dropFirst() { nodes.append(.submenu(title: g, symbol: nil, children: (byGroup[g] ?? []).map(item))) }
        return nodes
    }

    private static func join(_ sections: [[MenuNode]]) -> [MenuNode] {
        var out: [MenuNode] = []
        for s in sections where !s.isEmpty {
            if !out.isEmpty { out.append(.separator) }
            out += s
        }
        return out
    }

    // MARK: Requests

    static func request(for entry: MenuEntry, paths: [String], source: RequestSource) -> ExternalRequest {
        var r = ExternalRequest(source: source, action: entry.action, mode: entry.mode, target: entry.target, paths: paths)
        r.kinds = entry.kinds
        r.recipe = entry.recipe
        r.batch = entry.batch
        r.recursive = entry.recursive
        r.drop = entry.drop
        if let p = entry.preset { r.overrides = RequestOverrides(preset: p) }
        return r
    }
}

private extension MenuNode {
    func retargeted(container: Bool, recursive: Bool?) -> MenuNode {
        switch self {
        case .item(let t, let s, var e):
            e.usesContainer = container
            e.recursive = recursive
            return .item(title: t, symbol: s, entry: e)
        case .submenu(let t, let s, let c):
            return .submenu(title: t, symbol: s, children: c.map { $0.retargeted(container: container, recursive: recursive) })
        default: return self
        }
    }
}

extension MediaKind {
    /// "les images", "les vidéos"… (folder entries).
    var plural: String {
        switch self {
        case .image: "images"
        case .video: "vidéos"
        case .audio: "fichiers audio"
        case .document: "PDF"
        case .office: "documents"
        }
    }
    /// "3 images", "1 vidéo"… (mixed selections).
    func shortLabel(_ n: Int) -> String {
        let s = n > 1
        switch self {
        case .image: return "\(n) image\(s ? "s" : "")"
        case .video: return "\(n) vidéo\(s ? "s" : "")"
        case .audio: return "\(n) audio"
        case .document: return "\(n) PDF"
        case .office: return "\(n) document\(s ? "s" : "")"
        }
    }
}
