import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Global shortcut

/// A system-wide shortcut (Settings › Général) that opens the menu bar panel or the main window from any app.
/// Carbon hot keys need no Accessibility permission.
@MainActor
@Observable
final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()

    /// Another app already owns the combination.
    private(set) var registrationFailed = false
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    private init() {}

    func reload() {
        unregister()
        guard let key = PreferencesStore.shared.prefs.globalHotKey else { registrationFailed = false; return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x464F_524D), id: 1)  // 'FORM'
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        registrationFailed = status != noErr
    }

    /// While the recorder listens, the current shortcut must not fire.
    func suspend() { unregister() }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKeyCenter.shared.fire() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire() {
        let prefs = PreferencesStore.shared.prefs
        if prefs.hotKeyAction == .menuBarPanel, prefs.showInMenuBar {
            MenuBarController.shared.toggle()
        } else {
            WindowRouter.shared.toggleMain()
        }
    }

    // MARK: Conversion from AppKit events

    static func make(from event: NSEvent) -> GlobalHotKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = UInt32(event.keyCode)
        let isFunctionKey = functionKeys[code] != nil
        // A plain letter (or ⇧ + letter) would swallow typing everywhere: require ⌘, ⌥ or ⌃, except for F-keys.
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var text = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); text += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); text += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); text += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); text += "⌘" }
        guard let name = keyName(code, event: event) else { return nil }
        return GlobalHotKey(keyCode: code, modifiers: carbon, display: text + name)
    }

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
    ]

    private static func keyName(_ code: UInt32, event: NSEvent) -> String? {
        if let f = functionKeys[code] { return f }
        switch Int(code) {
        case kVK_Space: return "Espace"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Escape, kVK_Delete, kVK_ForwardDelete: return nil
        default:
            guard let c = event.charactersIgnoringModifiers?.uppercased(), !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return c
        }
    }
}

/// Click, then press the combination. Esc cancels, ⌫ clears.
struct HotKeyRecorder: View {
    @Binding var hotKey: GlobalHotKey?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 6) {
                    if recording {
                        Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse)
                        Text(hint ?? "Tapez le raccourci…")
                    } else if let hotKey {
                        Text(hotKey.display).font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
                    } else {
                        Text("Enregistrer un raccourci")
                    }
                }
                .frame(minWidth: 150)
            }
            .help(recording ? "Échap pour annuler, ⌫ pour effacer" : "Cliquez puis tapez une combinaison avec ⌘, ⌥ ou ⌃")
            if hotKey != nil && !recording {
                Button { hotKey = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Supprimer le raccourci")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = nil
        GlobalHotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                hotKey = nil
                stop()
            default:
                if let key = GlobalHotKeyCenter.make(from: event) {
                    hotKey = key
                    stop()
                } else {
                    hint = "Ajoutez ⌘, ⌥ ou ⌃"
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { GlobalHotKeyCenter.shared.reload() }
        recording = false
    }
}

// MARK: - Dock tile progress

/// While Forma works (main window or background jobs), its Dock icon shows a progress bar, like the Finder's copies.
@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private var lastStep = -1
    private let tileView = DockTileProgressView()

    func start() { observe() }

    private func observe() {
        withObservationTracking { update() } onChange: {
            DispatchQueue.main.async { DockProgress.shared.observe() }
        }
    }

    private func update() {
        let model = AppModel.shared
        let jobs = JobCenter.shared
        let running = model.isRunning || jobs.isBusy
        let progress = model.isRunning ? model.overallProgress : jobs.isBusy ? jobs.overallProgress : 0
        let step = running ? Int((progress * 100).rounded()) : -1
        guard step != lastStep else { return }
        lastStep = step
        let tile = NSApp.dockTile
        if running {
            tileView.progress = Double(step) / 100
            tileView.paused = model.isPaused
            if tile.contentView !== tileView { tile.contentView = tileView }
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

private final class DockTileProgressView: NSView {
    var progress: Double = 0
    var paused = false

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let inset = bounds.width * 0.14
        let height = max(8, bounds.height * 0.085)
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let inner = track.insetBy(dx: 1.5, dy: 1.5)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * progress), height: inner.height)
        (paused ? NSColor.systemOrange : NSColor.white).setFill()
        NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

// MARK: - Dock menu

/// Right-click (or long press) on Forma's Dock icon.
@MainActor
enum DockMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: "", action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let model = AppModel.shared
        if model.isRunning {
            add(model.isPaused ? "Reprendre" : "Mettre en pause", model.isPaused ? "play.fill" : "pause.fill") {
                model.isPaused ? model.resume() : model.pause()
            }
            add("Arrêter le traitement", "stop.fill") { model.cancel() }
            menu.addItem(.separator())
        }
        add("Ajouter des fichiers…", "plus") {
            AppDelegate.showMainWindow()
            AddPanel.present()
        }
        add("Optimiser le presse-papiers", "doc.on.clipboard") { ClipboardOptimizer.shared.optimizeNow() }
        if DropModel.shared.isConfigured {
            add("Envoyer le presse-papiers sur Drop", "arrow.up.circle") { DropActions.uploadClipboard() }
        }
        menu.addItem(.separator())
        add("Historique", "clock.arrow.circlepath") { AppDelegate.showHistory() }
        if DropModel.shared.isConfigured {
            add("Envois Drop", "list.bullet") { AppDelegate.showDrop() }
        }
        add("Annuler le dernier traitement", "arrow.uturn.backward",
            enabled: !HistoryModel.shared.lastUndoableBatch.isEmpty) { HistoryModel.shared.undoLastBatch() }
        menu.addItem(.separator())
        let prefs = PreferencesStore.shared
        if prefs.prefs.showInMenuBar {
            add("Garder Forma dans la barre des menus seulement", "menubar.rectangle") {
                prefs.prefs.dockIcon = .never
                Toast.show("Forma reste dans la barre des menus", symbol: "menubar.arrow.up.rectangle")
            }
        }
        return menu
    }
}
