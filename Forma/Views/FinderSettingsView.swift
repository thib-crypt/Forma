import SwiftUI
import AppKit

/// Settings › Finder: the context menu, the Share panel, Services, and recipes.
struct FinderSettingsView: View {
    @Environment(PreferencesStore.self) private var store
    @State private var finderStatus: ExtensionStatus?
    @State private var shareStatus: ExtensionStatus?
    @State private var editing: Recipe?

    var body: some View {
        @Bindable var store = store
        Form {
            statusSection
            Section {
                Toggle("Menu Forma dans le Finder", isOn: $store.prefs.finder.enabled)
                ForEach(MenuBuilder.kindOrder, id: \.self) { kind in
                    FavoritesRow(kind: kind, favorites: favoritesBinding(kind))
                }
                Toggle("Classer selon mes habitudes", isOn: $store.prefs.finder.rankByHabits)
                if store.prefs.finder.rankByHabits { habitsCaption }
            } header: {
                Text("Formats proposés")
            } footer: {
                Text("Les favoris apparaissent en tête du menu (« Convertir en WebP »), tous les autres formats dans « Convertir en… ». Clic droit sur une pastille pour la déplacer.")
            }
            Section("Entrées du menu") {
                Toggle("Compresser", isOn: $store.prefs.finder.showCompress)
                Toggle("Compresser avec un préréglage…", isOn: $store.prefs.finder.showCompressPresets)
                    .disabled(!store.prefs.finder.showCompress)
                Toggle("Agrandir ×2 (IA)", isOn: $store.prefs.finder.showUpscale)
                Toggle("Recettes", isOn: $store.prefs.finder.showRecipes)
                Toggle("Ouvrir dans Forma…", isOn: $store.prefs.finder.showOpenInForma)
                Toggle("Annuler la dernière conversion", isOn: $store.prefs.finder.showUndo)
                Toggle("Icônes", isOn: $store.prefs.finder.showIcons)
                Picker("Favoris hors du sous-menu", selection: $store.prefs.finder.topLevelCount) {
                    Text("Aucun").tag(0)
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            behaviourSection
            recipesSection
            Section {
                Text("Les services « Forma — Convertir / Compresser / Agrandir » travaillent aussi sans ouvrir de fenêtre. Ils restent disponibles dans les dossiers iCloud Drive et OneDrive, où macOS n'affiche pas les menus des extensions, et on peut leur attribuer un raccourci clavier.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Raccourcis clavier des services…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
                }
                Text("Liens pour Raycast, Alfred, BetterTouchTool : forma://convert?to=webp&path=… · forma://compress?path=… · forma://recipe?name=Web&path=…")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } header: {
                Text("Services & liens")
            }
        }
        .formStyle(.grouped)
        .task { await refreshStatus() }
        .sheet(item: $editing) { r in
            RecipeEditor(recipe: r) { saved in
                if let i = store.prefs.recipes.firstIndex(where: { $0.id == saved.id }) { store.prefs.recipes[i] = saved }
                else { store.prefs.recipes.append(saved) }
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            StatusRow(title: "Menu contextuel du Finder", symbol: "contextualmenu.and.cursorarrow", status: finderStatus)
            StatusRow(title: "Menu Partager", symbol: "square.and.arrow.up", status: shareStatus)
            HStack {
                Button("Réglages des extensions…") { ExtensionStatus.openSystemSettings() }
                Button("Réenregistrer") {
                    Task.detached { _ = ExtensionStatus.reset(); await refreshStatus() }
                }
                .help("Enregistre les extensions de cette copie de Forma et oublie les autres (dossier de build…)")
                Spacer()
                Button { Task { await refreshStatus() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Actualiser")
            }
        } header: {
            Text("Extensions")
        } footer: {
            if finderStatus?.state != .enabled {
                Text("Activez « Forma » dans Réglages Système › Général › Ouverture et extensions › Extensions (Finder et Partage).")
            }
        }
    }

    private func refreshStatus() async {
        let (f, s) = await Task.detached { (ExtensionStatus.query(ExtensionStatus.finderID), ExtensionStatus.query(ExtensionStatus.shareID)) }.value
        finderStatus = f
        shareStatus = s
    }

    private var habitsCaption: some View {
        let ranked = MenuConfigPublisher.ranked(HistoryModel.shared.entries)
        let text = MenuBuilder.kindOrder.compactMap { k -> String? in
            guard let ids = ranked[k.rawValue], !ids.isEmpty else { return nil }
            return "\(k.label) : \(ids.compactMap { FormatCatalog.format($0)?.name }.joined(separator: ", "))"
        }.joined(separator: " · ")
        return Text(text.isEmpty ? "Pas encore assez d'historique : les formats que vous utilisez le plus remonteront en tête du menu."
                                 : "D'après l'historique — \(text)")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func favoritesBinding(_ kind: MediaKind) -> Binding<[String]> {
        Binding(get: { store.prefs.finder.favorites(for: kind) },
                set: { store.prefs.finder.favorites[kind.rawValue] = $0 })
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        @Bindable var store = store
        return Section {
            Picker("Résultats", selection: destinationKind) {
                Text("Selon les réglages de sortie").tag(0)
                Text("À côté de l'original").tag(1)
                Text("Dans un dossier précis").tag(2)
                Text("À côté de l'original + presse-papiers").tag(3)
            }
            if case .folder(let p) = store.prefs.finder.destination {
                HStack {
                    Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choisir…") { if let u = chooseFolder() { store.prefs.finder.destination = .folder(u.path) } }
                }
            }
            Picker("Progression", selection: $store.prefs.finder.feedback) {
                ForEach(JobFeedback.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Afficher les résultats dans le Finder", isOn: $store.prefs.finder.revealWhenDone)
            HStack {
                Text("Dossier des partages")
                Spacer()
                Text(store.prefs.finder.sharesFolderURL.lastPathComponent).foregroundStyle(.secondary)
                Button("Choisir…") { if let u = chooseFolder() { store.prefs.finder.sharesFolder = u.path } }
            }
            Toggle("Masquer Forma du Dock quand aucune fenêtre n'est ouverte", isOn: $store.prefs.finder.hideDockIconWithoutWindows)
                .onChange(of: store.prefs.finder.hideDockIconWithoutWindows) { LaunchContext.updateDockPolicy() }
        } header: {
            Text("Travaux lancés du Finder, du menu Partager et des services")
        } footer: {
            Text("Forma travaille en arrière-plan sans ouvrir de fenêtre. Le dossier des partages reçoit les images partagées depuis Safari, Photos ou Mail, qui n'ont pas de fichier d'origine.")
        }
    }

    private var destinationKind: Binding<Int> {
        Binding(get: {
            switch store.prefs.finder.destination {
            case .standard: 0
            case .alongside: 1
            case .folder: 2
            case .clipboard: 3
            }
        }, set: { v in
            switch v {
            case 1: store.prefs.finder.destination = .alongside
            case 2:
                if let u = chooseFolder() { store.prefs.finder.destination = .folder(u.path) }
            case 3: store.prefs.finder.destination = .clipboard
            default: store.prefs.finder.destination = .standard
            }
        })
    }

    private func chooseFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choisir"
        return p.runModal() == .OK ? p.url : nil
    }

    // MARK: Recipes

    private var recipesSection: some View {
        Section {
            ForEach(store.prefs.recipes) { r in
                HStack(spacing: 10) {
                    Image(systemName: r.symbol).frame(width: 20).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).fontWeight(.medium)
                        Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Modifier") { editing = r }.buttonStyle(.borderless)
                    Menu {
                        Button("Dupliquer") {
                            var copy = r; copy.id = UUID(); copy.name += " (copie)"
                            store.prefs.recipes.append(copy)
                        }
                        Button("Supprimer", role: .destructive) { store.prefs.recipes.removeAll { $0.id == r.id } }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .onMove { store.prefs.recipes.move(fromOffsets: $0, toOffset: $1) }
            HStack {
                Button("Nouvelle recette…") { editing = Recipe(name: "Nouvelle recette", targets: [MediaKind.image.rawValue: "WEBP"]) }
                Spacer()
                if store.prefs.recipes.isEmpty {
                    Button("Ajouter les exemples") { store.prefs.recipes = Recipe.examples }
                }
            }
        } header: {
            Text("Recettes")
        } footer: {
            Text("Une recette est une action complète (format, qualité, taille, métadonnées, destination) : menu du Finder, menu Partager, barre des menus, `forma run <nom>` et Raccourcis.")
        }
    }
}

// MARK: - Pieces

private struct StatusRow: View {
    let title: String
    let symbol: String
    let status: ExtensionStatus?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let s = status, let p = s.path, !s.loadsThisApp {
                    Text("Copie chargée : \(p)").font(.caption).foregroundStyle(.orange).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let s = status {
                Label(s.label, systemImage: s.state == .enabled ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(s.state == .enabled ? Color.green : Color.orange)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Favourite formats of one kind as removable, reorderable chips.
private struct FavoritesRow: View {
    let kind: MediaKind
    @Binding var favorites: [String]

    private var outputs: [FormatDescriptor] { FormatCatalog.outputs(for: kind) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(kind.label, systemImage: kind.symbol).frame(width: 150, alignment: .leading)
            FlowLayout(spacing: 5) {
                ForEach(Array(favorites.enumerated()), id: \.element) { i, id in
                    chip(id, index: i)
                }
                Menu {
                    ForEach(outputs.filter { !favorites.contains($0.id) }) { f in
                        Button(f.name) { favorites.append(f.id) }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(favorites.count >= 6)
            }
        }
    }

    private func chip(_ id: String, index: Int) -> some View {
        HStack(spacing: 3) {
            Text(FormatCatalog.format(id)?.name ?? id).font(.system(size: 11.5, weight: .medium))
            Button { favorites.removeAll { $0 == id } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .contextMenu {
            Button("Déplacer à gauche") { move(index, by: -1) }.disabled(index == 0)
            Button("Déplacer à droite") { move(index, by: 1) }.disabled(index == favorites.count - 1)
        }
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard favorites.indices.contains(i), favorites.indices.contains(j) else { return }
        favorites.swapAt(i, j)
    }
}

/// Minimal wrapping layout for the chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing
            row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            row = max(row, sz.height)
        }
    }
}

// MARK: - Recipe editor

struct RecipeEditor: View {
    @State var recipe: Recipe
    var onSave: (Recipe) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nom", text: $recipe.name)
                    Picker("Icône", selection: $recipe.symbol) {
                        ForEach(Recipe.symbols, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) }
                    }
                    Picker("Action", selection: $recipe.mode) {
                        ForEach(ProcessMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                }
                if recipe.mode != .compress {
                    Section {
                        ForEach(recipe.mode == .upscale ? [MediaKind.image] : [MediaKind.image, .video, .audio, .office], id: \.self) { kind in
                            Picker(kind.label, selection: target(kind)) {
                                Text(recipe.mode == .upscale ? "Format d'origine" : "Ne pas traiter").tag("")
                                Divider()
                                ForEach(FormatCatalog.outputs(for: kind)) { Text($0.name).tag($0.id) }
                            }
                        }
                    } header: {
                        Text(recipe.mode == .upscale ? "Format de sortie" : "Convertir")
                    } footer: {
                        if recipe.mode == .convert { Text("Les fichiers d'un type sans format choisi sont ignorés par la recette.") }
                    }
                }
                Section("Réglages") {
                    Picker("Préréglage (images)", selection: $recipe.overrides.preset) {
                        Text("Réglage actuel").tag(CompressionPreset?.none)
                        ForEach(CompressionPreset.allCases.filter { $0 != .custom }) { Text($0.label).tag(Optional($0)) }
                    }
                    OptionalNumber(title: "Qualité (1–100)", value: $recipe.overrides.quality, placeholder: "Réglage actuel", range: 1...100)
                    OptionalNumber(title: "Taille maximale (px)", value: $recipe.overrides.maxDimension, placeholder: "Inchangée", range: 16...20000)
                    OptionalNumber(title: "Poids maximal (Ko)", value: $recipe.overrides.targetSizeKB, placeholder: "Aucun", range: 10...500_000)
                    Picker("Métadonnées", selection: $recipe.overrides.metadata) {
                        Text("Réglage actuel").tag(MetadataMode?.none)
                        ForEach(MetadataMode.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    if recipe.mode == .compress {
                        Toggle("Remplacer les originaux (Corbeille)", isOn: Binding(get: { recipe.overrides.replaceOriginals ?? false },
                                                                                    set: { recipe.overrides.replaceOriginals = $0 ? true : nil }))
                    }
                }
                Section("Destination & visibilité") {
                    Picker("Résultats", selection: $recipe.destination) {
                        Text("Selon les réglages").tag(RequestDestination.standard)
                        Text("À côté de l'original").tag(RequestDestination.alongside)
                        Text("À côté + presse-papiers").tag(RequestDestination.clipboard)
                        if case .folder(let p) = recipe.destination { Text((p as NSString).lastPathComponent).tag(recipe.destination) }
                    }
                    Button("Choisir un dossier…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { recipe.destination = .folder(u.path) }
                    }
                    Toggle("Menu du Finder", isOn: $recipe.showInFinder)
                    Toggle("Menu Partager", isOn: $recipe.showInShare)
                    Toggle("Barre des menus", isOn: $recipe.showInMenuBar)
                }
                Section { Text(recipe.detail).font(.caption).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    recipe.name = recipe.name.trimmingCharacters(in: .whitespaces)
                    if recipe.name.isEmpty { recipe.name = "Recette" }
                    onSave(recipe); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recipe.mode == .convert && recipe.targets.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 620)
    }

    private func target(_ kind: MediaKind) -> Binding<String> {
        Binding(get: { recipe.targets[kind.rawValue] ?? "" },
                set: { recipe.targets[kind.rawValue] = $0.isEmpty ? nil : $0 })
    }
}

private struct OptionalNumber: View {
    let title: String
    @Binding var value: Int?
    let placeholder: String
    let range: ClosedRange<Int>

    var body: some View {
        TextField(title, value: Binding(get: { value }, set: { v in value = v.map { min(range.upperBound, max(range.lowerBound, $0)) } }),
                  format: .number, prompt: Text(placeholder))
    }
}
