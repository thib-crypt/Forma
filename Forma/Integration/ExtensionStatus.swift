import Foundation
import FinderSync

/// State of Forma's extensions as PlugInKit sees them (`pluginkit -m -v -i …`). Shared by Settings › Finder and
/// `forma finder status`.
struct ExtensionStatus: Sendable {
    enum State: String, Sendable { case enabled, disabled, rejected, missing }

    static let finderID = "com.thibault.forma.FinderMenu"
    static let shareID = "com.thibault.forma.Share"

    var id: String
    var state: State
    var path: String?
    var version: String?
    /// Other registered copies (a stale build folder can shadow the installed app).
    var otherPaths: [String] = []

    var label: String {
        switch state {
        case .enabled: "Activée"
        case .disabled: "Désactivée"
        case .rejected: "Refusée par macOS"
        case .missing: "Non enregistrée"
        }
    }

    /// Whether the loaded copy is the one inside the running app.
    var loadsThisApp: Bool {
        guard let path else { return false }
        return path.hasPrefix(Bundle.main.bundleURL.path + "/")
    }

    static func query(_ id: String) -> ExtensionStatus {
        let out = run("/usr/bin/pluginkit", ["-m", "-A", "-v", "-i", id])
        var lines = out.split(separator: "\n").map(String.init).filter { $0.contains(id) }
        guard !lines.isEmpty else { return ExtensionStatus(id: id, state: .missing) }
        // Prefer the copy inside the running app.
        let mine = Bundle.main.bundleURL.path + "/"
        lines.sort { a, b in a.contains(mine) && !b.contains(mine) }
        let parts = lines[0].split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        let flag = lines[0].trimmingCharacters(in: .whitespaces).first
        let state: State = switch flag {
        case "+": .enabled
        case "-": .disabled
        case "!": .rejected
        default: .disabled
        }
        let version = parts.first.flatMap { p in p.firstRange(of: "(").map { String(p[p.index(after: $0.lowerBound)...].dropLast()) } }
        let paths = lines.compactMap { $0.split(separator: "\t").last.map(String.init) }.filter { $0.hasPrefix("/") }
        return ExtensionStatus(id: id, state: state, path: paths.first, version: version, otherPaths: Array(paths.dropFirst()))
    }

    @discardableResult
    static func setEnabled(_ id: String, _ on: Bool) -> Bool {
        run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", id]).isEmpty || true
    }

    /// Re-registers the extensions of this app and forgets the other copies.
    static func reset() -> [String] {
        var log: [String] = []
        for id in [finderID, shareID] {
            let s = query(id)
            for p in s.otherPaths + [s.path].compactMap({ $0 }) where !p.hasPrefix(Bundle.main.bundleURL.path + "/") {
                _ = run("/usr/bin/pluginkit", ["-r", p]); log.append("désenregistré : \(p)")
            }
        }
        let plugins = Bundle.main.builtInPlugInsURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: plugins.path)) ?? [] where name.hasSuffix(".appex") {
            let p = plugins.appendingPathComponent(name).path
            _ = run("/usr/bin/pluginkit", ["-a", p]); log.append("enregistré : \(p)")
        }
        setEnabled(finderID, true)
        setEnabled(shareID, true)
        return log
    }

    static var finderEnabledBySystem: Bool { FIFinderSyncController.isExtensionEnabled }

    static func openSystemSettings() { FIFinderSyncController.showExtensionManagementInterface() }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
