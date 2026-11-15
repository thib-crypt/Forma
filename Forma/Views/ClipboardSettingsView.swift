import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ClipboardSettingsView: View {
    @Environment(PreferencesStore.self) private var store
    @State private var optimizer = ClipboardOptimizer.shared
    @State private var editingRule: ClipboardRule?
    @State private var isNewRule = false
    @State private var editingFallback = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Optimiser les images copiées", isOn: $store.prefs.clipboard.enabled)
                Picker("Déclenchement", selection: $store.prefs.clipboard.trigger) {
                    ForEach(ClipboardTrigger.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!store.prefs.clipboard.enabled)
                if store.prefs.clipboard.isPaused, let until = store.prefs.clipboard.pausedUntil {
                    HStack {
                        Label("En pause jusqu'à \(until.formatted(date: .abbreviated, time: .shortened))", systemImage: "pause.circle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reprendre") { ClipboardOptimizer.shared.pause(for: nil) }
                    }
                }
            } header: {
                Text("Optimiseur")
            } footer: {
                Text(store.prefs.clipboard.trigger.help + " Copia utilise les mêmes règles pour « Coller optimisé » (⇧↩).")
            }

            Section {
                ForEach(Array(store.prefs.clipboard.rules.enumerated()), id: \.element.id) { index, rule in
                    RuleRow(rule: rule, index: index,
                            toggle: { store.prefs.clipboard.rules[index].enabled.toggle() },
                            edit: { isNewRule = false; editingRule = rule },
                            move: { move(index, by: $0) },
                            duplicate: {
                                var copy = rule; copy.id = UUID(); copy.name += " (copie)"
                                store.prefs.clipboard.rules.insert(copy, at: index + 1)
                            },
                            delete: { store.prefs.clipboard.rules.remove(at: index) },
                            count: store.prefs.clipboard.rules.count)
                }
                HStack(spacing: 10) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toutes les autres images").fontWeight(.medium)
                        Text(store.prefs.clipboard.fallback.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Modifier") { editingFallback = true }.buttonStyle(.borderless)
                }
                Button {
                    isNewRule = true
                    editingRule = ClipboardRule(name: "Nouvelle règle")
                } label: { Label("Ajouter une règle", systemImage: "plus") }
            } header: {
                Text("Règles")
            } footer: {
                Text("Évaluées de haut en bas : la première règle qui correspond (app d'origine, type d'image, poids) s'applique. « Photos » et « Captures » sont reconnues automatiquement (aplats de couleur, transparence).")
            }

            Section("Conditions générales") {
                Picker("Ignorer les images de moins de", selection: $store.prefs.clipboard.minSizeKB) {
                    ForEach([0, 20, 40, 100, 250, 500, 1000], id: \.self) { Text($0 == 0 ? "Aucune limite" : "\($0) Ko").tag($0) }
                }
                Picker("Garder l'original si le gain est inférieur à", selection: $store.prefs.clipboard.minGainPercent) {
                    ForEach([1, 5, 10, 20, 30, 50], id: \.self) { Text("\($0) %").tag($0) }
                }
                Toggle("Ignorer les images remises par un gestionnaire de presse-papiers (Copia…)", isOn: $store.prefs.clipboard.ignoreClipboardManagers)
                    .help("Quand Copia recolle un ancien élément (par exemple l'original), Forma n'y touche pas.")
            }

            Section {
                Picker("Contenu du presse-papiers", selection: $store.prefs.clipboard.output) {
                    ForEach(ClipboardOutput.allCases) { Text($0.label).tag($0) }
                }
                Text(store.prefs.clipboard.output.help).font(.caption).foregroundStyle(.secondary)
                Picker("Garder les fichiers optimisés", selection: $store.prefs.clipboard.fileRetentionDays) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) jour\($0 > 1 ? "s" : "")").tag($0) }
                }
                Toggle("Afficher une bulle après chaque optimisation", isOn: $store.prefs.clipboard.showToast)
                Toggle("Jouer un son", isOn: $store.prefs.clipboard.playSound)
                Button("Afficher les fichiers optimisés") { NSWorkspace.shared.open(ClipboardEngine.directory) }
                    .buttonStyle(.link)
            } header: {
                Text("Résultat")
            } footer: {
                Text("Les fichiers restent disponibles le temps choisi pour que Copia puisse encore les recoller.")
            }

            Section {
                HStack {
                    Button {
                        Task { await runTest() }
                    } label: { Label("Tester avec l'image du presse-papiers", systemImage: "flask") }
                    .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !optimizer.log.isEmpty {
                    ForEach(optimizer.log.prefix(8)) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.status == .optimized ? "checkmark.circle.fill" : e.status == .noGain ? "equal.circle" : "minus.circle")
                                .foregroundStyle(e.status == .optimized ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(e.app) · \(e.rule)").font(.callout)
                                Text(e.status == .optimized
                                     ? "\(e.before.formattedBytes) → \(e.format ?? "") \(e.after.formattedBytes)"
                                     : e.reason ?? e.status.rawValue)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Essai & journal")
            } footer: {
                Text("L'essai montre quelle règle s'appliquerait et le poids obtenu, sans modifier le presse-papiers.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.prefs.clipboard.enabled) { ClipboardOptimizer.shared.apply() }
        .onChange(of: store.prefs.clipboard.trigger) { ClipboardOptimizer.shared.apply() }
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule, isNew: isNewRule) { saved in
                if let i = store.prefs.clipboard.rules.firstIndex(where: { $0.id == saved.id }) {
                    store.prefs.clipboard.rules[i] = saved
                } else {
                    store.prefs.clipboard.rules.append(saved)
                }
            }
        }
        .sheet(isPresented: $editingFallback) {
            FallbackEditor(action: store.prefs.clipboard.fallback) { store.prefs.clipboard.fallback = $0 }
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let to = index + delta
        guard store.prefs.clipboard.rules.indices.contains(to) else { return }
        store.prefs.clipboard.rules.swapAt(index, to)
    }

    /// Dry run on the current clipboard image: shows the matching rule and the result, never writes the clipboard.
    private func runTest() async {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let candidates: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.init("public.jpeg"), "jpg"), (.init("public.heic"), "heic"), (.tiff, "tiff")]
        var input: URL?
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("forma-cliptest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let (type, ext) = candidates.first(where: { types.contains($0.0) }), let data = pb.data(forType: type) {
            let u = tmp.appendingPathComponent("test." + (ext == "tiff" ? "png" : ext))
            if ext == "tiff" { try? NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])?.write(to: u) } else { try? data.write(to: u) }
            input = u
        } else if let file = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
                  FileDetection.classify(file).mediaKind == .image {
            input = file
        }
        guard let input else { testResult = "Copiez d'abord une image (ou un fichier image)."; return }
        testing = true
        defer { testing = false }
        let source = pb.string(forType: ClipboardOptimizer.sourceType) ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            let o = try await ClipboardEngine.optimize(file: input, sourceApp: source, settings: store.prefs.clipboard, force: false, outputDir: tmp)
            let kind = ClipboardRules.analyze(input)?.isPhoto == true ? "photo" : "capture / graphique"
            switch o.status {
            case .optimized:
                testResult = "Reconnue comme \(kind) · règle « \(o.rule) »\n\(o.before.formattedBytes) → \(o.format?.name ?? "") \(o.after.formattedBytes) (−\(o.savingsPercent) %) · \(o.width) × \(o.height)"
            case .noGain, .skipped:
                testResult = "Reconnue comme \(kind) · règle « \(o.rule) »\nInchangée : \(o.reason ?? "")"
            }
        } catch {
            testResult = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: ClipboardRule
    let index: Int
    let toggle: () -> Void
    let edit: () -> Void
    let move: (Int) -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { _ in toggle() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Image(systemName: rule.action.skip ? "hand.raised" : rule.content.symbol)
                .foregroundStyle(rule.action.skip ? Color.orange : Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).fontWeight(.medium)
                Text(rule.conditionSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("→ " + rule.action.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer()
            Button("Modifier", action: edit).buttonStyle(.borderless)
            Menu {
                Button("Monter", systemImage: "arrow.up") { move(-1) }.disabled(index == 0)
                Button("Descendre", systemImage: "arrow.down") { move(1) }.disabled(index == count - 1)
                Button("Dupliquer", systemImage: "plus.square.on.square", action: duplicate)
                Divider()
                Button("Supprimer", systemImage: "trash", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

// MARK: - Editors

private struct RuleEditor: View {
    @State var rule: ClipboardRule
    let isNew: Bool
    let save: (ClipboardRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nom", text: $rule.name)
                    Toggle("Active", isOn: $rule.enabled)
                }
                Section {
                    if rule.apps.isEmpty {
                        Text("Toutes les apps").foregroundStyle(.secondary)
                    }
                    ForEach(rule.apps) { app in
                        HStack {
                            AppIcon(bundleID: app.bundleID)
                            Text(app.name)
                            Text(app.bundleID).font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Button { rule.apps.removeAll { $0 == app } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button("Ajouter une app…") { pickApp() }
                        Menu("Apps ouvertes") {
                            ForEach(runningApps, id: \.bundleID) { a in
                                Button(a.name) { if !rule.apps.contains(a) { rule.apps.append(a) } }
                            }
                        }
                        .fixedSize()
                    }
                    Picker("Type d'image", selection: $rule.content) {
                        ForEach(ClipboardContentFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Poids minimal", selection: $rule.minSizeKB) {
                        ForEach([0, 50, 200, 500, 1000, 3000], id: \.self) { Text($0 == 0 ? "Aucun" : $0 >= 1000 ? "\($0 / 1000) Mo" : "\($0) Ko").tag($0) }
                    }
                } header: {
                    Text("Quand")
                } footer: {
                    Text("L'app d'origine est celle où l'image a été copiée.")
                }
                ActionEditorSection(action: $rule.action)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Ajouter" : "Enregistrer") { save(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 640)
    }

    private var runningApps: [AppRef] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { AppRef(bundleID: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        p.prompt = "Ajouter"
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            guard let id = Bundle(url: u)?.bundleIdentifier else { continue }
            let ref = AppRef(bundleID: id, name: FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""))
            if !rule.apps.contains(ref) { rule.apps.append(ref) }
        }
    }
}

private struct FallbackEditor: View {
    @State var action: ClipboardAction
    let save: (ClipboardAction) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Form { ActionEditorSection(action: $action, title: "Toutes les autres images") }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(action); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
    }
}

private struct ActionEditorSection: View {
    @Binding var action: ClipboardAction
    var title = "Alors"

    var body: some View {
        Section(title) {
            Toggle("Ne pas toucher à ces images", isOn: $action.skip)
            if !action.skip {
                Picker("Format", selection: $action.format) {
                    ForEach(ClipboardAction.choices, id: \.self) { id in
                        Text(id == "AUTO" ? "Auto (PNG pour les captures, JPEG pour les photos)"
                             : id == "SAME" ? "Même format" : FormatCatalog.format(id)?.name ?? id).tag(id)
                    }
                }
                LabeledContent("Qualité : \(action.quality)") {
                    Slider(value: Binding(get: { Double(action.quality) }, set: { action.quality = Int($0.rounded()) }), in: 30...100)
                }
                Picker("Taille maximale", selection: $action.maxDimension) {
                    Text("Originale").tag(Int?.none)
                    ForEach([1024, 1280, 1600, 1920, 2560, 3840], id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                }
                Toggle("Ramener les captures Retina à leur taille à l'écran (÷2)", isOn: $action.retinaToStandard)
                    .help("Seulement pour les images marquées 144 dpi (captures d'écran d'un écran Retina).")
                Toggle("Supprimer les métadonnées (position GPS, appareil…)", isOn: $action.stripMetadata)
                if action.format == "PNG" || action.format == "AUTO" || action.format == "SAME" {
                    Toggle("PNG avec perte (pngquant, −60 à −80 %)", isOn: $action.lossyPNG)
                }
            }
        }
    }
}

private struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed").frame(width: 18, height: 18)
        }
    }
}
