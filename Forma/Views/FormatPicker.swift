import SwiftUI
import AppKit
import ImageIO

struct FormatPicker: View {
    let kind: MediaKind
    @Binding var selection: String
    var allowAuto = false
    @State private var query = ""
    @FocusState private var focused: Bool

    private var formats: [FormatDescriptor] {
        let list = FormatCatalog.outputs(for: kind)
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.name.lowercased().contains(q) || $0.ext.contains(q) || $0.detail.lowercased().contains(q) || $0.group.lowercased().contains(q) }
    }

    private var groups: [(String, [FormatDescriptor])] {
        var order: [String] = []
        var map: [String: [FormatDescriptor]] = [:]
        for f in formats {
            let g = kind == .video && f.kind == .audio ? "Extraire l'audio"
                : kind == .document && f.kind == .office ? "Extraire le texte" : f.group
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(f)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Rechercher un format", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let f = formats.first { selection = f.id } }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if allowAuto && query.isEmpty {
                        chip(id: "", name: "Auto", detail: "Réglage général")
                            .padding(.horizontal, 12)
                    }
                    ForEach(groups, id: \.0) { group, items in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], spacing: 6) {
                                ForEach(items) { f in chip(id: f.id, name: f.name, detail: f.detail) }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                    if formats.isEmpty {
                        Text("Aucun format trouvé").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 440, height: 460)
        .onAppear { focused = true }
    }

    private func chip(id: String, name: String, detail: String) -> some View {
        let selected = selection == id
        return Button { selection = id } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.45)), in: .rect(cornerRadius: 8))
            .foregroundStyle(selected ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detail)
    }
}

// MARK: - Metadata

struct MetadataView: View {
    let url: URL
    @State private var rows: [(String, [(String, String)])] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(url.lastPathComponent).font(.headline).lineLimit(2)
                if rows.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(rows, id: \.0) { section, items in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                            ForEach(items.indices, id: \.self) { i in
                                GridRow {
                                    Text(items[i].0).foregroundStyle(.secondary)
                                    Text(items[i].1).textSelection(.enabled).lineLimit(3)
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 420, height: 480)
        .task { rows = await Self.read(url) }
    }

    static func read(_ url: URL) async -> [(String, [(String, String)])] {
        var out: [(String, [(String, String)])] = []
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        var file: [(String, String)] = [("Taille", url.fileSize.formattedBytes), ("Type", FileDetection.classify(url).mediaKind?.label ?? "—")]
        if let d = attrs?[.creationDate] as? Date { file.append(("Créé", d.formatted())) }
        if let d = attrs?[.modificationDate] as? Date { file.append(("Modifié", d.formatted())) }
        out.append(("Fichier", file))

        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            var general: [(String, String)] = []
            for (k, v) in p.sorted(by: { $0.key < $1.key }) where !(v is [String: Any]) { general.append((k, "\(v)")) }
            out.append(("Image", general))
            for (k, v) in p.sorted(by: { $0.key < $1.key }) {
                guard let dict = v as? [String: Any] else { continue }
                let rows = dict.sorted { $0.key < $1.key }.map { ($0.key, Self.describe($0.value)) }
                if !rows.isEmpty { out.append((k.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""), rows)) }
            }
        } else {
            let p = await MediaEngine.probe(url)
            var media: [(String, String)] = []
            if p.duration > 0 { media.append(("Durée", Duration.seconds(p.duration).formatted(.time(pattern: .hourMinuteSecond)))) }
            if let v = p.videoCodec { media.append(("Vidéo", "\(v) · \(p.width)×\(p.height) · \(String(format: "%.2f", p.fps)) i/s")) }
            if let a = p.audioCodec { media.append(("Audio", "\(a) · \(p.audioChannels) can. · \(p.sampleRate) Hz")) }
            if p.bitrate > 0 { media.append(("Débit", "\(p.bitrate / 1000) kb/s")) }
            media.append(("Pochette", p.hasCoverArt ? "Oui" : "Non"))
            out.append(("Média", media))
            if !p.tags.isEmpty { out.append(("Tags", p.tags.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })) }
        }
        return out
    }

    static func describe(_ v: Any) -> String {
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
        return "\(v)"
    }
}

@MainActor
enum MetadataWindow {
    static func show(_ url: URL) {
        let host = NSHostingController(rootView: MetadataView(url: url))
        let w = NSWindow(contentViewController: host)
        w.title = "Infos — \(url.lastPathComponent)"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
