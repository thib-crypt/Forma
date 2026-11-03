import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PreferencesStore.self) private var store
    @State private var dropMode: ProcessMode = .compress
    @State private var targeted = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Forma").font(.headline)
                Spacer()
                Picker("", selection: $dropMode) {
                    ForEach(ProcessMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }

            VStack(spacing: 6) {
                Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                Text(dropMode == .convert
                     ? "Déposez pour convertir (\(FormatCatalog.format(store.prefs.processing.imageTarget)?.name ?? "") / \(FormatCatalog.format(store.prefs.processing.videoTarget)?.name ?? ""))"
                     : dropMode == .compress ? "Déposez pour compresser (\(store.prefs.processing.image.preset.label))"
                     : "Déposez des images pour les agrandir ×2 (IA)")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls, mode: dropMode, autoStart: true)
                return true
            } isTargeted: { targeted = $0 }

            if model.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.isPaused ? "En pause" : "Traitement en cours…").font(.caption)
                        Spacer()
                        Text("\(Int(model.overallProgress * 100)) %").font(.caption.monospacedDigit())
                    }
                    ProgressView(value: model.overallProgress)
                }
            } else if let s = model.lastBatchSummary {
                Label(s, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Optimiser automatiquement le presse-papiers", isOn: $store.prefs.clipboardEnabled)
                .onChange(of: store.prefs.clipboardEnabled) { ClipboardOptimizer.shared.apply() }
            Button { ClipboardOptimizer.shared.optimizeNow() } label: {
                Label("Optimiser l'image du presse-papiers", systemImage: "doc.on.clipboard")
            }
            let watched = store.prefs.watchedFolders.filter(\.enabled).count
            Label(watched == 0 ? "Aucun dossier surveillé" : "\(watched) dossier\(watched > 1 ? "s" : "") surveillé\(watched > 1 ? "s" : "")",
                  systemImage: "folder.badge.gearshape")
                .font(.caption).foregroundStyle(.secondary)
            if !store.prefs.scheduledJobs.isEmpty {
                Label("\(store.prefs.scheduledJobs.count) traitement(s) planifié(s)", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Ouvrir Forma") { AppDelegate.showMainWindow() }
                Spacer()
                SettingsLink { Text("Réglages…") }
                Button("Quitter") { NSApp.terminate(nil) }
            }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 320)
        .onAppear { dropMode = model.mode }
    }
}
