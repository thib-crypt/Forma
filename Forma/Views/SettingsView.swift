import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") { GeneralSettings() }
            Tab("Images", systemImage: "photo") { ImageSettingsView() }
            Tab("Vidéo", systemImage: "film") { VideoSettingsView() }
            Tab("Audio", systemImage: "waveform") { AudioSettingsView() }
            Tab("Sortie", systemImage: "folder") { OutputSettingsView() }
            Tab("Automatisation", systemImage: "bolt.horizontal") { AutomationSettings() }
            Tab("Presse-papiers", systemImage: "doc.on.clipboard") { ClipboardSettingsView() }
            Tab("Préréglages", systemImage: "square.stack") { PresetsSettings() }
            Tab("Moteurs", systemImage: "cpu") { EnginesSettings() }
        }
        .frame(width: 640, height: 600)
    }
}

// MARK: - Général

struct GeneralSettings: View {
    @Environment(PreferencesStore.self) private var store
    @State private var loginEnabled = LoginItem.isEnabled

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Au dépôt de fichiers") {
                Toggle("Lancer la compression automatiquement", isOn: $store.prefs.autoStartOnDrop)
                Toggle("Copier le résultat dans le presse-papiers", isOn: $store.prefs.autoCopyResult)
                Toggle("Afficher le résultat dans le Finder", isOn: $store.prefs.processing.output.revealWhenDone)
                Toggle("Notification à la fin du traitement", isOn: $store.prefs.notifyWhenDone)
            }
            Section("Démarrage & barre des menus") {
                Toggle("Ouvrir Forma à l'ouverture de session", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { LoginItem.set(loginEnabled) }
                Toggle("Afficher dans la barre des menus", isOn: $store.prefs.showInMenuBar)
                Text("Garde Forma actif pour les dossiers surveillés, le presse-papiers et les dépôts rapides.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Apparence", selection: $store.prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Garder l'historique des traitements", isOn: $store.prefs.historyEnabled)
                Picker("Conserver", selection: $store.prefs.historyRetentionDays) {
                    Text("7 jours").tag(7); Text("30 jours").tag(30); Text("90 jours").tag(90)
                    Text("1 an").tag(365); Text("Sans limite").tag(0)
                }
                .disabled(!store.prefs.historyEnabled)
            } header: {
                Text("Historique")
            } footer: {
                Text("Chaque traitement (app, Terminal, Raccourcis, dossiers surveillés) peut être annulé : le résultat part à la Corbeille et l'original revient s'il y avait été mis. ⌘Y pour l'ouvrir, ⌥⌘Z pour annuler le dernier lot.")
            }
            Section {
                Picker("Images en parallèle", selection: $store.prefs.maxParallelImages) {
                    Text("Auto (\(SystemInfo.imageParallelism(requested: 0)))").tag(0)
                    ForEach([1, 2, 4, 6, 8, 12], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Vidéos en parallèle", selection: $store.prefs.maxParallelVideos) {
                    ForEach([1, 2, 3, 4], id: \.self) { Text("\($0)").tag($0) }
                }
            } header: {
                Text("Performances")
            } footer: {
                Text("\(SystemInfo.totalCores) cœurs (\(SystemInfo.performanceCores) performance) · \(Int(SystemInfo.memoryGB.rounded())) Go. La cadence baisse automatiquement si le Mac chauffe.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Images

struct ImageSettingsView: View {
    var body: some View {
        Form {
            ImageCompressionSection()
            ResizeSection()
            MetadataSection()
            ColorSection()
            WatermarkSection()
            DocumentSection()
        }
        .formStyle(.grouped)
    }
}

struct ImageCompressionSection: View {
    @Environment(PreferencesStore.self) private var store
    @State private var useTarget = false
    var body: some View {
        @Bindable var store = store
        Section("Compression") {
            Picker("Préréglage", selection: $store.prefs.processing.image.preset) {
                ForEach(CompressionPreset.allCases) { p in
                    VStack(alignment: .leading) { Text(p.label); Text(p.detail).font(.caption) }.tag(p)
                }
            }
            if store.prefs.processing.image.preset == .custom {
                LabeledContent("Qualité : \(store.prefs.processing.image.customQuality)") {
                    Slider(value: Binding(get: { Double(store.prefs.processing.image.customQuality) },
                                          set: { store.prefs.processing.image.customQuality = Int($0) }), in: 10...100, step: 1)
                }
            }
            Toggle("Taille de fichier cible", isOn: Binding(get: { store.prefs.processing.image.targetFileSizeKB != nil },
                                                             set: { store.prefs.processing.image.targetFileSizeKB = $0 ? 500 : nil }))
            if let kb = store.prefs.processing.image.targetFileSizeKB {
                Stepper("≤ \(kb) Ko", value: Binding(get: { kb }, set: { store.prefs.processing.image.targetFileSizeKB = $0 }), in: 20...20000, step: kb < 200 ? 10 : 50)
            }
            Toggle("Compresser aussi pendant la conversion", isOn: $store.prefs.processing.compressWhileConverting)
            Toggle("PNG avec perte (pngquant)", isOn: $store.prefs.processing.image.lossyPNG)
            Toggle("JPEG progressif", isOn: $store.prefs.processing.image.progressiveJPEG)
            Toggle("Optimisation MozJPEG", isOn: $store.prefs.processing.image.useMozJPEG)
                .disabled(!Tool.mozjpeg.isAvailable)
                .help(Tool.mozjpeg.isAvailable ? "" : "brew install mozjpeg")
            Picker("Effort WebP / AVIF / JPEG XL", selection: $store.prefs.processing.image.effort) {
                Text("Rapide").tag(3); Text("Équilibré").tag(6); Text("Maximal").tag(9)
            }
            Toggle("Conserver les animations (GIF, WebP, APNG)", isOn: $store.prefs.processing.image.animatedFrames)
        }
    }
}

struct ResizeSection: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        let s = store.prefs.processing.image
        Section("Redimensionnement") {
            Picker("Mode", selection: $store.prefs.processing.image.resizeMode) {
                ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
            }
            if s.resizeMode != .none {
                Text(s.resizeMode.help).font(.caption).foregroundStyle(.secondary)
            }
            switch s.resizeMode {
            case .fit, .exact, .fill:
                HStack {
                    TextField("Largeur", value: $store.prefs.processing.image.width, format: .number).frame(width: 90)
                    Text("×")
                    TextField("Hauteur", value: $store.prefs.processing.image.height, format: .number).frame(width: 90)
                    Text("px")
                    Spacer()
                    Menu("Tailles") {
                        ForEach([(3840, 2160, "4K"), (2560, 1440, "1440p"), (1920, 1080, "Full HD"), (1280, 720, "HD"), (1080, 1080, "Carré 1080"), (1080, 1350, "Instagram portrait"), (800, 600, "800 × 600")], id: \.2) { w, h, n in
                            Button(n) { store.prefs.processing.image.width = w; store.prefs.processing.image.height = h }
                        }
                    }.fixedSize()
                }
            case .width:
                TextField("Largeur (px)", value: $store.prefs.processing.image.width, format: .number)
            case .height:
                TextField("Hauteur (px)", value: $store.prefs.processing.image.height, format: .number)
            case .percent:
                Stepper("\(s.percent) %", value: $store.prefs.processing.image.percent, in: 5...400, step: 5)
            case .none: EmptyView()
            }
            if s.resizeMode != .none && s.resizeMode != .percent && s.resizeMode != .fill {
                Toggle("Agrandir les petites images", isOn: $store.prefs.processing.image.upscale)
            }
        }
    }
}

struct MetadataSection: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Section("Métadonnées & orientation") {
            Picker("Métadonnées", selection: $store.prefs.processing.image.metadata) {
                ForEach(MetadataMode.allCases) { Text($0.label).tag($0) }
            }
            Text(store.prefs.processing.image.metadata.help).font(.caption).foregroundStyle(.secondary)
            Picker("Orientation", selection: $store.prefs.processing.image.orientation) {
                ForEach(OrientationMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Ajouter mon copyright aux images exportées", isOn: $store.prefs.processing.image.copyrightEnabled)
            if store.prefs.processing.image.copyrightEnabled {
                TextField("Auteur", text: $store.prefs.processing.image.artist)
                TextField("Copyright", text: $store.prefs.processing.image.copyright, prompt: Text("© 2026 Thibault"))
            }
        }
    }
}

struct ColorSection: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Section("Couleur & impression") {
            Picker("Espace colorimétrique", selection: $store.prefs.processing.image.colorSpace) {
                ForEach(ColorSpaceTarget.allCases) { c in Text("\(c.label) — \(c.detail)").tag(c) }
            }
            if store.prefs.processing.image.colorSpace != .keep {
                Picker("Rendu", selection: $store.prefs.processing.image.renderingIntent) {
                    ForEach(RenderingIntent.allCases) { Text($0.label).tag($0) }
                }
            }
            Picker("DPI", selection: $store.prefs.processing.image.dpi) {
                Text("Conserver").tag(Int?.none)
                ForEach([72, 96, 150, 240, 300, 600], id: \.self) { Text("\($0) dpi").tag(Int?.some($0)) }
            }
            Text("Le DPI est une étiquette pour les logiciels d'impression ; il ne change pas les pixels.").font(.caption).foregroundStyle(.secondary)
            ColorPicker("Fond (transparence → JPEG…)", selection: Binding(
                get: { Color(nsColor: NSColor(hex: store.prefs.processing.image.backgroundHex) ?? .white) },
                set: { store.prefs.processing.image.backgroundHex = NSColor($0).hexString }), supportsOpacity: false)
        }
    }
}

struct WatermarkSection: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        let w = store.prefs.processing.image.watermark
        Section("Filigrane") {
            Toggle("Ajouter un filigrane", isOn: $store.prefs.processing.image.watermark.enabled)
                .disabled(w.imagePath == nil)
            HStack {
                if let p = w.imagePath, let img = NSImage(contentsOfFile: p) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 32)
                    Text(URL(fileURLWithPath: p).lastPathComponent).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Aucune image").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choisir…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg, .svg, .webP, .heic, .tiff]
                    panel.message = "Choisissez une image de filigrane (PNG transparent recommandé)"
                    if panel.runModal() == .OK, let u = panel.url {
                        store.prefs.processing.image.watermark.imagePath = u.path
                        store.prefs.processing.image.watermark.enabled = true
                    }
                }
            }
            if w.enabled {
                Picker("Position", selection: $store.prefs.processing.image.watermark.position) {
                    ForEach(WatermarkPosition.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Opacité \(Int(w.opacity * 100)) %") {
                    Slider(value: $store.prefs.processing.image.watermark.opacity, in: 0.05...1)
                }
                LabeledContent("Taille \(Int(w.relativeSize * 100)) % de la largeur") {
                    Slider(value: $store.prefs.processing.image.watermark.relativeSize, in: 0.03...0.8)
                }
                LabeledContent("Marge") {
                    Slider(value: $store.prefs.processing.image.watermark.margin, in: 0...0.15)
                }
                Toggle("Appliquer aussi aux vidéos", isOn: $store.prefs.processing.image.watermark.applyToVideos)
            }
        }
    }
}

struct DocumentSection: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Section("PDF, EPS & Illustrator") {
            Toggle("Exporter chaque page (sinon la première)", isOn: $store.prefs.processing.image.pdfPerPage)
            Picker("Résolution de rendu", selection: $store.prefs.processing.image.pdfDPI) {
                ForEach([72, 150, 200, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
            }
        }
    }
}

// MARK: - Vidéo

struct VideoSettingsView: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        let v = store.prefs.processing.video
        Form {
            Section("Encodage") {
                Picker("Préréglage de compression", selection: $store.prefs.processing.video.preset) {
                    ForEach(VideoPreset.allCases) { p in Text("\(p.label) — \(p.detail)").tag(p) }
                }
                Picker("Codec (conversion & personnalisé)", selection: $store.prefs.processing.video.codec) {
                    ForEach(VideoCodec.allCases) { c in Text(c.label + (c.hardware != nil ? "  ⚡︎" : "")).tag(c) }
                }
                LabeledContent("Qualité : \(v.quality)") {
                    Slider(value: Binding(get: { Double(v.quality) }, set: { store.prefs.processing.video.quality = Int($0) }), in: 10...100)
                }
                Toggle("Accélération matérielle (VideoToolbox)", isOn: $store.prefs.processing.video.hardwareAcceleration)
                Text("⚡︎ H.264, HEVC et ProRes utilisent les moteurs média de la puce M3 Pro : jusqu'à 10× plus rapide, bascule automatique en logiciel si besoin.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Vitesse d'encodage (logiciel)", selection: $store.prefs.processing.video.speed) {
                    ForEach(EncodingSpeed.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Image") {
                Picker("Résolution", selection: $store.prefs.processing.video.resolution) {
                    ForEach(VideoResolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Images par seconde", selection: $store.prefs.processing.video.frameRate) {
                    Text("Conserver").tag(Int?.none)
                    ForEach([60, 30, 25, 24, 15], id: \.self) { Text("\($0) i/s").tag(Int?.some($0)) }
                }
                Picker("Vitesse de lecture", selection: $store.prefs.processing.video.playbackSpeed) {
                    ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { Text("\($0.formatted())×").tag($0) }
                }
            }
            Section("Découpe") {
                Toggle("Découper", isOn: Binding(get: { v.trimStart != nil || v.trimEnd != nil },
                                                 set: { on in store.prefs.processing.video.trimStart = on ? 0 : nil; store.prefs.processing.video.trimEnd = on ? 30 : nil }))
                if v.trimStart != nil || v.trimEnd != nil {
                    HStack {
                        TextField("Début (s)", value: $store.prefs.processing.video.trimStart, format: .number)
                        TextField("Fin (s)", value: $store.prefs.processing.video.trimEnd, format: .number)
                    }
                }
            }
            Section("Son & sous-titres") {
                Toggle("Supprimer la piste audio", isOn: $store.prefs.processing.video.removeAudio)
                Picker("Débit audio", selection: $store.prefs.processing.video.audioBitrate) {
                    ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag($0) }
                }
                Toggle("Joindre les sous-titres .srt / .vtt du même nom", isOn: $store.prefs.processing.video.autoAttachSubtitles)
                Toggle("Incruster les sous-titres dans l'image", isOn: $store.prefs.processing.video.burnSubtitles)
            }
            Section("GIF / WebP / APNG animés") {
                Stepper("\(v.gifFPS) images/s", value: $store.prefs.processing.video.gifFPS, in: 5...50)
                Stepper("Largeur max \(v.gifWidth) px", value: $store.prefs.processing.video.gifWidth, in: 120...1920, step: 40)
                Picker("Couleurs", selection: $store.prefs.processing.video.gifColors) {
                    ForEach([32, 64, 128, 256], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Lecture en boucle", isOn: $store.prefs.processing.video.gifLoop)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

struct AudioSettingsView: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Qualité") {
                Picker("Préréglage", selection: $store.prefs.processing.audio.preset) {
                    ForEach(AudioPreset.allCases) { p in Text("\(p.label) — \(p.detail)").tag(p) }
                }
                if store.prefs.processing.audio.preset == .custom {
                    Picker("Débit", selection: $store.prefs.processing.audio.bitrate) {
                        ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag($0) }
                    }
                }
                Picker("Mode de débit", selection: $store.prefs.processing.audio.mode) {
                    ForEach(AudioBitrateMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Fréquence", selection: $store.prefs.processing.audio.sampleRate) {
                    Text("Conserver").tag(Int?.none)
                    ForEach([22050, 32000, 44100, 48000, 96000], id: \.self) { Text("\(Double($0) / 1000, specifier: "%g") kHz").tag(Int?.some($0)) }
                }
                Toggle("Convertir en mono (fichiers plus légers, idéal pour la voix)", isOn: $store.prefs.processing.audio.mono)
                Toggle("Normaliser le volume (EBU R128)", isOn: $store.prefs.processing.audio.normalize)
            }
            Section("Compression") {
                Picker("Codec pour les fichiers sans perte (WAV, AIFF, FLAC…)", selection: $store.prefs.processing.audio.compressCodec) {
                    Text("AAC (recommandé)").tag("AAC")
                    Text("MP3").tag("MP3")
                    Text("Opus").tag("OPUS")
                    Text("FLAC (sans perte)").tag("FLAC")
                }
                Text("AAC offre la meilleure compatibilité. FLAC est sans perte (fichiers plus gros).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pochette") {
                Toggle("Intégrer cover.jpg / folder.jpg du dossier source", isOn: $store.prefs.processing.audio.embedCoverArt)
                Toggle("Ignorer les fichiers ayant déjà une pochette", isOn: $store.prefs.processing.audio.skipIfArtwork)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sortie

struct OutputSettingsView: View {
    var body: some View {
        Form {
            OutputLocationSection()
            FileNamingSection()
            FormatMappingsSection()
        }
        .formStyle(.grouped)
    }
}

struct OutputLocationSection: View {
    @Environment(PreferencesStore.self) private var store
    var body: some View {
        @Bindable var store = store
        let o = store.prefs.processing.output
        Section("Emplacement") {
            Picker("Enregistrer", selection: $store.prefs.processing.output.destination) {
                ForEach(OutputDestination.allCases) { Text($0.label).tag($0) }
            }
            if o.destination == .subfolder {
                TextField("Nom du sous-dossier", text: $store.prefs.processing.output.subfolderName)
            }
            if o.destination == .custom {
                HStack {
                    Text(o.customFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Aucun dossier").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choisir…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        p.message = "Dossier de sortie des fichiers traités"
                        if p.runModal() == .OK { store.prefs.processing.output.customFolderPath = p.url?.path }
                    }
                }
            }
            Picker("Si le fichier existe", selection: $store.prefs.processing.output.conflict) {
                ForEach(ConflictPolicy.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Conserver les dates de création / modification", isOn: $store.prefs.processing.output.preserveDates)
            Toggle("Compression : remplacer les originaux", isOn: $store.prefs.processing.output.replaceOriginals)
            if o.replaceOriginals { Text("Les originaux sont placés dans la Corbeille, récupérables.").font(.caption).foregroundStyle(.orange) }
            Toggle("Conversion : supprimer les originaux après traitement", isOn: $store.prefs.processing.output.deleteOriginals)
            if o.deleteOriginals { Text("Les originaux seront placés dans la Corbeille. Vérifiez avant d'activer.").font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct FileNamingSection: View {
    @Environment(PreferencesStore.self) private var store
    @State private var focusConvert = true
    var body: some View {
        @Bindable var store = store
        let o = store.prefs.processing.output
        Section {
            TextField("Conversion", text: $store.prefs.processing.output.convertPattern)
            Toggle("Même modèle pour la compression", isOn: $store.prefs.processing.output.samePatternForCompress)
            if !o.samePatternForCompress {
                TextField("Compression", text: $store.prefs.processing.output.compressPattern)
            }
            TextField("Agrandissement", text: $store.prefs.processing.output.upscalePattern)
            FlowTokens { token in
                if o.samePatternForCompress || focusConvert { store.prefs.processing.output.convertPattern += token }
                else { store.prefs.processing.output.compressPattern += token }
            }
            Picker("Les jetons s'ajoutent à", selection: $focusConvert) {
                Text("Conversion").tag(true); Text("Compression").tag(false)
            }.pickerStyle(.segmented).disabled(o.samePatternForCompress)
            let sample = NamePattern.render(o.convertPattern, .init(original: "IMG_4021", date: Date(), camera: "iPhone 17 Pro", width: 4032, height: 3024, format: "webp", index: 1))
            LabeledContent("Aperçu", value: "\(sample).webp")
        } header: {
            Text("Noms de fichiers")
        } footer: {
            Text("Les métadonnées manquantes reprennent le nom d'origine. Les jetons inconnus sont retirés.")
        }
    }
}

struct FlowTokens: View {
    var add: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(NamePattern.tokens, id: \.token) { t in
                Button(t.token) { add(t.token) }
                    .font(.system(size: 11, design: .monospaced))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(t.help)
            }
        }
    }
}

struct FormatMappingsSection: View {
    @Environment(PreferencesStore.self) private var store
    @State private var newInput = "heic"
    @State private var newOutput = "JPEG"
    var body: some View {
        @Bindable var store = store
        Section {
            ForEach($store.prefs.processing.mappings) { $m in
                HStack {
                    Text(".\(m.input)").font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(FormatCatalog.format(m.output)?.name ?? m.output)
                    Spacer()
                    Button(role: .destructive) { store.prefs.processing.mappings.removeAll { $0.id == m.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Extension", text: $newInput).frame(width: 90)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("", selection: $newOutput) {
                    ForEach(FormatCatalog.all) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                Button("Ajouter") {
                    let ext = newInput.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                    guard !ext.isEmpty else { return }
                    store.prefs.processing.mappings.removeAll { $0.input == ext }
                    store.prefs.processing.mappings.append(FormatMapping(input: ext, output: newOutput))
                }
            }
        } header: {
            Text("Conversions par défaut")
        } footer: {
            Text("Ex. : toujours convertir les .heic en JPEG et les .mov en MP4, quel que soit le format choisi dans la barre.")
        }
    }
}

// MARK: - Automatisation

struct AutomationSettings: View {
    @Environment(PreferencesStore.self) private var store
    @State private var editing: WatchedFolder?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach($store.prefs.watchedFolders) { $f in
                    HStack {
                        Toggle("", isOn: $f.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .onChange(of: f.enabled) { FolderWatcher.shared.reload() }
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: f.path).lastPathComponent).fontWeight(.medium)
                            Text("\(f.mode.label) · \(f.mode == .convert ? "\(f.imageTarget)/\(f.videoTarget)/\(f.audioTarget)" : f.mode == .upscale ? "images ×2 IA" : "préréglages actuels") → \(f.outputSubfolder)/ · \(f.processedCount) traité(s)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Modifier") { editing = f }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            store.prefs.watchedFolders.removeAll { $0.id == f.id }
                            FolderWatcher.shared.reload()
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Button("Ajouter un dossier à surveiller…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false
                    p.message = "Sélectionnez un dossier à surveiller pour un traitement automatique"
                    if p.runModal() == .OK, let u = p.url {
                        guard !store.prefs.watchedFolders.contains(where: { u.path.hasPrefix($0.path) || $0.path.hasPrefix(u.path) }) else {
                            Toast.show("Ce dossier chevauche un dossier déjà surveillé", symbol: "exclamationmark.triangle"); return
                        }
                        editing = WatchedFolder(path: u.path)
                    }
                }
            } header: {
                Text("Dossiers surveillés")
            } footer: {
                Text("Chaque nouveau fichier déposé dans un dossier surveillé est traité automatiquement (ex. : Captures d'écran → WebP). Les résultats vont dans un sous-dossier.")
            }

            Section("Traitements planifiés") {
                if store.prefs.scheduledJobs.isEmpty {
                    Text("Aucun. Utilisez « … › Planifier pour plus tard » dans la fenêtre principale.").foregroundStyle(.secondary)
                }
                ForEach(store.prefs.scheduledJobs) { j in
                    HStack {
                        Label("\(j.mode.label) \(j.paths.count) fichier(s)", systemImage: "clock")
                        Spacer()
                        Text(j.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Button(role: .destructive) { Scheduler.shared.cancel(j.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { f in
            WatchedFolderSheet(folder: f) { saved in
                if let i = store.prefs.watchedFolders.firstIndex(where: { $0.id == saved.id }) { store.prefs.watchedFolders[i] = saved }
                else { store.prefs.watchedFolders.append(saved) }
                FolderWatcher.shared.reload()
            }
        }
    }
}

struct WatchedFolderSheet: View {
    @State var folder: WatchedFolder
    var onSave: (WatchedFolder) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(URL(fileURLWithPath: folder.path).lastPathComponent) {
                    Picker("Action", selection: $folder.mode) { ForEach(ProcessMode.allCases) { Text($0.label).tag($0) } }
                    if folder.mode == .convert {
                        Picker("Images →", selection: $folder.imageTarget) { ForEach(FormatCatalog.images) { Text($0.name).tag($0.id) } }
                        Picker("Vidéos →", selection: $folder.videoTarget) { ForEach(FormatCatalog.video + FormatCatalog.audio) { Text($0.name).tag($0.id) } }
                        Picker("Audio →", selection: $folder.audioTarget) { ForEach(FormatCatalog.audio) { Text($0.name).tag($0.id) } }
                        Picker("Documents →", selection: Binding(get: { folder.officeTarget ?? "PDFDOC" }, set: { folder.officeTarget = $0 })) {
                            ForEach(FormatCatalog.office) { Text($0.name).tag($0.id) }
                        }
                    }
                    TextField("Sous-dossier de sortie", text: $folder.outputSubfolder)
                    Toggle("Inclure les sous-dossiers", isOn: $folder.includeSubfolders)
                    Toggle("Traiter les fichiers déjà présents", isOn: $folder.processExisting)
                    if folder.processedCount > 0 {
                        Button("Autoriser le retraitement des fichiers déjà traités") { folder.lastRun = nil; folder.processedCount = 0 }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    if folder.outputSubfolder.trimmingCharacters(in: .whitespaces).isEmpty { folder.outputSubfolder = "Forma" }
                    onSave(folder); dismiss()
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 460, height: 440)
    }
}

// MARK: - Préréglages

struct PresetsSettings: View {
    @Environment(PreferencesStore.self) private var store
    @State private var name = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack {
                    TextField("Nom du préréglage", text: $name, prompt: Text("Ex. : Blog, Client X, Archive…"))
                    Menu("Enregistrer") {
                        Button("Réglages images") { save(\.imagePresets, store.prefs.processing.image) }
                        Button("Réglages vidéo") { save(\.videoPresets, store.prefs.processing.video) }
                        Button("Réglages audio") { save(\.audioPresets, store.prefs.processing.audio) }
                    }
                    .fixedSize()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Enregistrer les réglages actuels") } footer: {
                Text("Images : compression, redimensionnement, métadonnées, couleur, filigrane. Vidéo : codec, qualité, vitesse. Audio : débit et options.")
            }
            presetList("Images", store.prefs.imagePresets, apply: { store.prefs.processing.image = $0 }, delete: { id in store.prefs.imagePresets.removeAll { $0.id == id } })
            presetList("Vidéo", store.prefs.videoPresets, apply: { store.prefs.processing.video = $0 }, delete: { id in store.prefs.videoPresets.removeAll { $0.id == id } })
            presetList("Audio", store.prefs.audioPresets, apply: { store.prefs.processing.audio = $0 }, delete: { id in store.prefs.audioPresets.removeAll { $0.id == id } })
        }
        .formStyle(.grouped)
    }

    private func save<T>(_ kp: WritableKeyPath<Preferences, [NamedPreset<T>]>, _ value: T) {
        store.prefs[keyPath: kp].append(NamedPreset(name: name.trimmingCharacters(in: .whitespaces), value: value))
        name = ""
    }

    @ViewBuilder
    private func presetList<T>(_ title: String, _ list: [NamedPreset<T>], apply: @escaping (T) -> Void, delete: @escaping (UUID) -> Void) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Button("Appliquer") { apply(p.value); Toast.show("Préréglage « \(p.name) » appliqué", symbol: "checkmark") }
                        Button(role: .destructive) { delete(p.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - Moteurs

struct EnginesSettings: View {
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var cliError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("ImageIO / Core Graphics") { Label("Intégré", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                LabeledContent("VideoToolbox / AudioToolbox") { Label("Intégré", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                ForEach(Tool.allCases, id: \.self) { t in
                    LabeledContent {
                        if t.isAvailable {
                            Label("Installé", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Copier `brew install \(t.brewFormula)`") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install \(t.brewFormula)", forType: .string)
                            }.controlSize(.small)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(t.label)
                            Text(t.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Moteurs") } footer: {
                Text("Forma privilégie les frameworks natifs d'Apple. Les outils Homebrew couvrent les formats exotiques et les optimisations avancées ; ils sont facultatifs.")
            }
            Section {
                UpscaleModelRow()
            } header: { Text("Super-résolution IA") } footer: {
                Text("Modèle d'Apple (VideoToolbox) exécuté sur le Neural Engine. macOS le télécharge une seule fois ; ensuite tout reste hors ligne. L'image est traitée en tuiles à ×4 puis réduite à ×2 en Lanczos pour un résultat sans artefact.")
            }
            Section {
                Toggle("Commande `forma` dans le Terminal", isOn: Binding(get: { cliInstalled }, set: { on in
                    cliError = on ? CLIInstaller.install() : CLIInstaller.uninstall()
                    cliInstalled = CLIInstaller.isInstalled
                }))
                if let cliError { Text(cliError).font(.caption).foregroundStyle(.red) }
                Text("forma convert ~/Desktop/*.heic --to jpg\nforma compress ~/Movies/clip.mov --preset balanced\nforma upscale ~/Pictures/logo.png\nforma formats")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            } header: { Text("Ligne de commande") } footer: {
                Text("Crée un lien symbolique dans /usr/local/bin. Raccourcis : actions « Convertir des fichiers », « Compresser des fichiers » et « Agrandir des images ×2 ». Finder : clic droit › Services › Forma.")
            }
            Section("À propos") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Formats de sortie", value: "\(FormatCatalog.all.count)")
                LabeledContent("Confidentialité", value: "100 % local (seul macOS télécharge une fois le modèle IA)")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Quick settings popover (bottom bar)

struct QuickSettings: View {
    let mode: ProcessMode
    var body: some View {
        Form {
            if mode == .compress { ImageCompressionSection() }
            if mode != .upscale { ResizeSection() }
            MetadataSection()
            OutputLocationSection()
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
    }
}
