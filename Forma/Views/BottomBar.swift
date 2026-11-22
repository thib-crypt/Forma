import SwiftUI

struct BottomBar: View {
    @Environment(AppModel.self) private var model
    @Environment(PreferencesStore.self) private var store
    @State private var showQuick = false
    @State private var showSchedule = false

    private var kinds: [MediaKind] {
        let present = Set(model.items.map { $0.kind == .document ? .image : $0.kind })
        return MediaKind.visible.filter(present.contains)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isRunning && model.runningMode == model.mode {
                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
            }
            HStack(spacing: 12) {
                summary
                Spacer(minLength: 8)
                targets
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .sheet(isPresented: $showSchedule) { ScheduleSheet() }
    }

    // MARK: Left

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            let total = model.items.reduce(Int64(0)) { $0 + $1.size }
            Text("\(model.items.count) fichier\(model.items.count > 1 ? "s" : "") · \(total.formattedBytes)")
                .font(.system(size: 12, weight: .semibold))
            if let s = model.lastBatchSummary, !model.isRunning {
                HStack(spacing: 8) {
                    Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    let undoable = HistoryModel.shared.entries.filter { $0.batch == model.lastBatchID && !$0.isUndone }
                    if !undoable.isEmpty {
                        Button {
                            Toast.show(HistoryModel.shared.undo(undoable), symbol: "arrow.uturn.backward")
                        } label: {
                            Label("Annuler", systemImage: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.link)
                        .help("Met les résultats de ce lot à la Corbeille et restaure les originaux (⌥⌘Z)")
                    }
                }
            } else if model.isRunning {
                Text(model.isPaused ? "En pause — les fichiers en cours se terminent" : "\(model.doneCount) / \(model.items.count) traités")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if model.totalSaved > 0 {
                Text("\(model.totalSaved.formattedBytes) économisés").font(.system(size: 11)).foregroundStyle(.green)
            } else {
                Text("Prêt").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    // MARK: Middle

    @ViewBuilder private var targets: some View {
        @Bindable var store = store
        HStack(spacing: 8) {
            if model.mode == .upscale {
                UpscaleControls()
            } else if model.mode == .convert {
                ForEach(kinds, id: \.self) { kind in
                    TargetButton(kind: kind, selection: binding(for: kind))
                }
            } else {
                ForEach(kinds, id: \.self) { kind in
                    switch kind {
                    case .image:
                        PresetMenu(symbol: "photo", title: store.prefs.processing.image.preset.label) {
                            Picker("Images", selection: $store.prefs.processing.image.preset) {
                                ForEach(CompressionPreset.allCases) { p in Text("\(p.label) — \(p.detail)").tag(p) }
                            }.pickerStyle(.inline)
                        }
                    case .video:
                        PresetMenu(symbol: "film", title: store.prefs.processing.video.preset.label) {
                            Picker("Vidéos", selection: $store.prefs.processing.video.preset) {
                                ForEach(VideoPreset.allCases) { p in Text("\(p.label) — \(p.detail)").tag(p) }
                            }.pickerStyle(.inline)
                        }
                    case .audio:
                        PresetMenu(symbol: "waveform", title: store.prefs.processing.audio.preset.label) {
                            Picker("Audio", selection: $store.prefs.processing.audio.preset) {
                                ForEach(AudioPreset.allCases) { p in Text("\(p.label) — \(p.detail)").tag(p) }
                            }.pickerStyle(.inline)
                        }
                    case .office where !kinds.contains(.image):
                        // Documents: the image preset drives the pictures recompressed inside DOCX / PPTX / EPUB.
                        PresetMenu(symbol: "doc.text", title: store.prefs.processing.image.preset.label) {
                            Picker("Images des documents", selection: $store.prefs.processing.image.preset) {
                                ForEach(CompressionPreset.allCases) { p in Text("\(p.label) — \(p.detail)").tag(p) }
                            }.pickerStyle(.inline)
                        }
                    case .document, .office: EmptyView()
                    }
                }
            }
        }
    }

    private func binding(for kind: MediaKind) -> Binding<String> {
        switch kind {
        case .video: Binding(get: { store.prefs.processing.videoTarget }, set: { store.prefs.processing.videoTarget = $0 })
        case .audio: Binding(get: { store.prefs.processing.audioTarget }, set: { store.prefs.processing.audioTarget = $0 })
        case .office: Binding(get: { store.prefs.processing.officeTarget }, set: { store.prefs.processing.officeTarget = $0 })
        default: Binding(get: { store.prefs.processing.imageTarget }, set: { store.prefs.processing.imageTarget = $0 })
        }
    }

    // MARK: Right

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            Button { showQuick.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.glass)
                .help("Réglages de traitement")
                .popover(isPresented: $showQuick, arrowEdge: .top) { QuickSettings(mode: model.mode) }

            Menu {
                Button("Planifier pour plus tard…", systemImage: "clock") { showSchedule = true }
                    .disabled(model.pendingCount == 0)
                Toggle(isOn: Binding(get: { store.prefs.drop.afterProcessing }, set: { store.prefs.drop.afterProcessing = $0 })) {
                    Label("Envoyer les résultats sur Drop", systemImage: "arrow.up.circle")
                }
                .disabled(!DropServer.isConfigured(store.prefs.drop))
                Button("Réessayer les échecs", systemImage: "arrow.clockwise") { model.retryFailed() }
                Button("Tout retraiter", systemImage: "arrow.counterclockwise") { model.resetAndRun() }
                    .disabled(model.isRunning)
                Divider()
                Button("Vider les fichiers traités", systemImage: "checkmark.circle") { model.clearFinished() }
                Button("Tout retirer", systemImage: "trash", role: .destructive) { model.removeAll() }
                    .disabled(model.isRunning && model.runningMode == model.mode)
            } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()

            if model.isRunning && model.runningMode == model.mode {
                Button { model.isPaused ? model.resume() : model.pause() } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.glass)
                .help(model.isPaused ? "Reprendre" : "Terminer les fichiers en cours puis mettre en pause")
                Button(role: .destructive) { model.cancel() } label: {
                    Label("Arrêter", systemImage: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            } else {
                Button { model.start() } label: {
                    Label(model.mode.label, systemImage: model.mode.symbol)
                        .frame(minWidth: 110)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.pendingCount == 0 || model.isRunning)
            }
        }
    }
}

struct TargetButton: View {
    let kind: MediaKind
    @Binding var selection: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).foregroundStyle(.secondary)
                Text(FormatCatalog.format(selection)?.name ?? selection).fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .help("Format de sortie pour les \(kind.label.lowercased())")
        .popover(isPresented: $show, arrowEdge: .top) {
            FormatPicker(kind: kind, selection: Binding(get: { selection }, set: { selection = $0; show = false }))
        }
    }
}

struct PresetMenu<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            Label(title, systemImage: symbol)
        }
        .menuIndicator(.visible)
        .buttonStyle(.glass)
        .fixedSize()
    }
}

struct ScheduleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Planifier le traitement", systemImage: "clock").font(.title3.weight(.semibold))
            Text("Les \(model.pendingCount) fichiers en attente seront traités à l'heure choisie avec les réglages actuels — idéal pour les grosses vidéos pendant la nuit.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Date", selection: $date, in: Date()...)
                .datePickerStyle(.graphical)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Planifier") {
                    let pending = model.items.filter { $0.status == .pending }
                    Scheduler.shared.schedule(paths: pending.map(\.url), mode: model.mode, at: date)
                    model.remove(Set(pending.map(\.id)))
                    Toast.show("Traitement planifié · \(date.formatted(date: .abbreviated, time: .shortened))", symbol: "clock")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
