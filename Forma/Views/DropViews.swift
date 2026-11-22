import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

/// Main-actor view of the Drop log (what Forma sent, when, and whether the link is still alive).
@MainActor
@Observable
final class DropModel {
    static let shared = DropModel()

    private(set) var records: [DropRecord] = []
    private(set) var syncing = false
    var error: String?
    private var observers: [NSObjectProtocol] = []
    private var reloadWork: DispatchWorkItem?

    private init() {
        let handler: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { DropModel.shared.scheduleReload() } }
        observers.append(NotificationCenter.default.addObserver(forName: .formaHistoryChanged, object: nil, queue: .main, using: handler))
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .formaHistoryChanged, object: nil, queue: .main, using: handler))
        reload()
    }

    func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { DropModel.shared.reload() } }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    func reload() {
        Task.detached(priority: .userInitiated) {
            let list = HistoryStore.shared.fetchDrops(limit: 2000, includeDeleted: true)
            await MainActor.run { DropModel.shared.records = list }
        }
    }

    var live: [DropRecord] { records.filter(\.isLive) }
    var isConfigured: Bool { DropServer.isConfigured(PreferencesStore.shared.prefs.drop) }

    /// Compares the log with the server: links deleted from the dashboard (or expired) are marked, new expiries copied.
    func sync() async {
        let prefs = PreferencesStore.shared.prefs.drop
        guard let server = try? DropServer.current(prefs) else { return }
        syncing = true
        defer { syncing = false }
        do {
            let remote = Dictionary(uniqueKeysWithValues: try await DropClient.shared.list(server: server).map { ($0.key, $0) })
            let server = server.host
            var gone: [String] = []
            for r in records where r.isLive && r.server == server {
                if let f = remote[r.key] {
                    if f.expiry?.timeIntervalSince1970.rounded() != r.expiresAt?.timeIntervalSince1970.rounded() {
                        HistoryStore.shared.updateDropExpiry(key: r.key, to: f.expiry)
                    }
                } else { gone.append(r.key) }
            }
            if !gone.isEmpty { HistoryStore.shared.markDropsDeleted(gone) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ list: [DropRecord]) async {
        let failed = await DropUploader.delete(list.filter { !$0.isDeleted }, prefs: PreferencesStore.shared.prefs.drop)
        if failed.isEmpty { Toast.show(list.count > 1 ? "\(list.count) fichiers supprimés de Drop" : "Supprimé de Drop", symbol: "trash") }
        else { error = "\(failed.count) fichier\(failed.count > 1 ? "s" : "") n'ont pas pu être supprimés." }
    }

    func setExpiry(_ record: DropRecord, to expiry: DropExpiry) async {
        guard let server = try? DropServer.current(PreferencesStore.shared.prefs.drop) else { return }
        let date = expiry.seconds.map { Date().addingTimeInterval(Double($0)) }
        do {
            try await DropClient.shared.setExpiry(key: record.key, to: date, server: server)
            HistoryStore.shared.updateDropExpiry(key: record.key, to: date)
            Toast.show(expiry == .never ? "Le lien n'expire plus" : "Le lien expirera dans \(expiry.label)", symbol: "timer")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Window

struct DropWindowView: View {
    @Environment(PreferencesStore.self) private var store
    @State private var model = DropModel.shared
    @State private var search = ""
    @State private var showDeleted = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false

    private var filtered: [DropRecord] {
        let q = search.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return model.records.filter { r in
            if !showDeleted, !r.isLive { return false }
            guard !q.isEmpty else { return true }
            return (r.name + " " + r.url).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
    }

    private var selected: [DropRecord] { model.records.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.isConfigured {
                ContentUnavailableView {
                    Label("Drop n'est pas configuré", systemImage: "icloud.slash")
                } description: {
                    Text("Entrez l'adresse de votre serveur et son mot de passe dans les réglages.")
                } actions: {
                    Button("Ouvrir les réglages Drop") { SettingsNavigation.shared.tab = .drop; AppDelegate.showSettings() }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Aucun envoi" : "Aucun résultat", systemImage: "arrow.up.circle",
                                       description: Text(search.isEmpty ? "Faites un clic droit sur un fichier dans le Finder › Forma › Envoyer sur Drop, ou glissez-le sur l'icône de la barre des menus." : ""))
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { r in
                        DropRow(record: r)
                            .tag(r.id)
                            .contextMenu { actions(for: contextTargets(r)) }
                    }
                }
                .listStyle(.inset)
            }
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .task { await model.sync() }
        .confirmationDialog("Supprimer \(selected.count) fichier\(selected.count > 1 ? "s" : "") de Drop ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { let list = selected; Task { await model.delete(list); selection = [] } }
        } message: {
            Text("Les liens cesseront de fonctionner. Les fichiers locaux ne sont pas touchés.")
        }
    }

    private func contextTargets(_ r: DropRecord) -> [DropRecord] { selection.contains(r.id) ? selected : [r] }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Drop").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Rechercher", text: $search).textFieldStyle(.roundedBorder).frame(width: 170)
            Toggle("Supprimés", isOn: $showDeleted).toggleStyle(.checkbox).help("Afficher aussi les liens supprimés ou expirés")
            Button { Task { await model.sync() } } label: {
                if model.syncing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Vérifier l'état des liens sur le serveur")
            .disabled(!model.isConfigured)
            Button { openDashboard() } label: { Image(systemName: "safari") }
                .help("Ouvrir le tableau de bord Drop").disabled(!model.isConfigured)
        }
        .padding(12)
    }

    private var summary: String {
        let live = model.live
        guard !live.isEmpty else { return DropServer.host(of: store.prefs.drop) ?? "Non configuré" }
        let bytes = live.reduce(Int64(0)) { $0 + $1.size }
        return "\(live.count) lien\(live.count > 1 ? "s" : "") actif\(live.count > 1 ? "s" : "") · \(bytes.formattedBytes) · \(DropServer.host(of: store.prefs.drop) ?? "")"
    }

    private func openDashboard() {
        if let url = DropServer.normalize(store.prefs.drop.baseURL) { NSWorkspace.shared.open(url) }
    }

    @ViewBuilder
    private func actions(for list: [DropRecord]) -> some View {
        let live = list.filter(\.isLive)
        if !live.isEmpty {
            Button("Copier le lien", systemImage: "doc.on.doc") { DropUploader.copy(live.map(\.url)) }
            if live.count == 1, let r = live.first {
                Button("Ouvrir dans le navigateur", systemImage: "arrow.up.right.square") { if let u = URL(string: r.url) { NSWorkspace.shared.open(u) } }
                Button("Copier le lien direct", systemImage: "link") { DropUploader.copy([directURL(r)]) }
                Menu("Expiration", systemImage: "timer") {
                    ForEach(DropExpiry.allCases) { e in Button(e == .never ? "Ne jamais expirer" : "Dans \(e.label)") { Task { await model.setExpiry(r, to: e) } } }
                }
            }
        }
        if let src = list.first?.source, FileManager.default.fileExists(atPath: src) {
            Button("Afficher l'original", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting(list.compactMap { $0.source.map { URL(fileURLWithPath: $0) } }) }
        }
        if !live.isEmpty {
            Divider()
            Button("Supprimer de Drop…", systemImage: "trash", role: .destructive) { selection = Set(live.map(\.id)); confirmDelete = true }
        }
    }

    private func directURL(_ r: DropRecord) -> String {
        r.url.hasSuffix("?raw") ? r.url : r.url + "?raw"
    }
}

private struct DropRow: View {
    let record: DropRecord
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (record.name as NSString).pathExtension) ?? .data))
                .resizable().frame(width: 30, height: 30).opacity(record.isLive ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(!record.isLive)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if record.isLive {
                Button {
                    DropUploader.copy([record.url]); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: { Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Text(record.isDeleted ? "Supprimé" : "Expiré").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        var parts = [record.date.formatted(.relative(presentation: .named)), record.size.formattedBytes]
        if record.isLive, let e = record.expiresAt { parts.append("expire \(e.formatted(.relative(presentation: .named)))") }
        parts.append(record.origin.label)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Settings

struct DropSettingsView: View {
    @Environment(PreferencesStore.self) private var store
    @State private var model = DropModel.shared
    @State private var password = ""
    @State private var testing = false
    @State private var outcome: Outcome?
    @State private var hasPassword = false

    enum Outcome { case ok(Int), failure(String) }

    private var host: String? { DropServer.host(of: store.prefs.drop) }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                TextField("Adresse", text: $store.prefs.drop.baseURL, prompt: Text("https://drop.example.com"))
                    .textContentType(.URL).autocorrectionDisabled()
                    .onSubmit { refreshPasswordState() }
                SecureField("Mot de passe", text: $password,
                            prompt: Text(hasPassword ? "Enregistré dans le trousseau — laissez vide pour le garder" : "Mot de passe du tableau de bord"))
                    .onSubmit { Task { await saveAndTest() } }
                HStack {
                    Button { Task { await saveAndTest() } } label: {
                        if testing { ProgressView().controlSize(.small) } else { Text(password.isEmpty && hasPassword ? "Tester la connexion" : "Enregistrer et tester") }
                    }
                    .disabled(testing || host == nil || (password.isEmpty && !hasPassword))
                    .keyboardShortcut(.defaultAction)
                    if hasPassword {
                        Button("Oublier le mot de passe", role: .destructive) { forget() }
                    }
                    Spacer()
                    status
                }
            } header: {
                Text("Serveur")
            } footer: {
                Text("Le mot de passe est le même que celui du tableau de bord. Il reste dans le trousseau de macOS : jamais dans les réglages ni dans les fichiers de Forma.")
            }

            Section("Envois") {
                Picker("Expiration par défaut", selection: $store.prefs.drop.expiry) {
                    ForEach(DropExpiry.allCases) { Text($0.label).tag($0) }
                }
                Picker("Lien copié", selection: $store.prefs.drop.linkStyle) {
                    ForEach(DropLinkStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Copier le lien dans le presse-papiers", isOn: $store.prefs.drop.copyLink)
                Toggle("Ouvrir le lien dans le navigateur (un seul fichier)", isOn: $store.prefs.drop.openLink)
            }

            Section {
                Toggle("Menu Finder › Forma › Envoyer sur Drop", isOn: $store.prefs.drop.showInFinder)
                Toggle("Panneau Partager › Forma", isOn: $store.prefs.drop.showInShare)
                Toggle("Fenêtre de Forma : envoyer chaque résultat sur Drop", isOn: $store.prefs.drop.afterProcessing)
            } header: {
                Text("Intégration")
            } footer: {
                Text("Chaque recette peut aussi envoyer ses résultats sur Drop (Réglages › Finder › Recettes). Dans le Terminal : forma drop <fichiers>, ou --drop sur convert, compress et upscale. Un dossier est envoyé en .zip.")
            }

            Section("Derniers envois") {
                let recent = Array(model.live.prefix(5))
                if recent.isEmpty {
                    Text("Rien d'envoyé pour l'instant.").foregroundStyle(.secondary)
                } else {
                    ForEach(recent) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).lineLimit(1).truncationMode(.middle)
                                Text("\(r.date.formatted(.relative(presentation: .named))) · \(r.size.formattedBytes)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { DropUploader.copy([r.url]) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copier le lien")
                        }
                    }
                }
                Button("Tous les envois…") { AppDelegate.showDrop() }.disabled(!model.isConfigured)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPasswordState() }
        .onChange(of: store.prefs.drop.baseURL) { outcome = nil; refreshPasswordState() }
    }

    @ViewBuilder private var status: some View {
        switch outcome {
        case .ok(let n):
            Label("Connecté · \(n) fichier\(n > 1 ? "s" : "") sur le serveur", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        case nil:
            if hasPassword { Label("Mot de passe enregistré", systemImage: "key.fill").foregroundStyle(.secondary) }
        }
    }

    private func refreshPasswordState() {
        hasPassword = host.map(DropKeychain.hasPassword(for:)) ?? false
        MenuConfigPublisher.shared.setNeedsPublish()
    }

    private func saveAndTest() async {
        guard let base = DropServer.normalize(store.prefs.drop.baseURL), let host = base.host() else { return }
        if store.prefs.drop.baseURL != base.absoluteString { store.prefs.drop.baseURL = base.absoluteString }
        testing = true
        defer { testing = false }
        do {
            if !password.isEmpty { try DropKeychain.save(password, for: host); password = "" }
            hasPassword = true
            let server = try DropServer.current(store.prefs.drop)
            let count = try await DropClient.shared.verify(server)
            outcome = .ok(count)
            await model.sync()
        } catch let e as DropError {
            if case .wrongPassword = e { DropKeychain.delete(for: host); hasPassword = false }
            outcome = .failure(e.localizedDescription)
        } catch {
            outcome = .failure(error.localizedDescription)
        }
        MenuConfigPublisher.shared.setNeedsPublish()
    }

    private func forget() {
        if let host { DropKeychain.delete(for: host) }
        hasPassword = false
        outcome = nil
        MenuConfigPublisher.shared.setNeedsPublish()
    }
}
