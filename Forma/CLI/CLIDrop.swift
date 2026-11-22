import Foundation
import AppKit

/// `forma drop …` — send files to Drop (the self-hosted share service) and manage the links.
extension CLI {

    static let dropUsage = """
    forma drop <fichiers|dossiers…> [options]   envoie sur Drop et affiche le lien (un dossier part en .zip)
          --expiry <1h|1d|7d|30d|never>   durée de vie du lien (par défaut : Réglages › Drop)
          --direct                        lien direct vers le fichier (…?raw)
          --name <nom>                    nom du fichier sur Drop (un seul fichier)
          --no-copy                       ne pas copier le lien dans le presse-papiers
          --open                          ouvre le lien dans le navigateur
          --quiet                         n'affiche que les liens
          --json                          résultat en JSON
    forma drop - [--name <nom>]           envoie l'entrée standard (ex. : pbpaste | forma drop - --name notes.txt)
    forma drop login [--password-stdin]   enregistre le mot de passe dans le trousseau et teste la connexion
    forma drop logout | status            oublie le mot de passe | état de la connexion
    forma drop list [-n 20] [--all] [--remote] [--json]   derniers envois (--remote : tout le serveur)
    forma drop rm <lien|clé>…             supprime de Drop
    forma drop expire <lien|clé> <1h|1d|7d|30d|never>   change la durée de vie

    """

    static func drop(_ args: [String]) -> Int32 {
        guard let first = args.first else { fputs(dropUsage, stderr); return 2 }
        let rest = Array(args.dropFirst())
        switch first {
        case "login": return dropLogin(rest)
        case "logout": return dropLogout()
        case "status": return dropStatus()
        case "list", "ls": return dropList(rest)
        case "rm", "delete", "remove": return dropRemove(rest)
        case "expire": return dropExpire(rest)
        case "help", "--help", "-h": print(dropUsage); return 0
        default: return dropUpload(args)
        }
    }

    // MARK: Helpers

    private static func dropPrefs() -> DropPreferences { PreferencesStore.loadSnapshot().drop }

    private static func dropServer() -> DropServer? {
        do { return try DropServer.current(dropPrefs()) }
        catch { fputs("✗ \(error.localizedDescription)\n", stderr); return nil }
    }

    /// Runs an async operation to completion from the (blocking) CLI.
    static func wait<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: T?
        Task.detached { out = await op(); sem.signal() }
        sem.wait()
        return out!
    }

    private static func iso(_ d: Date?) -> Any { d.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }

    /// Wakes Forma so it re-publishes the Finder menu (the Drop entries appear once a password is stored).
    private static func refreshApp() {
        var r = ExternalRequest(source: .cli, action: .refresh)
        r.paths = []
        try? GroupContainer.submit(r)
        // Let Launch Services deliver the wake-up URL before this process exits.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    // MARK: Upload

    private static func dropUpload(_ args: [String]) -> Int32 {
        var prefs = dropPrefs()
        var options = DropOptions()
        var files: [URL] = []
        var fromStdin = false
        var name: String?
        var json = false, quiet = false, copy = true, open = false
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--expiry", "-e":
                guard let v = it.next(), let e = DropExpiry.parse(v) else { fputs("Durée inconnue. Exemples : 1h, 1d, 7d, 30d, never.\n", stderr); return 2 }
                options.expiry = e
            case "--direct": prefs.linkStyle = .direct
            case "--name", "-n": name = it.next()
            case "--no-copy": copy = false
            case "--open": open = true
            case "--quiet", "-q": quiet = true
            case "--json": json = true; quiet = true
            case "-": fromStdin = true
            default:
                if a.hasPrefix("-") { fputs("Option inconnue : \(a)\n\(dropUsage)", stderr); return 2 }
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
            }
        }
        if fromStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty else { fputs("L'entrée standard est vide.\n", stderr); return 1 }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-Stdin-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name ?? "stdin.txt")
            do { try data.write(to: file) } catch { fputs("✗ \(error.localizedDescription)\n", stderr); return 1 }
            files.append(file)
        }
        guard !files.isEmpty else { fputs(dropUsage, stderr); return 2 }
        guard (try? DropServer.current(prefs)) != nil else { fputs("✗ \(DropError.notConfigured.localizedDescription)\n", stderr); return 1 }
        let missing = files.filter { !FileManager.default.fileExists(atPath: $0.path) }
        for m in missing { fputs("✗ \(m.lastPathComponent) : fichier introuvable\n", stderr) }
        files.removeAll { missing.contains($0) }
        guard !files.isEmpty else { return 1 }

        let batch = UUID(), settings = prefs, opts = options, targets = files, show = !quiet
        let results: [(URL, Result<DropUpload, Error>)] = wait {
            await withTaskGroup(of: (Int, URL, Result<DropUpload, Error>).self) { group in
                var out: [(Int, URL, Result<DropUpload, Error>)] = []
                var iterator = targets.enumerated().makeIterator()
                func add() {
                    guard let (i, u) = iterator.next() else { return }
                    group.addTask {
                        let meter = ProgressLine(label: u.lastPathComponent, enabled: show && isatty(2) != 0)
                        do {
                            let upload = try await DropUploader.upload(u, name: targets.count == 1 ? name : nil, options: opts, prefs: settings,
                                                                       origin: .cli, batch: batch) { meter.update($0) }
                            meter.finish()
                            return (i, u, .success(upload))
                        } catch {
                            meter.finish()
                            return (i, u, .failure(error))
                        }
                    }
                }
                for _ in 0..<2 { add() }
                while let r = await group.next() { out.append(r); add() }
                return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
            }
        }

        var links: [String] = []
        var failures: Int32 = 0
        var report: [[String: Any]] = []
        for (u, r) in results {
            switch r {
            case .success(let up):
                links.append(up.url)
                if json {
                    report.append(["input": u.path, "status": "uploaded", "key": up.key, "url": up.url, "size": up.size, "expiresAt": iso(up.expiresAt)])
                } else if quiet {
                    print(up.url)
                } else {
                    print("✓ \(u.lastPathComponent) · \(up.size.formattedBytes) → \(up.url)\(up.expiresAt.map { " (expire \($0.formatted(.relative(presentation: .named))))" } ?? "")")
                }
            case .failure(let e):
                failures += 1
                if json { report.append(["input": u.path, "status": "error", "error": e.localizedDescription]) }
                else { fputs("✗ \(u.lastPathComponent) : \(e.localizedDescription)\n", stderr) }
            }
        }
        if json { printJSON(report) }
        if copy, !links.isEmpty, (options.copyLink ?? prefs.copyLink) {
            MainActor.assumeIsolated { DropUploader.copy(links) }
            if !quiet { print(links.count == 1 ? "Lien copié dans le presse-papiers." : "\(links.count) liens copiés dans le presse-papiers.") }
        }
        if open, links.count == 1, let u = URL(string: links[0]) { NSWorkspace.shared.open(u) }
        return failures == 0 ? 0 : 1
    }

    // MARK: Account

    private static func dropLogin(_ args: [String]) -> Int32 {
        let prefs = dropPrefs()
        var url = prefs.baseURL
        var fromStdin = false
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--password-stdin": fromStdin = true
            case "--url": url = it.next() ?? url
            default: fputs("Option inconnue : \(a)\n", stderr); return 2
            }
        }
        guard let base = DropServer.normalize(url), let host = base.host() else { fputs("✗ \(DropError.badURL(url).localizedDescription)\n", stderr); return 2 }
        if base.absoluteString != DropServer.normalize(prefs.baseURL)?.absoluteString {
            fputs("Attention : l'adresse des Réglages est \(prefs.baseURL). Changez-la dans Réglages › Drop pour utiliser \(base.absoluteString).\n", stderr)
        }
        var password: String?
        if fromStdin {
            password = readLine(strippingNewline: true)
        } else if let p = getpass("Mot de passe Drop (\(host)) : ") {
            password = String(cString: p)
        }
        guard let pw = password, !pw.isEmpty else { fputs("Mot de passe vide.\n", stderr); return 2 }
        let server = DropServer(base: base, password: pw)
        let result: Result<Int, Error> = wait { do { return .success(try await DropClient.shared.verify(server)) } catch { return .failure(error) } }
        switch result {
        case .success(let n):
            do { try DropKeychain.save(pw, for: host) } catch { fputs("✗ \(error.localizedDescription)\n", stderr); return 1 }
            print("✓ Connecté à \(host) · \(n) fichier\(n > 1 ? "s" : "") · mot de passe enregistré dans le trousseau.")
            refreshApp()
            return 0
        case .failure(let e):
            fputs("✗ \(e.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func dropLogout() -> Int32 {
        guard let host = DropServer.host(of: dropPrefs()) else { return 1 }
        DropKeychain.delete(for: host)
        print("Mot de passe de \(host) supprimé du trousseau.")
        refreshApp()
        return 0
    }

    private static func dropStatus() -> Int32 {
        let prefs = dropPrefs()
        guard let base = DropServer.normalize(prefs.baseURL), let host = base.host() else { fputs("✗ Adresse invalide : \(prefs.baseURL)\n", stderr); return 1 }
        print("Serveur      \(base.absoluteString)")
        print("Mot de passe \(DropKeychain.hasPassword(for: host) ? "enregistré" : "absent — forma drop login")")
        print("Expiration   \(prefs.expiry.label)")
        print("Lien         \(prefs.linkStyle.label.lowercased())\(prefs.copyLink ? " · copié" : "")")
        guard let server = try? DropServer.current(prefs) else { return 1 }
        let r: Result<Int, Error> = wait { do { return .success(try await DropClient.shared.verify(server)) } catch { return .failure(error) } }
        switch r {
        case .success(let n): print("Connexion    ✓ \(n) fichier\(n > 1 ? "s" : "") sur le serveur"); return 0
        case .failure(let e): print("Connexion    ✗ \(e.localizedDescription)"); return 1
        }
    }

    // MARK: List / remove / expire

    private static func dropList(_ args: [String]) -> Int32 {
        var limit = 20, all = false, remote = false, json = false
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "-n", "--limit": limit = it.next().flatMap(Int.init) ?? limit
            case "--all": all = true; limit = 100_000
            case "--remote": remote = true
            case "--json": json = true
            default: fputs("Option inconnue : \(a)\n", stderr); return 2
            }
        }
        let prefs = dropPrefs()
        if remote {
            guard let server = dropServer() else { return 1 }
            let r: Result<[DropFile], Error> = wait { do { return .success(try await DropClient.shared.list(server: server)) } catch { return .failure(error) } }
            switch r {
            case .failure(let e): fputs("✗ \(e.localizedDescription)\n", stderr); return 1
            case .success(let files):
                let shown = Array(files.prefix(limit))
                if json {
                    printJSON(shown.map { ["key": $0.key, "url": DropLinks.url(base: server.base, key: $0.key, style: prefs.linkStyle), "size": $0.size,
                                           "date": iso($0.date), "expiresAt": iso($0.expiry), "views": $0.views, "downloads": $0.downloads] as [String: Any] })
                } else {
                    for f in shown { print("\(f.date.formatted(date: .abbreviated, time: .shortened))  \(f.size.formattedBytes.padding(toLength: 9, withPad: " ", startingAt: 0)) \(f.views) vue\(f.views > 1 ? "s" : "")  \(DropLinks.url(base: server.base, key: f.key, style: prefs.linkStyle))") }
                    print("\(files.count) fichier\(files.count > 1 ? "s" : "") sur le serveur.")
                }
                return 0
            }
        }
        let records = Array(HistoryStore.shared.fetchDrops(limit: limit, includeDeleted: json).filter { json || $0.isLive }.prefix(limit))
        if json {
            printJSON(records.map { ["key": $0.key, "url": $0.url, "name": $0.name, "size": $0.size, "date": iso($0.date), "expiresAt": iso($0.expiresAt),
                                     "deleted": $0.isDeleted, "origin": $0.origin.rawValue] as [String: Any] })
        } else if records.isEmpty {
            print("Aucun envoi. Essayez : forma drop <fichier>")
        } else {
            for r in records { print("\(r.date.formatted(date: .abbreviated, time: .shortened))  \(r.size.formattedBytes.padding(toLength: 9, withPad: " ", startingAt: 0)) \(r.url)\(r.expiresAt.map { "  (expire \($0.formatted(.relative(presentation: .named))))" } ?? "")") }
        }
        return 0
    }

    private static func dropRemove(_ args: [String]) -> Int32 {
        guard !args.isEmpty else { fputs("forma drop rm <lien|clé>…\n", stderr); return 2 }
        guard let server = dropServer() else { return 1 }
        let keys = args.map { DropLinks.key(from: $0, base: server.base) }
        var failures: Int32 = 0
        for key in keys {
            let r: Result<Void, Error> = wait { do { try await DropClient.shared.delete(key: key, server: server); return .success(()) } catch { return .failure(error) } }
            switch r {
            case .success: HistoryStore.shared.markDropsDeleted([key]); print("🗑  \(key)")
            case .failure(let e): failures += 1; fputs("✗ \(key) : \(e.localizedDescription)\n", stderr)
            }
        }
        return failures == 0 ? 0 : 1
    }

    private static func dropExpire(_ args: [String]) -> Int32 {
        guard args.count == 2, let expiry = DropExpiry.parse(args[1]) else { fputs("forma drop expire <lien|clé> <1h|1d|7d|30d|never>\n", stderr); return 2 }
        guard let server = dropServer() else { return 1 }
        let key = DropLinks.key(from: args[0], base: server.base)
        let date = expiry.seconds.map { Date().addingTimeInterval(Double($0)) }
        let r: Result<Void, Error> = wait { do { try await DropClient.shared.setExpiry(key: key, to: date, server: server); return .success(()) } catch { return .failure(error) } }
        switch r {
        case .success:
            HistoryStore.shared.updateDropExpiry(key: key, to: date)
            print(expiry == .never ? "✓ \(key) n'expire plus" : "✓ \(key) expirera dans \(expiry.label)")
            return 0
        case .failure(let e): fputs("✗ \(e.localizedDescription)\n", stderr); return 1
        }
    }
}

/// One-line upload meter on stderr (only when it is a terminal).
final class ProgressLine: @unchecked Sendable {
    private let label: String
    private let enabled: Bool
    private let lock = NSLock()
    private var shown = false

    init(label: String, enabled: Bool) { self.label = label; self.enabled = enabled }

    func update(_ p: Double) {
        guard enabled else { return }
        lock.withLock {
            shown = true
            let width = 24, filled = Int(p * Double(width))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
            fputs("\r\u{1B}[2K↑ \(label.prefix(40)) \(bar) \(Int(p * 100)) %", stderr)
        }
    }

    func finish() {
        guard enabled else { return }
        lock.withLock { if shown { fputs("\r\u{1B}[2K", stderr); shown = false } }
    }
}
