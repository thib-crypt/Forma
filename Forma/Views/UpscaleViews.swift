import SwiftUI

/// Tracks Apple's super-resolution model (downloaded once by macOS, then fully offline).
@MainActor
@Observable
final class UpscaleModelStatus {
    static let shared = UpscaleModelStatus()
    private(set) var state: Upscaler.ModelState = Upscaler.modelState
    private(set) var error: String?

    func refresh() { if case .downloading = state {} else { state = Upscaler.modelState } }

    func download() {
        guard state == .needsDownload else { return }
        state = .downloading(0); error = nil
        Task {
            do {
                try await Upscaler.prepareModel { p in Task { @MainActor in self.state = .downloading(p) } }
                state = .ready
            } catch {
                self.error = error.localizedDescription
                state = Upscaler.modelState
            }
        }
    }

    var label: String {
        switch state {
        case .unsupported: "IA indisponible sur ce Mac — agrandissement Lanczos"
        case .needsDownload: "Modèle IA à télécharger (une seule fois)"
        case .downloading(let p): "Téléchargement du modèle IA… \(Int(p * 100)) %"
        case .ready: "Super-résolution IA prête · Neural Engine"
        }
    }
}

/// Bottom-bar controls in "Agrandir" mode: fixed ×2 badge + output format.
struct UpscaleControls: View {
    @Environment(PreferencesStore.self) private var store
    @State private var status = UpscaleModelStatus.shared

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 8) {
            Label("×2 IA", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .capsule)
                .help(status.label)
            PresetMenu(symbol: "photo", title: Self.title(store.prefs.processing.upscaleTarget)) {
                Picker("Format de sortie", selection: $store.prefs.processing.upscaleTarget) {
                    ForEach(ProcessingSnapshot.upscaleChoices, id: \.self) { Text(Self.title($0, long: true)).tag($0) }
                }.pickerStyle(.inline)
            }
        }
        .onAppear { status.refresh() }
    }

    static func title(_ id: String, long: Bool = false) -> String {
        if id == "SAME" { return long ? "Format d'origine (PNG si non pris en charge)" : "Format d'origine" }
        guard let f = FormatCatalog.format(id) else { return id }
        return long ? "\(f.name) — \(f.detail)" : f.name
    }
}

/// Model status row used in the empty state and in Settings.
struct UpscaleModelRow: View {
    @State private var status = UpscaleModelStatus.shared

    var body: some View {
        HStack(spacing: 8) {
            switch status.state {
            case .ready:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 80)
            case .needsDownload:
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            case .unsupported:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text(status.label)
            if status.state == .needsDownload {
                Button("Télécharger") { status.download() }.controlSize(.small)
            }
        }
        .font(.callout)
        .onAppear { status.refresh() }
        if let e = status.error { Text(e).font(.caption).foregroundStyle(.red) }
    }
}
