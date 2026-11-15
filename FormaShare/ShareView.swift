import SwiftUI
import QuickLookThumbnailing

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView("Rien à convertir", systemImage: "questionmark.folder",
                                       description: Text("Forma accepte les images, vidéos, fichiers audio, PDF et documents."))
            } else {
                modePicker
                if model.recipe == nil { options }
                recipes
                destination
                Spacer(minLength: 0)
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
                footer
            }
        }
        .padding(18)
        .frame(width: 400, height: 460)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ThumbStack(items: Array(model.items.prefix(3)))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.items.count == 1 ? model.items[0].name : "\(model.items.count) éléments")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        var parts = model.kinds.map(\.label)
        if model.totalSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Options

    private var modePicker: some View {
        Picker("", selection: $model.mode) {
            Text("Convertir").tag(ProcessMode.convert)
            Text("Compresser").tag(ProcessMode.compress)
            if model.kinds == [.image] { Text("Agrandir ×2").tag(ProcessMode.upscale) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(model.recipe != nil)
        .onChange(of: model.mode) { model.recipe = nil }
    }

    @ViewBuilder
    private var options: some View {
        switch model.mode {
        case .convert:
            let choices = model.formatChoices
            if choices.isEmpty {
                Label("Chaque type est converti avec son format par défaut.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chips(title: "Format", items: choices.map { ($0.id, $0.name) }, selection: $model.target)
            }
        case .compress:
            if model.kinds.contains(.image) {
                Chips(title: "Préréglage", items: CompressionPreset.allCases.filter { $0 != .custom }.map { ($0.rawValue, $0.label) },
                      selection: Binding<String?>(get: { (model.preset ?? model.config.compressPreset).rawValue },
                                         set: { model.preset = $0.flatMap(CompressionPreset.init(rawValue:)) }))
            }
        case .upscale:
            Label("Super-résolution sur le Neural Engine, format d'origine conservé.", systemImage: "sparkles")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recipes: some View {
        if !model.recipes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recettes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(model.recipes) { r in
                        let on = model.recipe == r.id
                        Button { model.recipe = on ? nil : r.id } label: {
                            Label(r.name, systemImage: r.symbol).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                                .foregroundStyle(on ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var destination: some View {
        Picker("Résultat", selection: $model.destination) {
            if model.allFiles { Text("À côté de l'original").tag(0) }
            Text("Dossier des partages (\(sharesName))").tag(1)
            Text("Presse-papiers").tag(2)
        }
    }

    private var sharesName: String {
        model.config.sharesFolder.map { ($0 as NSString).lastPathComponent } ?? "Téléchargements"
    }

    private var footer: some View {
        HStack {
            Text("Forma travaille en arrière-plan.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Annuler") { model.cancel() }.keyboardShortcut(.cancelAction)
            Button(actionTitle) { model.send() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.sending || (model.mode == .convert && model.recipe == nil && model.formatChoices.count > 0 && model.target == nil))
        }
    }

    private var actionTitle: String {
        if model.recipe != nil { return "Appliquer" }
        return model.mode == .convert ? "Convertir" : model.mode == .compress ? "Compresser" : "Agrandir"
    }
}

/// Selectable capsules in a wrapping row.
private struct Chips: View {
    let title: String
    let items: [(String, String)]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            WrapLayout(spacing: 6) {
                ForEach(items, id: \.0) { id, name in
                    let on = selection == id
                    Button { selection = id } label: {
                        Text(name).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ThumbStack: View {
    let items: [SharedItem]
    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.element.id) { i, item in
                Thumb(item: item)
                    .rotationEffect(.degrees(Double(i) * 5))
                    .offset(x: CGFloat(i) * 3)
            }
        }
        .frame(width: 52, height: 52)
    }
}

private struct Thumb: View {
    let item: SharedItem
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: item.kind?.symbol ?? "doc").font(.title2).foregroundStyle(.secondary) }
        }
        .frame(width: 46, height: 46)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .task {
            guard let url = item.fileURL else { return }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 92, height: 92), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}
