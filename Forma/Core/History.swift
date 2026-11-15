import Foundation
import SQLite3

// MARK: - Model

/// Where a processed file came from (shown as a badge in the history).
enum HistoryOrigin: String, Codable, Sendable, CaseIterable {
    case app, cli, shortcut, watch, schedule, copia, finder, share, service, url, menuBar

    var label: String {
        switch self {
        case .app: "Forma"
        case .cli: "Terminal"
        case .shortcut: "Raccourci"
        case .watch: "Dossier surveillé"
        case .schedule: "Planifié"
        case .copia: "Copia"
        case .finder: "Finder"
        case .share: "Partage"
        case .service: "Service"
        case .url: "Lien forma://"
        case .menuBar: "Barre des menus"
        }
    }
    /// Jobs started outside the main window, undoable from the Finder menu.
    var isExternal: Bool { [.finder, .share, .service, .url].contains(self) }

    var symbol: String {
        switch self {
        case .app: "macwindow"
        case .cli: "terminal"
        case .shortcut: "square.2.layers.3d"
        case .watch: "eye"
        case .schedule: "clock"
        case .copia: "doc.on.clipboard"
        case .finder: "folder"
        case .share: "square.and.arrow.up"
        case .service: "contextualmenu.and.cursorarrow"
        case .url: "link"
        case .menuBar: "menubar.rectangle"
        }
    }
}

/// A file Forma moved to the Trash while processing (original, or an existing file it overwrote).
struct TrashedFile: Codable, Hashable, Sendable {
    var original: String
    var trash: String
}

struct HistoryOutput: Codable, Hashable, Sendable {
    var path: String
    var size: Int64
    var url: URL { URL(fileURLWithPath: path) }
}

struct HistoryEntry: Identifiable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var mode: ProcessMode
    var origin: HistoryOrigin
    var batch: UUID?
    var input: URL
    var inputSize: Int64
    var outputs: [HistoryOutput]
    var formatName: String
    /// Files sent to the Trash by this run (needed to undo it).
    var trashed: [TrashedFile]
    var note: String?
    var duration: TimeInterval
    var undoneAt: Date?

    var outputSize: Int64 { outputs.reduce(0) { $0 + $1.size } }
    var outputURLs: [URL] { outputs.map(\.url) }
    var isUndone: Bool { undoneAt != nil }
    var originalWasTrashed: Bool { trashed.contains { $0.original == input.path } }
    var savings: Double? {
        guard inputSize > 0, outputSize > 0, mode != .upscale else { return nil }
        return 1 - Double(outputSize) / Double(inputSize)
    }
    var savedBytes: Int64 { mode == .upscale ? 0 : max(0, inputSize - outputSize) }

    /// The original as it can be read now: in place, or still in the Trash.
    var readableOriginal: URL? {
        let fm = FileManager.default
        if let t = trashed.first(where: { $0.original == input.path }), fm.fileExists(atPath: t.trash) {
            return URL(fileURLWithPath: t.trash)
        }
        // In "replace originals" mode the output may now sit at the original path: that's not the original.
        if fm.fileExists(atPath: input.path), !outputs.contains(where: { $0.path == input.path }) { return input }
        return nil
    }
}

extension Notification.Name {
    /// Posted (also as a distributed notification, for the CLI and companion apps) when the history changes.
    static let formaHistoryChanged = Notification.Name("com.thibault.forma.historyChanged")
}

// MARK: - Store (SQLite, shared by the app and the `forma` CLI)

/// Thread-safe, multi-process history. WAL + busy timeout so the CLI and the app can write at the same time.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.thibault.forma.history")
    private let lock = NSLock()
    private var _enabled: Bool
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    /// Mirrors `Preferences.historyEnabled` (set by the app; read once from the prefs in the CLI).
    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forma", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("History.sqlite")
    }

    private init() {
        _enabled = PreferencesStore.loadSnapshot().historyEnabled
        queue.sync { open() }
    }

    private func open() {
        guard sqlite3_open_v2(Self.fileURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            NSLog("Forma history: cannot open database")
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 4000)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS entries(
            id TEXT PRIMARY KEY,
            date REAL NOT NULL,
            mode TEXT NOT NULL,
            origin TEXT NOT NULL,
            batch TEXT,
            input TEXT NOT NULL,
            input_size INTEGER NOT NULL,
            outputs TEXT NOT NULL,
            format TEXT NOT NULL,
            trashed TEXT NOT NULL,
            note TEXT,
            duration REAL NOT NULL DEFAULT 0,
            undone_at REAL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS entries_date ON entries(date DESC)")
        exec("CREATE INDEX IF NOT EXISTS entries_batch ON entries(batch)")
    }

    deinit { sqlite3_close_v2(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: Writes

    func record(_ e: HistoryEntry) {
        guard enabled else { return }
        let enc = JSONEncoder()
        let outputs = String(data: (try? enc.encode(e.outputs)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let trashed = String(data: (try? enc.encode(e.trashed)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        queue.sync {
            guard let db else { return }
            var st: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO entries(id,date,mode,origin,batch,input,input_size,outputs,format,trashed,note,duration,undone_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            bind(st, 1, e.id.uuidString)
            sqlite3_bind_double(st, 2, e.date.timeIntervalSince1970)
            bind(st, 3, e.mode.rawValue)
            bind(st, 4, e.origin.rawValue)
            bind(st, 5, e.batch?.uuidString)
            bind(st, 6, e.input.path)
            sqlite3_bind_int64(st, 7, e.inputSize)
            bind(st, 8, outputs)
            bind(st, 9, e.formatName)
            bind(st, 10, trashed)
            bind(st, 11, e.note)
            sqlite3_bind_double(st, 12, e.duration)
            if let u = e.undoneAt { sqlite3_bind_double(st, 13, u.timeIntervalSince1970) } else { sqlite3_bind_null(st, 13) }
            sqlite3_step(st)
        }
        Self.postChange()
    }

    func markUndone(_ ids: [UUID], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        queue.sync {
            for id in ids {
                run("UPDATE entries SET undone_at=? WHERE id=?") { st in
                    sqlite3_bind_double(st, 1, date.timeIntervalSince1970)
                    self.bind(st, 2, id.uuidString)
                }
            }
        }
        Self.postChange()
    }

    func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for id in ids { run("DELETE FROM entries WHERE id=?") { self.bind($0, 1, id.uuidString) } }
            exec("COMMIT")
        }
        Self.postChange()
    }

    func deleteAll() {
        queue.sync { _ = exec("DELETE FROM entries"); _ = exec("VACUUM") }
        Self.postChange()
    }

    /// Drops entries older than `days` (0 = keep forever).
    func prune(olderThanDays days: Int) {
        guard days > 0 else { return }
        let limit = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        queue.sync { run("DELETE FROM entries WHERE date < ?") { sqlite3_bind_double($0, 1, limit) } }
    }

    // MARK: Reads

    func fetch(limit: Int = 5000) -> [HistoryEntry] {
        queue.sync {
            guard let db else { return [] }
            var st: OpaquePointer?
            let sql = "SELECT id,date,mode,origin,batch,input,input_size,outputs,format,trashed,note,duration,undone_at FROM entries ORDER BY date DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int(st, 1, Int32(limit))
            let dec = JSONDecoder()
            var out: [HistoryEntry] = []
            while sqlite3_step(st) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(st, 0) ?? ""),
                      let mode = ProcessMode(rawValue: text(st, 2) ?? ""),
                      let input = text(st, 5) else { continue }
                let outputs = (try? dec.decode([HistoryOutput].self, from: Data((text(st, 7) ?? "[]").utf8))) ?? []
                let trashed = (try? dec.decode([TrashedFile].self, from: Data((text(st, 9) ?? "[]").utf8))) ?? []
                out.append(HistoryEntry(
                    id: id,
                    date: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                    mode: mode,
                    origin: HistoryOrigin(rawValue: text(st, 3) ?? "") ?? .app,
                    batch: text(st, 4).flatMap(UUID.init(uuidString:)),
                    input: URL(fileURLWithPath: input),
                    inputSize: sqlite3_column_int64(st, 6),
                    outputs: outputs,
                    formatName: text(st, 8) ?? "",
                    trashed: trashed,
                    note: text(st, 10),
                    duration: sqlite3_column_double(st, 11),
                    undoneAt: sqlite3_column_type(st, 12) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, 12))
                ))
            }
            return out
        }
    }

    // MARK: Helpers

    private func run(_ sql: String, _ binder: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        binder(st)
        sqlite3_step(st)
        sqlite3_finalize(st)
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(st, i, s, -1, Self.transient) } else { sqlite3_bind_null(st, i) }
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    static func postChange() {
        NotificationCenter.default.post(name: .formaHistoryChanged, object: nil)
        DistributedNotificationCenter.default().postNotificationName(.formaHistoryChanged, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

// MARK: - Undo

enum HistoryUndo {
    struct Report: Sendable {
        var restored: [URL] = []
        var trashedOutputs: [URL] = []
        var keptModified: [URL] = []
    }

    /// Checks that undoing is safe before touching anything.
    static func blocker(for e: HistoryEntry) -> String? {
        if e.isUndone { return "Ce traitement a déjà été annulé." }
        let fm = FileManager.default
        if let t = e.trashed.first(where: { $0.original == e.input.path }), !fm.fileExists(atPath: t.trash) {
            return "L'original de « \(e.input.lastPathComponent) » n'est plus dans la Corbeille : annuler supprimerait la seule copie restante."
        }
        return nil
    }

    /// Moves the outputs to the Trash and puts back what Forma had trashed. Outputs modified since (different size)
    /// are kept, never trashed.
    static func undo(_ e: HistoryEntry) throws -> Report {
        if let b = blocker(for: e) { throw ToolError(b) }
        let fm = FileManager.default
        var report = Report()
        for o in e.outputs where fm.fileExists(atPath: o.path) {
            let u = o.url
            if u.fileSize != o.size { report.keptModified.append(u); continue }
            try fm.trashItem(at: u, resultingItemURL: nil)
            report.trashedOutputs.append(u)
        }
        for t in e.trashed where fm.fileExists(atPath: t.trash) {
            var dest = URL(fileURLWithPath: t.original)
            if fm.fileExists(atPath: dest.path) { dest = uniqueRestoreURL(for: dest) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: URL(fileURLWithPath: t.trash), to: dest)
            report.restored.append(dest)
        }
        return report
    }

    private static func uniqueRestoreURL(for url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 1
        while true {
            let name = n == 1 ? "\(base) (restauré)" : "\(base) (restauré \(n))"
            let c = dir.appendingPathComponent(name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }
}
