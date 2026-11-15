import SwiftUI
import AppKit
import QuickLookThumbnailing

struct HistoryView: View {
    @Environment(PreferencesStore.self) private var store
    @State private var history = HistoryModel.shared
    @State private var search = ""
    @State private var modeFilter: ProcessMode?
    @State private var originFilter: HistoryOrigin?
    @State private var period: Period = .month
    @State private var selection = Set<UUID>()
    @State private var confirmClear = false
    @State private var status: String?

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: "Aujourd'hui"
            case .week: "7 derniers jours"
            case .month: "30 derniers jours"
            case .all: "Tout"
            }
        }
        var start: Date? {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }
    }

    // MARK: Filtering

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let start = period.start
        return history.entries.filter { e in
            if let start, e.date < start { return false }
            if let modeFilter, e.mode != modeFilter { return false }
            if let originFilter, e.origin != originFilter { return false }
            if !q.isEmpty {
                let hay = (e.input.lastPathComponent + " " + e.outputs.map { ($0.path as NSString).lastPathComponent }.joined(separator: " ") + " " + e.formatName)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    private var groups: [(day: Date, entries: [HistoryEntry])] {
        let cal = Calendar.current
        var out: [(Date, [HistoryEntry])] = []
        for e in filtered {
            let d = cal.startOfDay(for: e.date)
            if out.last?.0 == d { out[out.count - 1].1.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Aujourd'hui" }
        if cal.isDateInYesterday(d) { return "Hier" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? .omitted : .defaultDigits))
    }

    private var selected: [HistoryEntry] { history.entries.filter { selection.contains($0.id) } }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if !store.prefs.historyEnabled {
                Label("L'historique est désactivé : les nouveaux traitements ne sont pas enregistrés.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(8)
                    .background(.orange.opacity(0.12))
            }
            summary
            list
            bottomBar
        }
        .frame(minWidth: 620, minHeight: 420)
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher un fichier")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Période", selection: $period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .help("Période affichée")
                Menu {
                    Picker("Mode", selection: $modeFilter) {
                        Text("Tous les modes").tag(ProcessMode?.none)
                        ForEach(ProcessMode.allCases) { Label($0.label, systemImage: $0.symbol).tag(ProcessMode?.some($0)) }
                    }
                    Picker("Origine", selection: $originFilter) {
                        Text("Toutes les origines").tag(HistoryOrigin?.none)
                        ForEach(HistoryOrigin.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag(HistoryOrigin?.some($0)) }
                    }
                } label: {
                    Label("Filtrer", systemImage: modeFilter == nil && originFilter == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filtrer par mode ou par origine")
            }
        }
        .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmClear) {
            Button("Effacer l'historique", role: .destructive) { history.clearAll(); selection.removeAll() }
        } message: {
            Text("Vos fichiers ne sont pas touchés, mais les traitements ne pourront plus être annulés depuis Forma.")
        }
        .onAppear { history.reload() }
    }

    // MARK: Summary

    private var summary: some View {
        let list = filtered.filter { !$0.isUndone }
        let saved = list.reduce(Int64(0)) { $0 + $1.savedBytes }
        let before = list.reduce(Int64(0)) { $0 + ($1.mode == .upscale ? 0 : $1.inputSize) }
        return HStack(spacing: 22) {
            Stat(value: "\(list.count)", label: list.count > 1 ? "fichiers traités" : "fichier traité", symbol: "doc.on.doc")
            Stat(value: saved.formattedBytes, label: "économisés", symbol: "arrow.down.circle", tint: .green)
            if before > 0 && saved > 0 {
                Stat(value: "−\(Int((Double(saved) / Double(before) * 100).rounded())) %", label: "en moyenne", symbol: "percent", tint: .green)
            }
            Spacer()
            ForEach(ProcessMode.allCases) { m in
                let n = list.filter { $0.mode == m }.count
                if n > 0 {
                    Label("\(n)", systemImage: m.symbol).font(.callout.monospacedDigit()).foregroundStyle(.secondary).help(m.label)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.day) { group in
                Section(dayTitle(group.day)) {
                    ForEach(group.entries) { e in
                        HistoryRow(entry: e).tag(e.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if filtered.isEmpty {
                if history.entries.isEmpty {
                    ContentUnavailableView("Aucun traitement pour l'instant", systemImage: "clock.arrow.circlepath",
                                           description: Text("Chaque conversion, compression ou agrandissement apparaîtra ici, qu'il vienne de Forma, du Terminal, d'un Raccourci ou d'un dossier surveillé."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: history.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            let outs = history.entries.filter { ids.contains($0.id) }.flatMap(\.outputURLs).filter { FileManager.default.fileExists(atPath: $0.path) }
            if !outs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outs) }
        }
        .onKeyPress(.space) {
            guard let e = selected.first else { return .ignored }
            PreviewWindow.show(PreviewRequest(source: .history(e)))
            return .handled
        }
        .onDeleteCommand { history.remove(selection); selection.removeAll() }
    }

    @ViewBuilder
    private func menu(for list: [HistoryEntry]) -> some View {
        let outputs = list.flatMap(\.outputURLs).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !outputs.isEmpty {
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            if list.count == 1, let o = outputs.first { Button("Ouvrir") { NSWorkspace.shared.open(o) } }
            Button("Copier le résultat") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(outputs as [NSURL])
            }
        }
        if list.count == 1, let e = list.first, e.readableOriginal != nil, kindOf(e).map(PreviewRenderer.canPreview) == true {
            Button("Aperçu avant / après") { PreviewWindow.show(PreviewRequest(source: .history(e))) }
        }
        let originals = list.compactMap(\.readableOriginal).filter { !$0.path.contains("/.Trash/") }
        if !originals.isEmpty {
            Button("Afficher l'original") { NSWorkspace.shared.activateFileViewerSelecting(originals) }
            Menu("Retraiter") {
                ForEach(ProcessMode.allCases) { m in
                    Button(m.label) {
                        AppDelegate.showMainWindow()
                        AppModel.shared.add(originals, mode: m, autoStart: false)
                    }
                }
            }
        }
        Divider()
        let undoable = list.filter { !$0.isUndone }
        if !undoable.isEmpty {
            Button(undoable.contains(where: \.originalWasTrashed) ? "Annuler et restaurer l'original" : "Annuler (résultat à la Corbeille)") {
                status = history.undo(undoable, reveal: true)
            }
            .disabled(undoable.allSatisfy { HistoryUndo.blocker(for: $0) != nil })
        }
        Button("Retirer de l'historique", role: .destructive) {
            history.remove(Set(list.map(\.id)))
            selection.subtract(list.map(\.id))
        }
    }

    private func kindOf(_ e: HistoryEntry) -> MediaKind? { FileDetection.classify(e.input).mediaKind }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let status {
                Label(status, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .transition(.opacity)
            } else if !selection.isEmpty {
                Text("\(selection.count) sélectionné\(selection.count > 1 ? "s" : "")").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Conservé \(store.prefs.historyRetentionDays == 0 ? "sans limite" : "\(store.prefs.historyRetentionDays) jours") · Espace pour l'aperçu")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Effacer l'historique…") { confirmClear = true }
                .disabled(history.entries.isEmpty)
            let undoable = selected.filter { !$0.isUndone }
            Button {
                status = history.undo(undoable, reveal: true)
                selection.removeAll()
            } label: {
                Label(undoable.count > 1 ? "Annuler \(undoable.count) traitements" : "Annuler le traitement", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.glassProminent)
            .disabled(undoable.isEmpty || undoable.allSatisfy { HistoryUndo.blocker(for: $0) != nil })
            .help("Met les résultats à la Corbeille et remet les originaux que Forma avait supprimés")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.smooth(duration: 0.2), value: status)
        .task(id: status) {
            guard status != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            status = nil
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Row

struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var thumb: NSImage?

    private var outputExists: Bool { entry.outputURLs.contains { FileManager.default.fileExists(atPath: $0.path) } }
    private var outputName: String {
        guard let first = entry.outputs.first else { return "—" }
        let name = (first.path as NSString).lastPathComponent
        return entry.outputs.count > 1 ? "\(name) + \(entry.outputs.count - 1)" : name
    }

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(image: thumb, kind: FileDetection.classify(entry.input).mediaKind ?? .image)
                .saturation(entry.isUndone ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.input.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if outputName != entry.input.lastPathComponent {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(outputName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(entry.input.pathExtension.uppercased()) · \(entry.inputSize.formattedBytes)")
                    Image(systemName: "arrow.right").font(.caption2)
                    Text("\(entry.formatName) · \(entry.outputSize.formattedBytes)")
                    if let note = entry.note { Text("· \(note)") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if entry.isUndone {
                    Chip(text: "Annulé", symbol: "arrow.uturn.backward", color: .secondary)
                } else if !outputExists {
                    Chip(text: "Introuvable", symbol: "questionmark.folder", color: .orange)
                }
                if entry.origin != .app { Chip(text: entry.origin.label, symbol: entry.origin.symbol, color: .secondary) }
                if !entry.isUndone { SavingsBadge(savings: entry.savings) }
                Image(systemName: entry.mode.symbol).foregroundStyle(.secondary).help(entry.mode.label).frame(width: 18)
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .opacity(entry.isUndone ? 0.55 : 1)
        .task(id: entry.id) { thumb = await HistoryThumbnails.image(for: entry) }
    }
}

private struct Chip: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
            .foregroundStyle(color)
    }
}

@MainActor
enum HistoryThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for e: HistoryEntry) async -> NSImage? {
        let fm = FileManager.default
        guard let url = e.outputURLs.first(where: { fm.fileExists(atPath: $0.path) }) ?? e.readableOriginal else { return nil }
        let key = url.path as NSString
        if let c = cache.object(forKey: key) { return c }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: [.thumbnail, .icon])
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        cache.setObject(rep.nsImage, forKey: key)
        return rep.nsImage
    }
}
