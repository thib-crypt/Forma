import SwiftUI
import AppKit

@main
enum FormaMain {
    static func main() {
        let args = CommandLine.arguments
        if CLI.shouldHandle(args) {
            exit(CLI.run(args))
        }
        FormaApp.main()
    }
}

struct FormaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = PreferencesStore.shared
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Forma", id: "main") {
            MainView()
                .environment(model)
                .environment(store)
                .frame(minWidth: 760, minHeight: 520)
                .preferredColorScheme(store.colorScheme)
                .background(WindowOpenerBridge())
        }
        .defaultSize(width: 980, height: 660)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified)
        .commands { FormaCommands(model: model, store: store) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(store)
                .preferredColorScheme(store.colorScheme)
        }

        MenuBarExtra(isInserted: Binding(get: { store.menuBarVisible }, set: { v in
            if store.prefs.showInMenuBar != v { store.prefs.showInMenuBar = v }
        })) {
            MenuBarView()
                .environment(model)
                .environment(store)
        } label: {
            Image(systemName: model.isRunning ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Captures SwiftUI's openWindow so AppKit entry points (Services, Dock, CLI) can show the main window.
private struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { AppDelegate.openMain = { openWindow(id: "main") } }
    }
}

struct FormaCommands: Commands {
    let model: AppModel
    let store: PreferencesStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Ajouter des fichiers…") { AddPanel.present() }.keyboardShortcut("o")
        }
        CommandMenu("Traitement") {
            Button("Convertir") { model.mode = .convert }.keyboardShortcut("1")
            Button("Compresser") { model.mode = .compress }.keyboardShortcut("2")
            Divider()
            Button(model.isRunning ? "Arrêter" : "Démarrer") {
                model.isRunning ? model.cancel() : model.start()
            }.keyboardShortcut(.return, modifiers: .command)
            Button(model.isPaused ? "Reprendre" : "Mettre en pause") {
                model.isPaused ? model.resume() : model.pause()
            }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!model.isRunning)
            Divider()
            Button("Réessayer les échecs") { model.retryFailed() }
            Button("Vider les fichiers traités") { model.clearFinished() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            Divider()
            Button("Optimiser le presse-papiers") { ClipboardOptimizer.shared.optimizeNow() }.keyboardShortcut("v", modifiers: [.command, .option])
        }
    }
}

enum AddPanel {
    @MainActor static func present(mode: ProcessMode? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choisissez des fichiers ou des dossiers à convertir ou compresser"
        panel.prompt = "Ajouter"
        if panel.runModal() == .OK { AppModel.shared.add(panel.urls, mode: mode) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMain: (() -> Void)?
    private let services = ServicesProvider()

    @MainActor static func showMainWindow() {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Forma" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Notifier.requestAuthorization()
        MainActor.assumeIsolated {
            FolderWatcher.shared.reload()
            Scheduler.shared.start()
            ClipboardOptimizer.shared.apply()
        }
        cleanupOrphanedTemps()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppDelegate.showMainWindow()
            AppModel.shared.add(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !PreferencesStore.shared.prefs.showInMenuBar }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppDelegate.showMainWindow() } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.isRunning else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Un traitement est en cours"
            alert.informativeText = "Quitter maintenant annulera les fichiers en cours."
            alert.addButton(withTitle: "Quitter")
            alert.addButton(withTitle: "Annuler")
            if alert.runModal() == .alertFirstButtonReturn { AppModel.shared.cancel(); return .terminateNow }
            return .terminateCancel
        }
    }

    /// Removes temp files left by a crash or forced quit.
    private func cleanupOrphanedTemps() {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("Forma-Intents-") {
                try? fm.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }
}
