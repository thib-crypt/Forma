import Foundation
import AppKit

/// What an upload gave back.
struct DropUpload: Sendable, Hashable, Identifiable {
    var key: String
    var name: String
    var url: String
    var size: Int64
    var expiresAt: Date?
    var source: URL
    var id: String { key }
}

/// Sends local files to Drop and keeps a local log of the links (SQLite, next to the history).
/// Everything here is `nonisolated`: the app, the CLI, Shortcuts and watched folders all call it.
enum DropUploader {

    /// Uploads one file, or a folder (zipped first). Records the link in the log.
    static func upload(_ input: URL, name: String? = nil, options: DropOptions? = nil, prefs: DropPreferences, origin: HistoryOrigin,
                       batch: UUID? = nil, entry: UUID? = nil,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> DropUpload {
        let server = try DropServer.current(prefs)
        guard FileManager.default.fileExists(atPath: input.path) else { throw DropError.missingFile(input.lastPathComponent) }
        let expiry = options?.expiry ?? prefs.expiry

        var file = input
        var cleanup: URL?
        if input.isDirectory {
            let zipped = try await zip(input)
            file = zipped
            cleanup = zipped.deletingLastPathComponent()
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        let size = file.fileSize
        guard size > 0 else { throw ToolError("« \(file.lastPathComponent) » est vide : rien à envoyer.") }
        let remote = try await DropClient.shared.upload(file, name: name ?? file.lastPathComponent, expiry: expiry, server: server, progress: progress)
        let url = DropLinks.url(base: server.base, key: remote.key, style: prefs.linkStyle)
        let record = DropRecord(key: remote.key, date: Date(), name: remote.name, url: url, size: remote.size > 0 ? remote.size : size,
                                expiresAt: remote.expiry, origin: origin, batch: batch, entry: entry, source: input.path,
                                server: server.host, deletedAt: nil)
        HistoryStore.shared.recordDrop(record)
        return DropUpload(key: remote.key, name: remote.name, url: url, size: record.size, expiresAt: remote.expiry, source: input)
    }

    /// `ditto -c -k --keepParent`: a Finder-compatible zip of the folder, in a private temporary directory.
    static func zip(_ folder: URL) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(folder.lastPathComponent + ".zip")
        let name = folder.lastPathComponent
        let status: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", "--sequesterRsrc", folder.path, dest.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        guard status == 0, dest.fileSize > 0 else {
            try? FileManager.default.removeItem(at: dir)
            throw DropError.zipFailed(name)
        }
        return dest
    }

    // MARK: Remote deletion

    /// Deletes the files on the server and marks them deleted in the log. Returns the keys that could not be deleted.
    @discardableResult
    static func delete(_ records: [DropRecord], prefs: DropPreferences) async -> [String] {
        guard !records.isEmpty, let server = try? DropServer.current(prefs) else { return records.map(\.key) }
        var failed: [String] = []
        var done: [String] = []
        for r in records {
            do { try await DropClient.shared.delete(key: r.key, server: server); done.append(r.key) }
            catch { failed.append(r.key) }
        }
        HistoryStore.shared.markDropsDeleted(done)
        return failed
    }

    /// Links that belong to history entries being undone (a converted file sent to Drop goes back with its conversion).
    static func records(forEntries ids: [UUID]) -> [DropRecord] {
        HistoryStore.shared.fetchDrops(limit: 5000, entries: ids)
    }

    // MARK: Clipboard

    /// Links on the pasteboard: one → the URL, several → one per line.
    @MainActor
    static func copy(_ links: [String]) {
        guard !links.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(links.joined(separator: "\n"), forType: .string)
        if links.count == 1, let u = URL(string: links[0]) { pb.setString(u.absoluteString, forType: .URL) }
    }
}
