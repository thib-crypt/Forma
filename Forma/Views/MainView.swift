import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(PreferencesStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.items.isEmpty {
                DropZoneView(targeted: dropTargeted)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                FileListView()
                    .transition(.opacity)
                if dropTargeted { DropOverlay() }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.items.isEmpty)
        .animation(.smooth(duration: 0.15), value: dropTargeted)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.items.isEmpty { BottomBar().transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(ProcessMode.allCases) { m in
                        Label(m.label, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .frame(width: 400)
                .help("⌘1 Convertir · ⌘2 Compresser · ⌘3 Agrandir")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { AddPanel.present() } label: { Label("Ajouter", systemImage: "plus") }
                    .help("Ajouter des fichiers ou dossiers (⌘O)")
                SettingsLink { Label("Réglages", systemImage: "gearshape") }
            }
        }
        .navigationTitle("")
        .sheet(item: $model.compareItem) { CompareView(item: $0) }
    }
}

// MARK: - Empty state

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    var targeted: Bool

    private var subtitle: String {
        switch model.mode {
        case .convert: "Images, vidéos, audio, PDF et RAW — plus de 130 formats, 100 % en local."
        case .compress: "Réduisez le poids sans perte visible. Les originaux ne sont jamais modifiés par défaut."
        case .upscale: "Doublez la définition de vos images grâce à la super-résolution IA d'Apple,\nexécutée sur le Neural Engine — détails nets, sans halo, 100 % en local."
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(.tint.opacity(targeted ? 0.22 : 0.12)).frame(width: 128, height: 128)
                Image(systemName: model.mode == .upscale ? "sparkles" : model.mode.symbol)
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: targeted)
            }
            VStack(spacing: 6) {
                Text(targeted ? "Relâchez pour ajouter" : "Déposez vos fichiers ici")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if model.mode == .upscale { UpscaleModelRow().padding(.top, 4) }
            }
            Button { AddPanel.present() } label: {
                Label("Ajouter des fichiers ou dossiers…", systemImage: "plus")
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            HStack(spacing: 10) {
                ForEach(model.mode == .upscale ? [MediaKind.image] : MediaKind.allCases) { k in
                    Label(k.label, systemImage: k.symbol)
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            .foregroundStyle(.secondary)

            Text("Apple Silicon · \(SystemInfo.totalCores) cœurs · VideoToolbox")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .padding(24)
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.tint.opacity(0.08))
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .overlay {
                Label("Ajouter à la liste", systemImage: "plus.circle.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(14)
            .allowsHitTesting(false)
    }
}
