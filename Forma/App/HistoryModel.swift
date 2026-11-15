import Foundation
import AppKit

/// Main-actor view of the history database. Reloads when the app, the CLI or a Shortcut records something.
@MainActor
@Observable
final class HistoryModel {
    static let shared = HistoryModel()

    private(set) var entries: [HistoryEntry] = []
    private var observers: [NSObjectProtocol] = []
    private var reloadWork: DispatchWorkItem?

    private init() {
        let store = HistoryStore.shared
        store.enabled = PreferencesStore.shared.prefs.historyEnabled
        let days = PreferencesStore.shared.prefs.historyRetentionDays
        DispatchQueue.global(qos: .utility).async { store.prune(olderThanDays: days) }
        let handler: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { HistoryModel.shared.scheduleReload() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .formaHistoryChanged, object: nil, queue: .main, using: handler))
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .formaHistoryChanged, object: nil, queue: .main, using: handler))
        reload()
    }

    /// Coalesces bursts (a 200-file batch posts 200 changes).
    func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { HistoryModel.shared.reload() } }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func reload() {
        Task.detached(priority: .userInitiated) {
            let list = HistoryStore.shared.fetch()
            await MainActor.run { HistoryModel.shared.entries = list }
        }
    }

    func entry(_ id: UUID?) -> HistoryEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id } ?? HistoryStore.shared.fetch().first { $0.id == id }
    }

    // MARK: Undo

    /// The most recent batch that can still be undone (one main-window run, one CLI call, one Shortcut…).
    var lastUndoableBatch: [HistoryEntry] {
        guard let first = entries.first(where: { !$0.isUndone }) else { return [] }
        guard let batch = first.batch else { return [first] }
        return entries.filter { $0.batch == batch && !$0.isUndone }
    }

    /// Undoes the given entries; returns a short summary, or throws the first blocking reason.
    @discardableResult
    func undo(_ list: [HistoryEntry], reveal: Bool = false) -> String {
        var done: [UUID] = [], restored: [URL] = [], kept = 0
        var problems: [String] = []
        for e in list where !e.isUndone {
            do {
                let r = try HistoryUndo.undo(e)
                done.append(e.id)
                restored += r.restored
                kept += r.keptModified.count
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        HistoryStore.shared.markUndone(done)
        AppModel.shared.didUndo(Set(done))
        reload()
        if reveal, !restored.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(restored) }

        var msg = done.isEmpty ? "Rien n'a été annulé" : "\(done.count) traitement\(done.count > 1 ? "s" : "") annulé\(done.count > 1 ? "s" : "")"
        if !restored.isEmpty { msg += " · \(restored.count) original\(restored.count > 1 ? "aux" : "") restauré\(restored.count > 1 ? "s" : "")" }
        if kept > 0 { msg += " · \(kept) fichier\(kept > 1 ? "s" : "") modifié\(kept > 1 ? "s" : "") conservé\(kept > 1 ? "s" : "")" }
        if let p = problems.first {
            let alert = NSAlert()
            alert.messageText = done.isEmpty ? "Annulation impossible" : "Annulation partielle"
            alert.informativeText = problems.count > 1 ? "\(p)\n\n(+ \(problems.count - 1) autre\(problems.count > 2 ? "s" : ""))" : p
            alert.alertStyle = .warning
            alert.runModal()
        }
        return msg
    }

    func undoLastBatch() {
        let batch = lastUndoableBatch
        guard !batch.isEmpty else { NSSound.beep(); return }
        let msg = undo(batch)
        Toast.show(msg, symbol: "arrow.uturn.backward")
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        let list = Array(ids)
        DispatchQueue.global(qos: .utility).async { HistoryStore.shared.delete(list) }
    }

    func clearAll() {
        entries = []
        DispatchQueue.global(qos: .utility).async { HistoryStore.shared.deleteAll() }
    }
}
