import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// Share › Forma: a compact panel to pick an action, then the request goes to Forma, which works in the background
/// (progress in its HUD). Items that only exist as data (an image from Safari or Photos) are copied into the inbox.
final class ShareViewController: NSViewController {
    private let model = ShareModel()

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        model.context = extensionContext
        model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        let host = NSHostingView(rootView: ShareView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 460)
        view = host
        preferredContentSize = NSSize(width: 400, height: 460)
    }
}

struct SharedItem: Identifiable {
    let id = UUID()
    var provider: NSItemProvider
    var fileURL: URL?
    var name: String
    var kind: MediaKind?
    var typeIdentifier: String?
    var size: Int64?
}

@MainActor
@Observable
final class ShareModel {
    var items: [SharedItem] = []
    var loading = true
    var mode: ProcessMode = .convert
    var target: String?          // nil = default per kind
    var preset: CompressionPreset?
    var recipe: UUID?
    var destination: Int = 0     // 0 alongside, 1 shares folder, 2 clipboard
    var sending = false
    var error: String?
    let config = MenuConfigStore.Reader().config
    weak var context: NSExtensionContext?

    var kinds: [MediaKind] {
        var seen: [MediaKind] = []
        for k in items.compactMap(\.kind) where !seen.contains(k) { seen.append(k) }
        return seen
    }
    var allFiles: Bool { !items.isEmpty && items.allSatisfy { $0.fileURL != nil } }
    var totalSize: Int64 { items.compactMap(\.size).reduce(0, +) }
    var recipes: [RecipeSummary] { config.recipes.filter { r in r.showInShare && kinds.contains { r.accepts($0) } } }

    /// Format chips: favourites of the (single) detected kind, then its popular formats.
    var formatChoices: [FormatDescriptor] {
        guard kinds.count == 1, let kind = kinds.first else { return [] }
        let exts = Set(items.compactMap { $0.fileURL?.pathExtension.lowercased() ?? $0.typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } })
        let sel = SelectionSummary(counts: [kind: items.count], exts: exts)
        let outputs = MenuBuilder.convertOutputs(for: kind, sel: sel, config: config)
        var list = MenuBuilder.topFormats(for: kind, sel: sel, config: config, among: outputs)
        for f in outputs where f.popular && !list.contains(f) && list.count < 8 { list.append(f) }
        return list
    }

    func load(_ extensionItems: [NSExtensionItem]) {
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { loading = false; return }
        let group = DispatchGroup()
        var loaded: [Int: SharedItem] = [:]
        let lock = NSLock()
        for (i, p) in providers.enumerated() {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    guard let url, url.isFileURL else { return }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                    let item = SharedItem(provider: p, fileURL: url, name: url.lastPathComponent,
                                          kind: FileDetection.classify(url).mediaKind, size: size)
                    lock.withLock { loaded[i] = item }
                }
            } else {
                let type = Self.mediaType(of: p)
                let ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "dat"
                let name = (p.suggestedName ?? "Partage \(i + 1)") + "." + ext
                let kind = FileDetection.classify(URL(fileURLWithPath: "x.\(ext)")).mediaKind
                lock.withLock { loaded[i] = SharedItem(provider: p, fileURL: nil, name: name, kind: kind, typeIdentifier: type) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.items = loaded.keys.sorted().compactMap { loaded[$0] }.filter { $0.kind != nil }
            self.loading = false
            self.destination = self.allFiles ? 0 : 1
            if self.kinds.count == 1, self.kinds[0] == .image || self.kinds[0] == .office || self.kinds[0] == .document {
                self.target = self.formatChoices.first?.id
            }
        }
    }

    private static func mediaType(of p: NSItemProvider) -> String? {
        for t in [UTType.image, .movie, .audio, .pdf] {
            if let id = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: t) == true }) { return id }
        }
        return p.registeredTypeIdentifiers.first
    }

    // MARK: Sending

    func send() {
        guard !sending, !items.isEmpty else { return }
        sending = true
        var r = ExternalRequest(source: .share, mode: mode)
        if let recipe {
            r.action = .recipe
            r.recipe = recipe
        } else {
            r.target = mode == .convert ? target : nil
            if mode == .compress, let preset { r.overrides = RequestOverrides(preset: preset) }
        }
        switch destination {
        case 0: r.destination = .alongside
        case 2: r.destination = .clipboard
        default: r.destination = config.sharesFolder.map { .folder($0) } ?? .alongside
        }
        let request = r
        let items = self.items
        Task.detached {
            do {
                var req = request
                var paths: [String] = []
                var staged: URL?
                for item in items {
                    if let u = item.fileURL { paths.append(u.path); continue }
                    let dir = try staged ?? GroupContainer.stagingDirectory(for: req.id)
                    staged = dir
                    if let copy = try await Self.stage(item, into: dir) { paths.append(copy.path) }
                }
                req.paths = paths
                req.stagedDirectory = staged?.path
                guard !paths.isEmpty else { throw ShareError.nothing }
                try GroupContainer.submit(req, hostApp: GroupContainer.hostAppURL())
                await MainActor.run { self.context?.completeRequest(returningItems: nil) }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.sending = false
                }
            }
        }
    }

    enum ShareError: LocalizedError {
        case nothing
        var errorDescription: String? { "Rien de compatible à envoyer à Forma." }
    }

    /// Copies an item that has no file on disk into the inbox (deleted by Forma once processed).
    nonisolated private static func stage(_ item: SharedItem, into dir: URL) async throws -> URL? {
        guard let type = item.typeIdentifier else { return nil }
        return try await withCheckedThrowingContinuation { cont in
            _ = item.provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { cont.resume(throwing: error ?? ShareError.nothing); return }
                var dest = dir.appendingPathComponent(item.name)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\((item.name as NSString).deletingPathExtension) \(n).\((item.name as NSString).pathExtension)")
                    n += 1
                }
                do { try FileManager.default.copyItem(at: url, to: dest); cont.resume(returning: dest) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    func cancel() {
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
