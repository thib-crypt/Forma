import SwiftUI
import AppKit

struct FileListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                FileRow(item: item)
                    .tag(item.id)
                    .listRowSeparator(.hidden)
                    .contextMenu { FileContextMenu(item: item) }
            }
            .onDelete { idx in model.remove(Set(idx.map { model.items[$0].id })) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDeleteCommand { model.remove(model.selection) }
        .onKeyPress(.space) {
            guard let item = model.items.first(where: { model.selection.contains($0.id) }) else { return .ignored }
            PreviewWindow.open(item, mode: model.mode)
            return .handled
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            if !ids.isEmpty {
                Button("Retirer de la liste") { model.remove(ids) }
            }
        } primaryAction: { ids in
            guard let id = ids.first, let item = model.items.first(where: { $0.id == id }) else { return }
            if let out = item.outputs.first { NSWorkspace.shared.open(out) } else { NSWorkspace.shared.open(item.url) }
        }
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PreferencesStore.self) private var store
    let item: FileItem
    @State private var hovering = false

    private var target: FormatDescriptor? {
        if let o = item.targetOverride { return FormatCatalog.format(o) }
        return store.prefs.processing.target(for: item.url, kind: item.kind, mode: model.mode)
    }

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(image: item.thumbnail, kind: item.kind)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(item.inputExt) · \(item.size.formattedBytes)")
                    if let target {
                        Image(systemName: "arrow.right").font(.caption2)
                        if item.status == .done, item.outputSize > 0 {
                            Text("\(target.name) · \(item.outputSize.formattedBytes)").foregroundStyle(.primary)
                        } else {
                            Text(target.name)
                        }
                    }
                    if let note = item.note { Text("· \(note)").foregroundStyle(.secondary) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if case .failed(let msg) = item.status {
                    Text(msg).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)

            if hovering, PreviewRenderer.canPreview(item.kind), !item.status.isProcessing {
                Button { PreviewWindow.open(item, mode: model.mode) } label: {
                    Image(systemName: "eye").padding(4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(item.status == .done ? "Comparer avant / après (Espace)" : "Aperçu avec les réglages actuels (Espace)")
                .transition(.opacity)
            }
            if model.mode == .convert, item.status == .pending || item.status == .cancelled {
                FormatOverrideMenu(item: item)
            }
            StatusView(item: item)
                .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        // Double-click is the List's primaryAction (opens the result): a tap gesture here delayed every selection click.
    }
}

struct Thumbnail: View {
    let image: NSImage?
    let kind: MediaKind
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind.symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct StatusView: View {
    let item: FileItem
    var body: some View {
        switch item.status {
        case .pending:
            Text("En attente").font(.caption).foregroundStyle(.tertiary)
        case .processing(let p):
            HStack(spacing: 8) {
                Text("\(Int(p * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
            }
        case .done:
            HStack(spacing: 6) {
                if let r = item.resolutionBadge {
                    Label(r, systemImage: item.note == nil ? "sparkles" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: .capsule)
                        .foregroundStyle(.tint)
                        .help(item.note ?? "Agrandi ×2 par super-résolution IA")
                } else if let s = item.savings, abs(s) >= 0.005 {
                    Text(s > 0 ? "−\(Int((s * 100).rounded())) %" : "+\(Int((-s * 100).rounded())) %")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((s > 0 ? Color.green : Color.orange).opacity(0.16), in: .capsule)
                        .foregroundStyle(s > 0 ? .green : .orange)
                }
                if item.isSendingToDrop {
                    ProgressView().controlSize(.small).help("Envoi sur Drop…")
                } else if let link = item.dropLinks.first {
                    Button { DropUploader.copy(item.dropLinks) } label: { Image(systemName: "link.circle.fill").foregroundStyle(.tint) }
                        .buttonStyle(.plain).help("Lien Drop : \(link)\nClic pour copier")
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .transition(.scale.combined(with: .opacity))
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(msg)
        case .skipped(let msg):
            Label(msg, systemImage: "forward.fill").font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text("Annulé").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FormatOverrideMenu: View {
    @Environment(PreferencesStore.self) private var store
    let item: FileItem
    @State private var show = false
    var body: some View {
        Button {
            show = true
        } label: {
            HStack(spacing: 3) {
                Text(item.targetOverride.flatMap(FormatCatalog.format)?.name ?? "Auto")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Format de sortie pour ce fichier uniquement")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            FormatPicker(kind: item.kind, selection: Binding(
                get: { item.targetOverride ?? "" },
                set: { item.targetOverride = $0.isEmpty ? nil : $0; show = false }
            ), allowAuto: true)
        }
    }
}

struct FileContextMenu: View {
    @Environment(AppModel.self) private var model
    let item: FileItem

    @ViewBuilder
    private func dropButtons(for urls: [URL]) -> some View {
        if DropServer.isConfigured(PreferencesStore.shared.prefs.drop), !item.isSendingToDrop {
            if let link = item.dropLinks.first {
                Button("Copier le lien Drop") { DropUploader.copy(item.dropLinks); Toast.show("Lien Drop copié", symbol: "link") }
                Button("Ouvrir le lien Drop") { if let u = URL(string: link) { NSWorkspace.shared.open(u) } }
            } else {
                Button("Envoyer sur Drop") { Task { await model.sendToDrop(item, urls: urls, copyWhenDone: true) } }
            }
        }
    }

    var body: some View {
        if let out = item.outputs.first {
            Button("Afficher le résultat dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) }
            Button("Ouvrir le résultat") { NSWorkspace.shared.open(out) }
            if PreviewRenderer.canPreview(item.kind) {
                Button("Comparer avant / après") { PreviewWindow.open(item, mode: model.mode) }
            }
            if let e = HistoryModel.shared.entry(item.historyID), !e.isUndone {
                Button("Annuler ce traitement") { Toast.show(HistoryModel.shared.undo([e]), symbol: "arrow.uturn.backward") }
                    .disabled(HistoryUndo.blocker(for: e) != nil)
            }
            Button("Copier le résultat") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(item.outputs as [NSURL])
            }
            dropButtons(for: item.outputs)
            Divider()
        }
        if item.outputs.isEmpty, PreviewRenderer.canPreview(item.kind), !item.status.isProcessing {
            Button("Aperçu avec les réglages actuels") { PreviewWindow.open(item, mode: model.mode) }
            Divider()
        }
        if item.outputs.isEmpty { dropButtons(for: [item.url]) }
        Button("Afficher l'original dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Infos & métadonnées") { MetadataWindow.show(item.url) }
        Divider()
        if item.status.isFinished {
            Button("Retraiter") { model.reset(item) }
        }
        Button("Retirer de la liste", role: .destructive) { model.remove([item.id]) }
    }
}
