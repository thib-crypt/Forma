import SwiftUI
import AppKit

// MARK: - Window

/// One reusable, resizable window (can go full screen) for before/after comparisons.
@MainActor
enum PreviewWindow {
    private static var window: NSWindow?

    static func show(_ request: PreviewRequest) {
        let root = PreviewView(request: request, close: { window?.close() })
            .environment(AppModel.shared)
            .environment(PreferencesStore.shared)
            .preferredColorScheme(PreferencesStore.shared.colorScheme)
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = []
        let title = "Aperçu — \(request.fileName)"
        if let w = window {
            w.contentViewController = host
            w.title = title
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = title
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 520)
        w.setContentSize(NSSize(width: 1180, height: 800))
        w.center()
        w.setFrameAutosaveName("FormaPreview")
        w.collectionBehavior.insert(.fullScreenPrimary)
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func open(_ item: FileItem, mode: ProcessMode) {
        guard PreviewRenderer.canPreview(item.kind) else { NSSound.beep(); return }
        show(PreviewRequest(source: .item(item, mode)))
    }
}

@MainActor extension PreviewRequest {
    var fileName: String {
        switch source {
        case .item(let i, _): i.name
        case .history(let e): e.input.lastPathComponent
        }
    }
}

// MARK: - View

enum CompareDisplay: String, CaseIterable, Identifiable {
    case split, sideBySide, difference
    var id: String { rawValue }
    var label: String {
        switch self {
        case .split: "Glisser"
        case .sideBySide: "Côte à côte"
        case .difference: "Différences"
        }
    }
    var symbol: String {
        switch self {
        case .split: "rectangle.split.2x1"
        case .sideBySide: "square.split.2x1"
        case .difference: "plusminus"
        }
    }
}

struct PreviewView: View {
    let request: PreviewRequest
    var close: () -> Void

    @Environment(PreferencesStore.self) private var store
    @Environment(AppModel.self) private var model

    @State private var before: PreviewSide?
    @State private var after: PreviewSide?
    @State private var afterVersion = 0
    @State private var elapsed: TimeInterval?
    @State private var keepsOriginal = false
    @State private var rendering = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var diff: CGImage?

    @State private var display: CompareDisplay = .split
    @State private var split: CGFloat = 0.5
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var canvasFit: CGSize = .zero
    @State private var showSettings = false
    @State private var historyEntry: HistoryEntry?

    // MARK: Derived

    private var item: FileItem? { if case .item(let i, _) = request.source { i } else { nil } }
    private var mode: ProcessMode {
        switch request.source {
        case .item(_, let m): m
        case .history(let e): e.mode
        }
    }
    private var kind: MediaKind {
        switch request.source {
        case .item(let i, _): i.kind
        case .history(let e): FileDetection.classify(e.input).mediaKind ?? .image
        }
    }
    /// Live = re-encode with the current settings. Otherwise we compare against an existing output.
    private var isLive: Bool {
        guard let item else { return false }
        return !(item.status == .done && !item.outputs.isEmpty)
    }
    private var originalURL: URL? {
        switch request.source {
        case .item(let i, _): i.url
        case .history(let e): e.readableOriginal
        }
    }
    private var existingOutput: URL? {
        switch request.source {
        case .item(let i, _): i.outputs.first
        case .history(let e): e.outputURLs.first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private struct RenderKey: Equatable {
        var live: Bool
        var snapshot: ProcessingSnapshot
        var override: String?
        var output: URL?
    }
    private var renderKey: RenderKey {
        RenderKey(live: isLive, snapshot: isLive ? store.prefs.processing : ProcessingSnapshot(),
                  override: item?.targetOverride, output: isLive ? nil : existingOutput)
    }

    private var savings: Double? {
        guard let b = before?.bytes, let a = after?.bytes, b > 0, a > 0, mode != .upscale else { return nil }
        return 1 - Double(a) / Double(b)
    }

    private var pixelated: Bool {
        guard let a = after, a.pixelWidth > 0, canvasFit.width > 0, mode != .upscale else { return false }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return canvasFit.width * zoom * scale > CGFloat(a.pixelWidth) * 1.01
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            footer
        }
        .background(.background)
        .task(id: originalURL) { await loadBefore() }
        .task(id: renderKey) { await renderAfter() }
        .task(id: "\(display.rawValue)-\(afterVersion)") { await computeDiff() }
        .onAppear { historyEntry = currentHistoryEntry() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            SideInfo(title: "Original", side: before, alignment: .leading, missing: originalURL == nil ? "Original introuvable" : nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Picker("Affichage", selection: $display) {
                    ForEach(CompareDisplay.allCases) { d in
                        Label(d.label, systemImage: d.symbol).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Glisser · Côte à côte · Carte des différences (×8)")
                zoomControls
            }

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    if rendering {
                        ProgressView().controlSize(.small)
                        Text(progress > 0.03 ? "Calcul… \(Int(progress * 100)) %" : "Calcul de l'aperçu…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(isLive ? "Aperçu" : "Résultat").font(.headline)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).multilineTextAlignment(.trailing)
                } else if let a = after {
                    HStack(spacing: 6) {
                        Text(Self.describe(a)).font(.caption).foregroundStyle(.secondary)
                        SavingsBadge(savings: savings, estimated: a.estimated)
                    }
                    if keepsOriginal {
                        Text("Déjà optimisé : l'original sera conservé").font(.caption2).foregroundStyle(.orange)
                    } else if let note = a.note ?? elapsed.map({ "Encodé en \(AppModel.format($0))" }) {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1.001)
            Menu {
                Button("Ajusté à la fenêtre") { setZoom(1) }
                Button("Taille réelle (pixels)") { setZoom(actualPixelsZoom) }
                Button("200 % des pixels") { setZoom(actualPixelsZoom * 2) }
                Button("400 % des pixels") { setZoom(actualPixelsZoom * 4) }
            } label: {
                Text(zoomLabel).monospacedDigit().frame(minWidth: 62)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command).hidden().frame(width: 0)
            Button("") { setZoom(actualPixelsZoom) }.keyboardShortcut("1", modifiers: .command).hidden().frame(width: 0)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private var actualPixelsZoom: CGFloat {
        guard let w = (after ?? before)?.pixelWidth, w > 0, canvasFit.width > 0 else { return 2 }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return max(1, CGFloat(w) / scale / canvasFit.width)
    }

    private var zoomLabel: String {
        guard zoom > 1.001 else { return "Ajusté" }
        guard let w = (after ?? before)?.pixelWidth, w > 0, canvasFit.width > 0 else { return "×\(String(format: "%.1f", zoom))" }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return "\(Int((canvasFit.width * zoom * scale / CGFloat(w) * 100).rounded())) %"
    }

    private func setZoom(_ z: CGFloat) {
        let nz = min(64, max(1, z))
        withAnimation(.smooth(duration: 0.22)) {
            pan = nz <= 1.001 ? .zero : CGSize(width: pan.width * nz / zoom, height: pan.height * nz / zoom)
            zoom = nz
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        CompareCanvas(before: before?.image, after: after?.image, diff: diff, display: display,
                      split: $split, zoom: $zoom, pan: $pan, fit: $canvasFit,
                      pixelated: pixelated, smoothBefore: mode == .upscale,
                      afterLabel: isLive ? "Aperçu" : "Résultat")
            .overlay {
                if before == nil && originalURL != nil { ProgressView().controlSize(.large) }
                else if before?.image == nil && after?.image == nil && !rendering {
                    ContentUnavailableView("Aperçu visuel indisponible", systemImage: "eye.slash",
                                           description: Text(error ?? "Ce type de fichier ne peut pas être affiché."))
                }
            }
            .overlay(alignment: .bottom) {
                if display == .difference {
                    Text("Noir = identique · zones claires = détails modifiés par l'encodage (amplifiés ×8)")
                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule).padding(12)
                } else if zoom <= 1.001 && after != nil && before != nil && display == .split {
                    Text("Glissez pour comparer · pincez ou double-cliquez pour zoomer")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule).padding(12)
                }
            }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if isLive { liveControls } else if let item, item.status == .done {
                Label("Traité \(item.finishedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else if let e = historyEntry {
                Label("\(e.origin.label) · \(e.date.formatted(date: .abbreviated, time: .shortened))", systemImage: e.origin.symbol)
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer(minLength: 8)
            if let out = existingOutput, !isLive {
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
            if let e = historyEntry ?? currentHistoryEntry(), !e.isUndone, !isLive {
                Button {
                    HistoryModel.shared.undo([e])
                    historyEntry = nil
                    if item == nil { close() }
                } label: {
                    Label(item != nil ? "Annuler et ajuster" : "Restaurer l'original", systemImage: "arrow.uturn.backward")
                }
                .help(item != nil ? "Met le résultat à la Corbeille, restaure l'original si besoin et repasse en aperçu en direct"
                                  : "Met le résultat à la Corbeille et restaure l'original")
                .disabled(HistoryUndo.blocker(for: e) != nil)
            }
            Button("Fermer") { close() }.keyboardShortcut(.cancelAction)
            if isLive, let item {
                Button {
                    model.mode = mode
                    close()
                    if item.status != .pending { model.reset(item) }
                    model.start(mode: mode)
                } label: {
                    Label(model.pendingCount(for: mode) > 1 ? "\(mode.label) (\(model.pendingCount(for: mode)))" : mode.label, systemImage: mode.symbol)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)
                .help("Lance le traitement de la liste avec ces réglages")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var liveControls: some View {
        @Bindable var store = store
        HStack(spacing: 12) {
            if mode == .convert, let item {
                ConvertFormatButton(item: item)
                if kind != .video {
                    Toggle("Compresser", isOn: $store.prefs.processing.compressWhileConverting)
                        .toggleStyle(.switch).controlSize(.small)
                        .help("Applique le préréglage de compression pendant la conversion")
                }
            }
            if kind == .video, mode != .upscale {
                Picker("Vidéo", selection: $store.prefs.processing.video.preset) {
                    ForEach(VideoPreset.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            } else if mode == .compress || (mode == .convert && store.prefs.processing.compressWhileConverting) {
                Picker("Préréglage", selection: $store.prefs.processing.image.preset) {
                    ForEach(CompressionPreset.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 6) {
                    Text("Qualité").foregroundStyle(.secondary).fixedSize()
                    Slider(value: Binding(
                        get: { Double(store.prefs.processing.image.quality()) },
                        set: { v in
                            // NSSlider writes its value back on first layout: only react to a real change,
                            // otherwise merely opening the preview would switch the preset to "Personnalisé".
                            let q = Int(v.rounded())
                            guard q != store.prefs.processing.image.quality() else { return }
                            store.prefs.processing.image.customQuality = q
                            if store.prefs.processing.image.preset != .custom { store.prefs.processing.image.preset = .custom }
                        }), in: 10...100)
                    .frame(width: 150)
                    Text("\(store.prefs.processing.image.quality())").monospacedDigit().frame(width: 26, alignment: .trailing)
                }
                .font(.callout)
                .disabled(store.prefs.processing.image.targetFileSizeKB != nil)
                .help(store.prefs.processing.image.targetFileSizeKB != nil ? "Une taille de fichier cible est active (réglages)" : "")
            } else if mode == .upscale {
                Picker("Format", selection: $store.prefs.processing.upscaleTarget) {
                    ForEach(ProcessingSnapshot.upscaleChoices, id: \.self) { id in
                        Text(id == "SAME" ? "Format d'origine" : FormatCatalog.format(id)?.name ?? id).tag(id)
                    }
                }
                .fixedSize()
            }
            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Tous les réglages : redimensionnement, métadonnées… (l'aperçu se met à jour)")
                .popover(isPresented: $showSettings, arrowEdge: .top) { QuickSettings(mode: mode) }
        }
    }

    // MARK: Loading

    private func loadBefore() async {
        guard let url = originalURL else { before = nil; return }
        before = await PreviewRenderer.original(url, kind: kind)
    }

    private func renderAfter() async {
        error = nil
        if !isLive {
            rendering = false
            keepsOriginal = false
            elapsed = nil
            guard let out = existingOutput else {
                after = nil
                error = "Le résultat est introuvable (déplacé ou supprimé)."
                return
            }
            let name = historyEntry?.formatName
            after = await PreviewRenderer.existing(out, kind: FileDetection.classify(out).mediaKind ?? kind, formatName: name)
            if let item, item.note != nil, after?.note == nil { after?.note = item.note }
            afterVersion += 1
            return
        }
        guard let item else { return }
        // Debounce: sliders fire many changes per second.
        try? await Task.sleep(for: .milliseconds(after == nil ? 0 : 280))
        guard !Task.isCancelled else { return }
        rendering = true
        progress = 0
        let snapshot = store.prefs.processing
        let override = item.targetOverride.flatMap(FormatCatalog.format)
        let url = item.url, k = item.kind, m = mode
        let result = await Task.detached(priority: .userInitiated) {
            try await PreviewRenderer.render(input: url, kind: k, mode: m, snapshot: snapshot, targetOverride: override) { p in
                Task { @MainActor in progress = p }
            }
        }.resultCancellingOnParent()
        guard !Task.isCancelled else { return }
        rendering = false
        switch result {
        case .success(let o):
            after = o.after
            elapsed = o.elapsed
            keepsOriginal = o.keepsOriginal
            afterVersion += 1
        case .failure(let e):
            if e is CancellationError { return }
            error = e.localizedDescription
        }
    }

    private func computeDiff() async {
        guard display == .difference, let b = before?.image, let a = after?.image else { diff = nil; return }
        diff = await Task.detached(priority: .userInitiated) { PreviewRenderer.difference(before: b, after: a) }.value
    }

    private func currentHistoryEntry() -> HistoryEntry? {
        switch request.source {
        case .history(let e): HistoryModel.shared.entries.first { $0.id == e.id } ?? e
        case .item(let i, _): HistoryModel.shared.entry(i.historyID)
        }
    }

    static func describe(_ s: PreviewSide) -> String {
        var parts = [s.formatName, (s.estimated ? "≈ " : "") + s.bytes.formattedBytes]
        if let d = s.dimensions { parts.append(d) }
        return parts.joined(separator: " · ")
    }
}

extension Task where Failure == Error {
    /// Awaits a detached task, cancelling it when the awaiting (SwiftUI `.task`) is cancelled.
    func resultCancellingOnParent() async -> Result<Success, Error> {
        await withTaskCancellationHandler {
            await self.result
        } onCancel: {
            self.cancel()
        }
    }
}

extension AppModel {
    func pendingCount(for mode: ProcessMode) -> Int { items(for: mode).filter { $0.status == .pending || $0.status == .cancelled }.count }
}

// MARK: - Pieces

private struct SideInfo: View {
    let title: String
    let side: PreviewSide?
    let alignment: HorizontalAlignment
    var missing: String?
    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title).font(.headline)
            if let side {
                Text(PreviewView.describe(side)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(missing ?? "Chargement…").font(.caption).foregroundStyle(missing == nil ? .tertiary : .secondary)
            }
        }
    }
}

struct SavingsBadge: View {
    let savings: Double?
    var estimated = false
    var body: some View {
        if let s = savings, abs(s) >= 0.005 {
            Text((s > 0 ? "−" : "+") + "\(Int((abs(s) * 100).rounded())) %")
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background((s > 0 ? Color.green : Color.orange).opacity(0.16), in: .capsule)
                .foregroundStyle(s > 0 ? .green : .orange)
                .help(estimated ? "Estimation" : "Gain de poids")
        }
    }
}

/// Output format for this file in the preview (writes the per-file override, like the row's menu).
private struct ConvertFormatButton: View {
    @Environment(PreferencesStore.self) private var store
    let item: FileItem
    @State private var show = false
    var body: some View {
        let current = item.targetOverride.flatMap(FormatCatalog.format)
            ?? store.prefs.processing.target(for: item.url, kind: item.kind, mode: .convert)
        Button { show.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
                Text(current?.name ?? "Format").fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .help("Format de sortie de ce fichier")
        .popover(isPresented: $show, arrowEdge: .top) {
            FormatPicker(kind: item.kind, selection: Binding(
                get: { item.targetOverride ?? "" },
                set: { item.targetOverride = $0.isEmpty ? nil : $0; show = false }
            ), allowAuto: true)
        }
    }
}

// MARK: - Canvas

/// Draws the comparison. Both images are laid out in the same box, so zoom and pan stay aligned
/// (even when the result has another resolution, e.g. after ×2 upscaling or a resize).
struct CompareCanvas: View {
    let before: CGImage?
    let after: CGImage?
    let diff: CGImage?
    let display: CompareDisplay
    @Binding var split: CGFloat
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var fit: CGSize
    let pixelated: Bool
    let smoothBefore: Bool
    let afterLabel: String

    @State private var dragMode: DragMode?
    @State private var panStart: CGSize = .zero
    @State private var zoomStart: CGFloat?
    private enum DragMode { case split, pan }

    private var reference: CGImage? { after ?? before }

    var body: some View {
        GeometryReader { geo in
            let paneSize = display == .sideBySide ? CGSize(width: (geo.size.width - 1) / 2, height: geo.size.height) : geo.size
            let fitted = fitSize(reference, in: paneSize)
            ZStack {
                Color.black.opacity(0.88)
                switch display {
                case .split: splitView(size: geo.size, fitted: fitted)
                case .sideBySide:
                    HStack(spacing: 1) {
                        layer(before, box: fitted, container: paneSize, smooth: smoothBefore)
                            .overlay(alignment: .topLeading) { tag("Original") }
                        layer(after, box: fitted, container: paneSize, smooth: false)
                            .overlay(alignment: .topTrailing) { tag(afterLabel) }
                    }
                case .difference:
                    layer(diff, box: fitted, container: geo.size, smooth: false)
                        .overlay { if diff == nil && after != nil { ProgressView() } }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: geo.size, fitted: fitted, container: paneSize))
            .simultaneousGesture(magnify(fitted: fitted, container: paneSize))
            .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                toggleZoom(at: loc, size: display == .sideBySide ? paneSize : geo.size, fitted: fitted, full: geo.size)
            }
            .onAppear { fit = fitted }
            .onChange(of: fitted) { fit = fitted }
            .clipped()
        }
    }

    private func splitView(size: CGSize, fitted: CGSize) -> some View {
        let s = after == nil ? 1 : split
        return ZStack(alignment: .leading) {
            layer(after, box: fitted, container: size, smooth: false)
            layer(before, box: fitted, container: size, smooth: smoothBefore)
                .mask(alignment: .leading) { Rectangle().frame(width: size.width * s) }
            if after != nil && before != nil {
                Rectangle().fill(.white).frame(width: 2).shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: size.width * s - 1)
                Circle().fill(.white).frame(width: 30, height: 30).shadow(color: .black.opacity(0.35), radius: 4)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                    .offset(x: size.width * s - 15)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) { if before != nil { tag("Original") } }
        .overlay(alignment: .topTrailing) { if after != nil { tag(afterLabel) } }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .padding(10)
    }

    @ViewBuilder
    private func layer(_ image: CGImage?, box: CGSize, container: CGSize, smooth: Bool) -> some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(pixelated && !smooth ? .none : .high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: box.width * zoom, height: box.height * zoom)
                    .offset(pan)
            } else {
                Color.clear
            }
        }
        .frame(width: container.width, height: container.height)
        .clipped()
    }

    private func fitSize(_ image: CGImage?, in c: CGSize) -> CGSize {
        guard let image, image.width > 0, image.height > 0, c.width > 0, c.height > 0 else { return c }
        let a = CGFloat(image.width) / CGFloat(image.height)
        return c.width / c.height > a ? CGSize(width: c.height * a, height: c.height) : CGSize(width: c.width, height: c.width / a)
    }

    private func clampPan(_ p: CGSize, fitted: CGSize, container: CGSize, zoom z: CGFloat? = nil) -> CGSize {
        let z = z ?? zoom
        let mx = max(0, (fitted.width * z - container.width) / 2), my = max(0, (fitted.height * z - container.height) / 2)
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }

    private func dragGesture(size: CGSize, fitted: CGSize, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragMode == nil {
                    let nearHandle = abs(v.startLocation.x - size.width * split) < 22
                    dragMode = display == .split && (zoom <= 1.001 || nearHandle) ? .split : .pan
                    panStart = pan
                }
                switch dragMode {
                case .split: split = min(1, max(0, v.location.x / max(1, size.width)))
                case .pan:
                    pan = clampPan(CGSize(width: panStart.width + v.translation.width, height: panStart.height + v.translation.height),
                                   fitted: fitted, container: container)
                case nil: break
                }
            }
            .onEnded { _ in dragMode = nil }
    }

    private func magnify(fitted: CGSize, container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if zoomStart == nil { zoomStart = zoom }
                let nz = min(64, max(1, (zoomStart ?? 1) * v.magnification))
                pan = clampPan(CGSize(width: pan.width * nz / zoom, height: pan.height * nz / zoom), fitted: fitted, container: container, zoom: nz)
                zoom = nz
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// Double-click: fit ↔ real pixels, centred on the clicked point.
    private func toggleZoom(at loc: CGPoint, size: CGSize, fitted: CGSize, full: CGSize) {
        var local = loc
        if display == .sideBySide, loc.x > size.width { local.x -= size.width + 1 }
        let target: CGFloat
        if zoom > 1.001 { target = 1 } else {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let px = CGFloat(reference?.width ?? 0) / scale
            target = max(2, fitted.width > 0 ? px / fitted.width : 2)
        }
        let f = target / zoom
        let p = CGSize(width: local.x - size.width / 2, height: local.y - size.height / 2)
        withAnimation(.smooth(duration: 0.25)) {
            pan = target <= 1.001 ? .zero
                : clampPan(CGSize(width: pan.width * f - p.width * (f - 1), height: pan.height * f - p.height * (f - 1)),
                           fitted: fitted, container: size, zoom: target)
            zoom = target
        }
    }
}
