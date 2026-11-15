import Foundation

/// Keeps `menu.json` (read by the sandboxed extensions) in sync with the preferences and the history.
@MainActor
final class MenuConfigPublisher {
    static let shared = MenuConfigPublisher()
    private var lastWritten: Data?
    private var work: DispatchWorkItem?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        observe()
        publishNow()
    }

    /// Re-arms an observation of everything the menu depends on.
    private func observe() {
        withObservationTracking {
            let p = PreferencesStore.shared.prefs
            _ = p.finder
            _ = p.recipes
            _ = p.processing.image.preset
            _ = HistoryModel.shared.entries.count
            _ = HistoryModel.shared.entries.first?.id
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MenuConfigPublisher.shared.setNeedsPublish()
                    MenuConfigPublisher.shared.observe()
                }
            }
        }
    }

    func setNeedsPublish() {
        work?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { MenuConfigPublisher.shared.publishNow() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func publishNow() {
        let config = Self.makeConfig()
        guard let data = MenuConfigStore.encode(config), data != lastWritten, let url = GroupContainer.menuConfigURL else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastWritten = data
            GroupContainer.postMenuChanged()
        } catch {
            NSLog("Forma: cannot write menu.json: \(error.localizedDescription)")
        }
    }

    static func makeConfig() -> MenuConfig {
        let prefs = PreferencesStore.shared.prefs
        let f = prefs.finder
        var c = MenuConfig()
        c.enabled = f.enabled
        c.favorites = f.favorites
        c.rankByHabits = f.rankByHabits
        c.showCompress = f.showCompress
        c.showCompressPresets = f.showCompressPresets
        c.showUpscale = f.showUpscale
        c.showRecipes = f.showRecipes
        c.showUndo = f.showUndo
        c.showOpenInForma = f.showOpenInForma
        c.showIcons = f.showIcons
        c.topLevelCount = f.topLevelCount
        c.compressPreset = prefs.processing.image.preset
        c.libreOffice = Tool.soffice.isAvailable
        c.sharesFolder = f.sharesFolderURL.path
        c.recipes = prefs.recipes.map(\.summary)
        let entries = HistoryModel.shared.entries
        c.ranked = ranked(entries)
        c.lastBatch = lastExternalBatch(entries)
        return c
    }

    /// Most used conversion targets per input kind (at least 2 uses), from the in-memory history.
    static func ranked(_ entries: [HistoryEntry]) -> [String: [String]] {
        var counts: [MediaKind: [String: Int]] = [:]
        for e in entries.prefix(3000) where e.mode == .convert && !e.isUndone {
            guard let kind = FileDetection.classify(e.input).mediaKind else { continue }
            counts[kind, default: [:]][e.formatName, default: 0] += 1
        }
        var out: [String: [String]] = [:]
        for (kind, byName) in counts {
            let outputs = FormatCatalog.outputs(for: kind)
            let ids = byName.filter { $0.value >= 2 }.sorted { $0.value > $1.value }
                .compactMap { name, _ in outputs.first { $0.name == name }?.id }
            if !ids.isEmpty { out[kind.rawValue] = Array(ids.prefix(3)) }
        }
        return out
    }

    /// The most recent batch started from the Finder, the Share menu, a Service or a link, if it can still be undone.
    static func lastExternalBatch(_ entries: [HistoryEntry]) -> BatchSummary? {
        guard let last = entries.first(where: { $0.origin.isExternal }), !last.isUndone, let batch = last.batch else { return nil }
        let members = entries.filter { $0.batch == batch && !$0.isUndone }
        guard !members.isEmpty else { return nil }
        let verb: String = switch last.mode {
        case .convert: "Conversion en \(last.formatName)"
        case .compress: "Compression"
        case .upscale: "Agrandissement"
        }
        let n = members.count
        return BatchSummary(id: batch, title: n > 1 ? "\(verb) de \(n) fichiers" : "\(verb) de \(last.input.lastPathComponent)",
                            date: last.date, count: n)
    }
}
