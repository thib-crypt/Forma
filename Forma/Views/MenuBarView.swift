import SwiftUI
import QuickLookThumbnailing

/// Content of the menu bar panel (hosted in a non-activating glass panel by `MenuBarController`).
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(MenuBarState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            DropTiles()
                .padding(.horizontal, 12)

            DropHint()
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

            if model.isRunning || model.lastBatchSummary != nil {
                ActivityCard()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.blurReplace.combined(with: .opacity))
            }

            RecentSection()

            PanelDivider()

            ClipboardSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            PanelDivider()

            MenuBarFooter()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: MenuBarController.width)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.28), value: model.isRunning)
        .animation(.smooth(duration: 0.28), value: model.lastBatchSummary)
        .animation(.smooth(duration: 0.22), value: state.fileDragActive)
        .animation(.smooth(duration: 0.22), value: state.notice)
        // Drops anywhere outside the tiles use the current mode.
        .dropDestination(for: URL.self) { urls, _ in
            MenuBarController.shared.accept(urls, mode: model.mode)
        }
        .focusEffectDisabled()
    }
}

// MARK: - Header

private struct MenuBarHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(MenuBarState.self) private var state

    private var status: String {
        if model.isRunning, let m = model.runningMode {
            let list = model.items(for: m)
            let done = list.filter(\.status.isFinished).count
            return model.isPaused ? "En pause · \(done) / \(list.count)" : "\(m.label) · \(done) / \(list.count)"
        }
        return "Prêt"
    }

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Forma").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isRunning ? (model.isPaused ? Color.orange : Color.accentColor) : Color.green)
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { state.isPinned.toggle() } label: {
                    Image(systemName: state.isPinned ? "pin.fill" : "pin")
                        .rotationEffect(.degrees(state.isPinned ? 0 : 45))
                }
                .buttonStyle(PanelIconButtonStyle(active: state.isPinned))
                .help(state.isPinned ? "Détacher : le panneau se fermera au prochain clic ailleurs"
                                     : "Épingler : le panneau reste ouvert, comme une étagère de dépôt")

                Button { MenuBarController.shared.close(animated: false); AppDelegate.showMainWindow() } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(PanelIconButtonStyle())
                .help("Ouvrir la fenêtre Forma (⌥-clic sur l'icône)")

                Menu {
                    Button("Historique", systemImage: "clock.arrow.circlepath") { AppDelegate.showHistory() }
                    Button("Réglages…", systemImage: "gearshape") { AppDelegate.showSettings() }
                    Divider()
                    Button("Annuler le dernier traitement", systemImage: "arrow.uturn.backward") {
                        HistoryModel.shared.undoLastBatch()
                    }
                    .disabled(HistoryModel.shared.lastUndoableBatch.isEmpty)
                    Divider()
                    Button("Quitter Forma", systemImage: "power") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(PanelIconButtonStyle())
                .fixedSize()
            }
        }
    }
}

// MARK: - Drop tiles

private struct DropTiles: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProcessMode.allCases) { DropTile(mode: $0) }
        }
    }
}

extension ProcessMode {
    var tint: Color {
        switch self {
        case .convert: .blue
        case .compress: .green
        case .upscale: .purple
        }
    }
    var tileSymbol: String { self == .upscale ? "sparkles" : symbol }
}

private struct DropTile: View {
    let mode: ProcessMode
    @Environment(AppModel.self) private var model
    @Environment(MenuBarState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    private var isDefault: Bool { model.mode == mode }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(mode.tint.opacity(targeted ? 0.32 : 0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: targeted ? "arrow.down" : mode.tileSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(mode.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .scaleEffect(targeted && !reduceMotion ? 1.08 : 1)

            VStack(spacing: 2) {
                Text(mode.label)
                    .font(.system(size: 12, weight: .semibold))
                TileOptions(mode: mode)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: state.fileDragActive ? 122 : 104)
        .background {
            shape.fill(targeted ? AnyShapeStyle(mode.tint.opacity(0.16))
                       : AnyShapeStyle(Color.primary.opacity(hovering ? 0.08 : 0.045)))
        }
        .overlay {
            if targeted {
                shape.strokeBorder(mode.tint, lineWidth: 1.5)
            } else if state.fileDragActive {
                shape.strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            } else if isDefault {
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .contentShape(shape)
        .scaleEffect(targeted && !reduceMotion ? 1.03 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: targeted)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { MenuBarController.shared.choose(mode: mode) }
        .dropDestination(for: URL.self) { urls, _ in
            MenuBarController.shared.accept(urls, mode: mode)
        } isTargeted: { targeted = $0 }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Déposez des fichiers ici, ou cliquez pour en choisir")
    }

    private var help: String {
        switch mode {
        case .convert: "Déposez pour convertir — ou cliquez pour choisir des fichiers"
        case .compress: "Déposez pour compresser — ou cliquez pour choisir des fichiers"
        case .upscale: "Déposez des images pour les agrandir ×2 par IA — ou cliquez pour en choisir"
        }
    }
}

/// The tile's subtitle doubles as a quick settings menu (target formats, preset, upscale format).
private struct TileOptions: View {
    let mode: ProcessMode
    @Environment(PreferencesStore.self) private var store

    private static let imageTargets = ["JPEG", "PNG", "WEBP", "AVIF", "HEIC", "JXL", "TIFF", "GIF", "PDF"]
    private static let videoTargets = ["MP4", "MOV", "WEBM", "MKV", "GIF"]
    private static let audioTargets = ["MP3", "M4A", "AAC", "WAV", "FLAC", "OPUS"]
    private static let officeTargets = ["PDFDOC", "DOCX", "ODT", "RTF", "TXT", "MD", "HTML", "EPUB"]

    private var title: String {
        let p = store.prefs.processing
        switch mode {
        case .convert:
            return "\(FormatCatalog.format(p.imageTarget)?.name ?? p.imageTarget) · \(FormatCatalog.format(p.videoTarget)?.name ?? p.videoTarget)"
        case .compress:
            return p.image.preset.label
        case .upscale:
            return p.upscaleTarget == "SAME" ? "×2 · Original" : "×2 · \(FormatCatalog.format(p.upscaleTarget)?.name ?? p.upscaleTarget)"
        }
    }

    var body: some View {
        @Bindable var store = store
        Menu {
            switch mode {
            case .convert:
                formatPicker("Images", ids: Self.imageTargets, selection: $store.prefs.processing.imageTarget)
                formatPicker("Vidéos", ids: Self.videoTargets, selection: $store.prefs.processing.videoTarget)
                formatPicker("Audio", ids: Self.audioTargets, selection: $store.prefs.processing.audioTarget)
                formatPicker("Documents", ids: Self.officeTargets, selection: $store.prefs.processing.officeTarget)
            case .compress:
                Picker("Préréglage", selection: $store.prefs.processing.image.preset) {
                    ForEach(CompressionPreset.allCases.filter { $0 != .custom || store.prefs.processing.image.preset == .custom }) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.inline)
            case .upscale:
                Picker("Format de sortie", selection: $store.prefs.processing.upscaleTarget) {
                    ForEach(ProcessingSnapshot.upscaleChoices, id: \.self) {
                        Text($0 == "SAME" ? "Format d'origine" : FormatCatalog.format($0)?.name ?? $0).tag($0)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .frame(maxWidth: 100)
        .help("Réglages rapides")
    }

    @ViewBuilder
    private func formatPicker(_ title: String, ids: [String], selection: Binding<String>) -> some View {
        let list = ids.compactMap(FormatCatalog.format)
        Picker(title, selection: selection) {
            ForEach(list, id: \.id) { Text($0.name).tag($0.id) }
            if !list.contains(where: { $0.id == selection.wrappedValue }) {
                Text(FormatCatalog.format(selection.wrappedValue)?.name ?? selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }
}

private struct DropHint: View {
    @Environment(AppModel.self) private var model
    @Environment(MenuBarState.self) private var state

    var body: some View {
        Group {
            if let n = state.notice {
                Label(n.text, systemImage: n.symbol)
                    .foregroundStyle(n.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                    .id(n.id)
            } else if state.fileDragActive {
                Label("Relâchez sur l'action voulue", systemImage: "hand.point.up.left")
                    .foregroundStyle(.secondary)
            } else {
                Text("Déposez sur une action, ou sur l'icône : \(model.mode.label.lowercased())")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .offset(y: 3)))
    }
}

// MARK: - Activity

private struct ActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRunning, let m = model.runningMode {
                running(m)
            } else if let summary = model.lastBatchSummary {
                finished(summary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func running(_ m: ProcessMode) -> some View {
        let list = model.items(for: m)
        let current = list.filter(\.status.isProcessing)
        HStack(spacing: 8) {
            Image(systemName: m.tileSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(m.tint)
                .symbolEffect(.pulse, isActive: !model.isPaused)
            Text(model.isPaused ? "En pause" : "\(m.label) en cours")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(Int(model.overallProgress * 100)) %")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        ProgressView(value: model.overallProgress)
            .progressViewStyle(.linear)
            .tint(m.tint)
            .animation(.linear(duration: 0.15), value: model.overallProgress)
        HStack(spacing: 6) {
            Text(current.isEmpty ? "Préparation…" : current.map(\.name).joined(separator: ", "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button { model.isPaused ? model.resume() : model.pause() } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(PanelIconButtonStyle(size: 22))
            .help(model.isPaused ? "Reprendre" : "Mettre en pause")
            Button { model.cancel() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(PanelIconButtonStyle(size: 22))
                .help("Arrêter")
        }
    }

    @ViewBuilder
    private func finished(_ summary: String) -> some View {
        let batch = model.lastBatchID.map { id in HistoryModel.shared.entries.filter { $0.batch == id && !$0.isUndone } } ?? []
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
            // Keep "4,1 Mo" together when the line wraps.
            Text(summary.replacing(/(\d) (ko|Mo|Go|o|s|min|fichiers?|échecs?)/) { "\($0.1)\u{00A0}\($0.2)" })
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.lastBatchSummary = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(PanelIconButtonStyle(size: 20))
                .help("Masquer")
        }
        if !batch.isEmpty {
            HStack(spacing: 6) {
                Button { NSWorkspace.shared.activateFileViewerSelecting(batch.flatMap(\.outputURLs)) } label: {
                    Label("Afficher", systemImage: "magnifyingglass")
                }
                Button { HistoryModel.shared.undo(batch); model.lastBatchSummary = nil } label: {
                    Label("Annuler", systemImage: "arrow.uturn.backward")
                }
            }
            .buttonStyle(PanelCapsuleButtonStyle())
        }
    }
}

// MARK: - Recent results

private struct RecentSection: View {
    @State private var history = HistoryModel.shared

    private var recent: [HistoryEntry] {
        let fm = FileManager.default
        return Array(history.entries.lazy
            .filter { !$0.isUndone && !$0.outputs.isEmpty }
            .filter { $0.outputs.first.map { fm.fileExists(atPath: $0.path) } ?? false }
            .prefix(3))
    }

    var body: some View {
        let list = recent
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Récents")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Tout l'historique") { AppDelegate.showHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
                VStack(spacing: 0) {
                    ForEach(list) { RecentRow(entry: $0) }
                }
                .padding(.horizontal, 6)
            }
            .padding(.bottom, 8)
        }
    }
}

private struct RecentRow: View {
    let entry: HistoryEntry
    @State private var hovering = false
    @State private var copied = false

    private var output: URL { entry.outputs[0].url }

    private var detail: String {
        var parts = [entry.formatName, entry.outputSize.formattedBytes]
        if entry.mode == .upscale { parts.append("×2") }
        else if let s = entry.savings { parts.append(s >= 0 ? "−\(Int((s * 100).rounded())) %" : "+\(Int((-s * 100).rounded())) %") }
        if entry.outputs.count > 1 { parts.append("\(entry.outputs.count) fichiers") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            FileThumbnail(url: output)
            VStack(alignment: .leading, spacing: 2) {
                Text(output.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(detail).monospacedDigit()
                    Text("·")
                    Text(entry.date, format: .relative(presentation: .named))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 2) {
                    Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(PanelIconButtonStyle(size: 24))
                        .help("Copier le fichier")
                    Button { NSWorkspace.shared.activateFileViewerSelecting(entry.outputURLs) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(PanelIconButtonStyle(size: 24))
                    .help("Afficher dans le Finder")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(output) }
        .onDrag { NSItemProvider(contentsOf: output) ?? NSItemProvider() }
        .help("Glissez le résultat où vous voulez · double-clic pour l'ouvrir")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(entry.outputURLs as [NSURL])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

private struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url) }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        let img = rep.nsImage
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

// MARK: - Clipboard

private struct ClipboardSection: View {
    @Environment(PreferencesStore.self) private var store
    @State private var optimizer = ClipboardOptimizer.shared

    private var subtitle: String {
        let c = store.prefs.clipboard
        guard c.enabled else { return "Désactivé · ⌥⌘V à la demande" }
        if c.isPaused, let until = c.pausedUntil { return "En pause jusqu'à \(until.formatted(date: .omitted, time: .shortened))" }
        if c.trigger != .automatic { return "À la demande · ⌥⌘V" }
        let n = c.rules.filter(\.enabled).count
        if let last = optimizer.log.first, last.status == .optimized, last.before > 0 {
            let pct = Int(((1 - Double(last.after) / Double(last.before)) * 100).rounded())
            return "Dernière image : −\(pct) % · \(last.app)"
        }
        return "Automatique · \(n) règle\(n > 1 ? "s" : "") active\(n > 1 ? "s" : "")"
    }

    var body: some View {
        @Bindable var store = store
        let c = store.prefs.clipboard
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.16))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: optimizer.busy ? "sparkles" : "doc.on.clipboard")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                            .contentTransition(.symbolEffect(.replace))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Presse-papiers").font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(c.isPaused && c.enabled ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: $store.prefs.clipboard.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: store.prefs.clipboard.enabled) { ClipboardOptimizer.shared.apply() }
                    .help("Optimiser automatiquement les images copiées")
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Button { ClipboardOptimizer.shared.optimizeNow() } label: {
                    Label("Optimiser maintenant", systemImage: "wand.and.sparkles")
                }
                .disabled(optimizer.busy)
                if c.enabled && c.trigger == .automatic {
                    if c.isPaused {
                        Button { ClipboardOptimizer.shared.pause(for: nil) } label: { Label("Reprendre", systemImage: "play.fill") }
                    } else {
                        Menu {
                            Button("15 minutes") { ClipboardOptimizer.shared.pause(for: 900) }
                            Button("1 heure") { ClipboardOptimizer.shared.pause(for: 3600) }
                            Button("Jusqu'à demain") {
                                let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
                                ClipboardOptimizer.shared.pause(for: tomorrow.timeIntervalSinceNow)
                            }
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(PanelCapsuleButtonStyle())
            .padding(.leading, 44)
        }
        .animation(.smooth(duration: 0.2), value: c.enabled)
        .animation(.smooth(duration: 0.2), value: c.isPaused)
    }
}

// MARK: - Footer

private struct MenuBarFooter: View {
    @Environment(PreferencesStore.self) private var store

    var body: some View {
        let watched = store.prefs.watchedFolders.filter(\.enabled).count
        let scheduled = store.prefs.scheduledJobs.count
        HStack(spacing: 4) {
            Button { AppDelegate.showSettings() } label: {
                Label(watched == 0 ? "Aucun dossier surveillé" : "\(watched) dossier\(watched > 1 ? "s" : "") surveillé\(watched > 1 ? "s" : "")",
                      systemImage: watched == 0 ? "folder" : "folder.badge.gearshape")
            }
            .help("Configurer les dossiers surveillés")
            if scheduled > 0 {
                Button { AppDelegate.showSettings() } label: {
                    Label("\(scheduled) planifié\(scheduled > 1 ? "s" : "")", systemImage: "clock")
                }
            }
            Spacer(minLength: 4)
            Button { AppDelegate.showSettings() } label: {
                Label("Réglages", systemImage: "gearshape")
            }
        }
        .buttonStyle(PanelFooterButtonStyle())
    }
}

// MARK: - Styles

private struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

/// Round icon button with a hover fill, like the controls of macOS panels.
struct PanelIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

private struct PanelCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.11 : 0.065)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

private struct PanelFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 11))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Gives button styles a hover state.
private struct Hovering<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}
