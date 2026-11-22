import AppKit
import UniformTypeIdentifiers

/// Entry points for sending things to Drop from the app itself (menu commands, menu bar, main window).
@MainActor
enum DropActions {
    static var isConfigured: Bool { DropServer.isConfigured(PreferencesStore.shared.prefs.drop) }

    /// Queues an upload job (same path as the Finder menu): progress in the HUD, link on the clipboard.
    @discardableResult
    static func upload(_ urls: [URL], source: RequestSource = .menuBar, options: DropOptions = DropOptions()) -> Bool {
        guard !urls.isEmpty else { return false }
        guard isConfigured else {
            Toast.show("Drop n'est pas configuré", symbol: "exclamationmark.triangle")
            SettingsNavigation.shared.tab = .drop
            AppDelegate.showSettings()
            return false
        }
        var r = ExternalRequest(source: source, action: .upload, paths: urls.map(\.path))
        r.drop = options
        JobCenter.shared.submit(r)
        return true
    }

    static func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.message = "Choisissez les fichiers à envoyer sur Drop"
        panel.prompt = "Envoyer"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        NSApp.activate()
        if panel.runModal() == .OK { upload(panel.urls, source: .menuBar) }
    }

    /// Files on the pasteboard go as they are; an image or text is written to a temporary file first.
    static func uploadClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            upload(urls)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-Clipboard-\(UUID().uuidString)", isDirectory: true)
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                               locale: Locale(identifier: "fr_FR"), timeZone: .current, calendar: .current))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
                let file = dir.appendingPathComponent("Presse-papiers \(stamp).png")
                try png.write(to: file)
                upload([file])
            } else if let text = pb.string(forType: .string), !text.isEmpty {
                let file = dir.appendingPathComponent("Presse-papiers \(stamp).txt")
                try Data(text.utf8).write(to: file)
                upload([file])
            } else {
                Toast.show("Le presse-papiers est vide", symbol: "doc.on.clipboard")
            }
        } catch {
            Toast.show("Impossible de lire le presse-papiers", symbol: "exclamationmark.triangle")
        }
    }
}
