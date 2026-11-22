import SwiftUI
import AppKit

@main
enum FormaMain {
    static func main() {
        let args = CommandLine.arguments
        if CLI.shouldHandle(args) {
            exit(CLI.run(args))
        }
        // Only one Forma app process at a time (several copies of Forma.app can be registered: /Applications and
        // the Xcode build folders). A second one hands what it was launched for to the first, then quits.
        if !InstanceLock.acquire() {
            DuplicateLaunch.run(headless: args.contains("--headless"))
        }
        // Launched by the Finder / Share extension: no window, no Dock icon (decided before NSApp exists).
        if LaunchContext.detectHeadless(args) {
            MainActor.assumeIsolated { LaunchContext.headless = true }
            NSApplication.shared.setActivationPolicy(.accessory)
        } else if PreferencesStore.loadSnapshot().effectiveDockIcon != .always {
            // "Barre des menus" presence: never flash a Dock icon at launch (a window brings it back if wanted).
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        FormaApp.main()
    }
}

struct FormaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Forma's windows belong to `WindowRouter` (AppKit), so they can be opened from the Dock, the menu bar,
        // the Finder or a shortcut even when no SwiftUI view exists yet. This scene only carries the menus
        // and is never shown: its "Réglages…" item is replaced below.
        Settings { EmptyView() }
            .commands { FormaCommands(model: AppModel.shared, store: PreferencesStore.shared) }
    }
}

struct FormaCommands: Commands {
    let model: AppModel
    let store: PreferencesStore

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Réglages…") { AppDelegate.showSettings() }.keyboardShortcut(",")
        }
        CommandGroup(before: .windowList) {
            Button("Forma") { AppDelegate.showMainWindow() }.keyboardShortcut("0")
            Button("Historique") { AppDelegate.showHistory() }.keyboardShortcut("y")
            Button("Envois Drop") { AppDelegate.showDrop() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(replacing: .newItem) {
            Button("Ajouter des fichiers…") { AddPanel.present() }.keyboardShortcut("o")
        }
        CommandMenu("Traitement") {
            Button("Convertir") { model.mode = .convert }.keyboardShortcut("1")
            Button("Compresser") { model.mode = .compress }.keyboardShortcut("2")
            Button("Agrandir ×2 (IA)") { model.mode = .upscale }.keyboardShortcut("3")
            Divider()
            Button(model.isRunning ? "Arrêter" : "Démarrer") {
                model.isRunning ? model.cancel() : model.start()
            }.keyboardShortcut(.return, modifiers: .command)
            Button(model.isPaused ? "Reprendre" : "Mettre en pause") {
                model.isPaused ? model.resume() : model.pause()
            }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!model.isRunning)
            Divider()
            Button("Aperçu avant / après") {
                if let item = model.items.first(where: { model.selection.contains($0.id) }) ?? model.items.first {
                    PreviewWindow.open(item, mode: model.mode)
                }
            }
            .disabled(model.items.isEmpty)
            Button("Annuler le dernier traitement") { HistoryModel.shared.undoLastBatch() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(HistoryModel.shared.lastUndoableBatch.isEmpty)
            Divider()
            Button("Réessayer les échecs") { model.retryFailed() }
            Button("Vider les fichiers traités") { model.clearFinished() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            Divider()
            Button("Optimiser le presse-papiers") { ClipboardOptimizer.shared.optimizeNow() }.keyboardShortcut("v", modifiers: [.command, .option])
        }
        CommandMenu("Drop") {
            Button("Envoyer des fichiers sur Drop…") { DropActions.pickAndUpload() }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Envoyer le presse-papiers sur Drop") { DropActions.uploadClipboard() }.keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Afficher les envois") { AppDelegate.showDrop() }
            Button("Réglages Drop…") { SettingsNavigation.shared.tab = .drop; AppDelegate.showSettings() }
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
    private let services = ServicesProvider()

    @MainActor static func showMainWindow() { WindowRouter.shared.show(.main) }
    @MainActor static func showHistory() { WindowRouter.shared.show(.history) }
    @MainActor static func showDrop() { WindowRouter.shared.show(.drop) }
    @MainActor static func showSettings() { WindowRouter.shared.showSettings() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Before launch completes, so the URL that launched us is routed here and never opens a window.
            RequestRouter.shared.installURLHandler()
            if LaunchContext.headless { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Notifier.requestAuthorization()
        MainActor.assumeIsolated {
            _ = HistoryModel.shared
            FolderWatcher.shared.reload()
            Scheduler.shared.start()
            ClipboardOptimizer.shared.apply()
            MenuBarController.shared.install()
            MenuConfigPublisher.shared.start()
            GlobalHotKeyCenter.shared.reload()
            DockProgress.shared.start()
            RequestRouter.shared.drainInbox()
            observeWindowsForDockPolicy()
            presentAtLaunch(notification)
            LaunchContext.updateDockPolicy()
            // Safety net: a headless launch whose request vanished must not linger.
            LaunchContext.quitIfIdle(after: 15)
        }
        cleanupOrphanedTemps()
    }

    /// What an ordinary launch shows. Launches made to open files or links show what those need instead.
    @MainActor private func presentAtLaunch(_ notification: Notification) {
        guard !LaunchContext.headless else { return }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        let prefs = PreferencesStore.shared.prefs
        if !isDefault {
            // Opened for a file (it shows the window itself) or a forma:// link (works in the background).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    if !LaunchContext.hasVisibleWindow && !WindowRouter.shared.isVisible(.main) {
                        LaunchContext.headless = true
                        LaunchContext.updateDockPolicy()
                        LaunchContext.quitIfIdle(after: 15)
                    }
                }
            }
            return
        }
        if prefs.showInMenuBar && (loginItem || !prefs.showWindowAtLaunch) {
            // Lives in the menu bar: a manual launch opens the panel under the icon, so you see where Forma is.
            if !loginItem {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    MainActor.assumeIsolated { MenuBarController.shared.open() }
                }
            }
            return
        }
        WindowRouter.shared.show(.main)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MainActor.assumeIsolated { DockMenu.make() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let links = urls.filter { $0.scheme?.lowercased() == GroupContainer.scheme }
            links.forEach(RequestRouter.shared.handle)
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return }
            AppDelegate.showMainWindow()
            AppModel.shared.add(files)
        }
    }

    /// Dock icon only while a window is open, in headless or "mode discret".
    @MainActor private func observeWindowsForDockPolicy() {
        let nc = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { LaunchContext.updateDockPolicy() } }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main, using: update)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            !PreferencesStore.shared.prefs.showInMenuBar && !JobCenter.shared.isBusy && !ProgressHUD.shared.isVisible
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag` counts panels (HUD, menu bar panel), so decide on Forma's real windows.
        MainActor.assumeIsolated {
            if !LaunchContext.hasVisibleWindow { AppDelegate.showMainWindow() }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.isRunning || JobCenter.shared.isBusy else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Un traitement est en cours"
            alert.informativeText = "Quitter maintenant annulera les fichiers en cours."
            alert.addButton(withTitle: "Quitter")
            alert.addButton(withTitle: "Annuler")
            if alert.runModal() == .alertFirstButtonReturn {
                AppModel.shared.cancel()
                JobCenter.shared.cancelAll()
                return .terminateNow
            }
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
