import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// UI state shared between the status item and the panel content.
@MainActor
@Observable
final class MenuBarState {
    var isOpen = false
    /// Pinned: the panel ignores outside clicks and stays on screen (a drop shelf).
    var isPinned = false
    /// A file drag is in progress somewhere on screen while the panel is open.
    var fileDragActive = false
    /// Files are being dragged over the menu bar icon itself.
    var iconTargeted = false
    /// Short confirmation shown under the drop tiles ("3 fichiers ajoutés…").
    var notice: Notice?

    struct Notice: Equatable {
        let id = UUID()
        var text: String
        var symbol: String
        var isError = false
    }
}

/// Menu bar item + drop panel.
///
/// Replaces `MenuBarExtra(.window)`, whose window closes as soon as Forma resigns key — which is exactly
/// what happens when you click in the Finder to pick up a file. Here the panel is a non-activating
/// `NSPanel`: it never steals focus from the Finder, survives the click that starts a drag, and only
/// closes on a real click elsewhere (mouse released without dragging), Escape, a Space change, or the icon.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    let state = MenuBarState()
    static let width: CGFloat = 360

    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?

    private var outsideClickPending = false
    private var mouseDownPoint = NSPoint.zero
    private var dragChangeCount = 0
    private var dragPollTimer: Timer?
    private var clickPollTimer: Timer?
    /// Opened by hovering a drag over the icon: closes again if the drag ends without a drop.
    private var springLoaded = false
    private var droppedDuringDrag = false
    private var noticeWork: DispatchWorkItem?
    private var lastIconKey = ""
    /// Height reported by the SwiftUI content (can arrive before the panel exists).
    private var contentHeight: CGFloat = 0

    // MARK: Install / visibility

    func install() {
        observeVisibility()
        observeIcon()
    }

    private func observeVisibility() {
        let visible = withObservationTracking { PreferencesStore.shared.menuBarVisible } onChange: {
            DispatchQueue.main.async { MenuBarController.shared.observeVisibility() }
        }
        visible ? showStatusItem() : removeStatusItem()
    }

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "com.thibault.forma.status"
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "Forma — cliquez, ou déposez des fichiers sur l'icône"
            button.setAccessibilityLabel("Forma")
            // The status bar window forwards NSDraggingDestination calls to its delegate.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        statusItem = item
        lastIconKey = ""
        refreshIcon()
    }

    private func removeStatusItem() {
        close(animated: false)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    // MARK: Icon

    private func observeIcon() {
        withObservationTracking {
            refreshIcon()
        } onChange: {
            DispatchQueue.main.async { MenuBarController.shared.observeIcon() }
        }
    }

    private func refreshIcon() {
        let model = AppModel.shared
        let running = model.isRunning
        let progress = running ? model.overallProgress : 0
        let steps = Int((progress * 60).rounded())
        let key = "\(running)-\(model.isPaused)-\(steps)-\(state.iconTargeted)"
        guard let button = statusItem?.button, key != lastIconKey else { return }
        lastIconKey = key
        button.image = StatusIcon.make(running: running, paused: model.isPaused, progress: Double(steps) / 60,
                                       targeted: state.iconTargeted)
        button.setAccessibilityValue(running ? "\(Int(progress * 100)) %" : nil)
    }

    // MARK: Clicks on the icon

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showContextMenu(from: sender)
        } else if event?.modifierFlags.contains(.option) == true {
            close(animated: false)
            AppDelegate.showMainWindow()
        } else {
            toggle()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        close(animated: false)
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, key: String = "", _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Ouvrir Forma", "macwindow") { AppDelegate.showMainWindow() }
        add("Historique", "clock.arrow.circlepath") { AppDelegate.showHistory() }
        add("Réglages…", "gearshape", key: ",") { AppDelegate.showSettings() }
        menu.addItem(.separator())
        let undo = ClosureMenuItem(title: "Annuler le dernier traitement", keyEquivalent: "") { HistoryModel.shared.undoLastBatch() }
        undo.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        undo.isEnabled = !HistoryModel.shared.lastUndoableBatch.isEmpty
        menu.autoenablesItems = false
        menu.addItem(undo)
        menu.addItem(.separator())
        add("Quitter Forma", "power", key: "q") { NSApp.terminate(nil) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    // MARK: Open / close

    func toggle() { state.isOpen ? close() : open() }

    func open(animated: Bool = true) {
        guard let button = statusItem?.button, let anchor = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.appearance = Self.appearance
        if state.isOpen {
            panel.makeKey()
            return
        }
        state.isOpen = true
        let target = frame(for: panel, below: anchor.frame, height: contentHeight > 1 ? contentHeight : nil)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated {
            panel.alphaValue = 0
            panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: 8), display: false)
        } else {
            panel.alphaValue = 1
            panel.setFrame(target, display: false)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        installMonitors()
    }

    func close(animated: Bool = true) {
        guard state.isOpen, let panel else { return }
        state.isOpen = false
        state.fileDragActive = false
        springLoaded = false
        removeMonitors()
        statusItem?.button?.highlight(false)
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !MenuBarController.shared.state.isOpen { panel.orderOut(nil) }
            }
        })
    }

    private static var appearance: NSAppearance? {
        switch PreferencesStore.shared.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func makePanel() -> MenuBarPanel {
        let panel = MenuBarPanel()
        panel.onCancel = { MenuBarController.shared.close() }

        let root = MenuBarView()
            .environment(AppModel.shared)
            .environment(PreferencesStore.shared)
            .environment(state)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                MenuBarController.shared.contentHeightChanged(h)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []

        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        glass.contentView = host
        panel.contentView = glass

        host.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: Self.width, height: max(contentHeight, 200)))
        return panel
    }

    /// Keeps the panel's top edge pinned under the menu bar as sections appear and disappear.
    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 1 else { return }
        contentHeight = ceil(height)
        guard let panel else { return }
        let h = ceil(height)
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        if let anchor = statusItem?.button?.window, state.isOpen {
            let target = frame(for: panel, below: anchor.frame, height: h)
            f = target
        } else {
            f.origin.y += f.height - h
            f.size.height = h
        }
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    private func frame(for panel: NSPanel, below anchor: NSRect, height: CGFloat? = nil) -> NSRect {
        let size = NSSize(width: Self.width, height: height ?? panel.frame.height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY, visible.maxY) - 6
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    // MARK: Outside clicks & drag tracking

    private func installMonitors() {
        removeMonitors()
        dragChangeCount = NSPasteboard(name: .drag).changeCount

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { e in
            let type = e.type
            MainActor.assumeIsolated { MenuBarController.shared.globalMouseDown(type) }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { _ in
            MainActor.assumeIsolated { MenuBarController.shared.globalMouseDragged() }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in
            MainActor.assumeIsolated { MenuBarController.shared.globalMouseUp() }
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            MainActor.assumeIsolated { MenuBarController.shared.localMouseDown(e) }
            return e
        }) { monitors.append(m) }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = MenuBarController.shared
                if !c.state.isPinned { c.close(animated: false) }
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        spaceObserver = nil
        dragPollTimer?.invalidate()
        dragPollTimer = nil
        clickPollTimer?.invalidate()
        clickPollTimer = nil
        outsideClickPending = false
    }

    /// A click in another app. We don't close yet: if it turns into a drag, the user is probably
    /// bringing files to the panel. The decision is made when the button is released.
    private func globalMouseDown(_ type: NSEvent.EventType) {
        guard !state.isPinned else { return }
        guard type == .leftMouseDown, !isInMenuBar(NSEvent.mouseLocation) else { close(); return }
        outsideClickPending = true
        mouseDownPoint = NSEvent.mouseLocation
        // Some apps swallow the mouse-up (menus, drag sessions): poll the button as a fallback.
        clickPollTimer?.invalidate()
        clickPollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarController.shared.pollOutsideClick() }
        }
    }

    private func pollOutsideClick() {
        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != dragChangeCount {
            // A drag started from that click: keep the panel, it is probably the destination.
            dragChangeCount = pb.changeCount
            outsideClickPending = false
            if pb.types?.contains(.fileURL) == true { beginFileDrag() }
        }
        guard outsideClickPending else { clickPollTimer?.invalidate(); clickPollTimer = nil; return }
        if NSEvent.pressedMouseButtons & 1 == 0 { globalMouseUp() }
    }

    /// Clicking another menu bar item opens a menu that tracks the mouse itself: close right away.
    private func isInMenuBar(_ p: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return false }
        return p.y >= screen.visibleFrame.maxY && screen.frame.maxY > screen.visibleFrame.maxY
    }

    private func globalMouseDragged() {
        if outsideClickPending, hypot(NSEvent.mouseLocation.x - mouseDownPoint.x, NSEvent.mouseLocation.y - mouseDownPoint.y) > 3 {
            outsideClickPending = false
        }
        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != dragChangeCount {
            dragChangeCount = pb.changeCount
            if pb.types?.contains(.fileURL) == true { beginFileDrag() }
        }
    }

    private func globalMouseUp() {
        clickPollTimer?.invalidate()
        clickPollTimer = nil
        if outsideClickPending {
            outsideClickPending = false
            close()
        }
    }

    private func localMouseDown(_ e: NSEvent) {
        guard state.isOpen, !state.isPinned, let window = e.window else { return }
        if window === panel || window === statusItem?.button?.window { return }
        // Menus, pop-ups and tooltips opened from the panel live in their own windows.
        if window.level.rawValue > NSWindow.Level.statusBar.rawValue || window.parent === panel { return }
        close()
    }

    private func beginFileDrag() {
        guard !state.fileDragActive else { return }
        state.fileDragActive = true
        droppedDuringDrag = false
        // A drag session swallows mouse-up events: poll the button state instead.
        dragPollTimer?.invalidate()
        dragPollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                MenuBarController.shared.endFileDrag()
            }
        }
    }

    private func endFileDrag() {
        dragPollTimer?.invalidate()
        dragPollTimer = nil
        state.fileDragActive = false
        state.iconTargeted = false
        outsideClickPending = false
        if springLoaded {
            springLoaded = false
            // Opened just for this drag, which went elsewhere: get out of the way.
            if !droppedDuringDrag && !state.isPinned {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let c = MenuBarController.shared
                    guard let panel = c.panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
                    c.close()
                }
            }
        }
    }

    // MARK: Accepting files

    /// Adds dropped files to the given mode and starts processing right away.
    @discardableResult
    func accept(_ urls: [URL], mode: ProcessMode) -> Bool {
        droppedDuringDrag = true
        let files = urls.filter(\.isFileURL)
        let added = AppModel.shared.add(files, mode: mode, autoStart: true)
        if added == 0 {
            NSSound.beep()
            let reason = mode == .upscale ? "Aucune image à agrandir" : "Rien de nouveau à traiter"
            post(.init(text: reason, symbol: "exclamationmark.circle", isError: true))
            return false
        }
        let noun = added > 1 ? "\(added) fichiers ajoutés" : "1 fichier ajouté"
        post(.init(text: "\(noun) · \(mode.label)", symbol: "checkmark.circle.fill"))
        return true
    }

    /// Tile click: pick files with an open panel, then process them like a drop.
    func choose(mode: ProcessMode) {
        close(animated: false)
        NSApp.activate()
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = mode != .upscale
        picker.canChooseFiles = true
        if mode == .upscale { picker.allowedContentTypes = [.image] }
        picker.message = "Fichiers à \(mode.label.lowercased()) — le traitement démarre aussitôt"
        picker.prompt = mode.label
        guard picker.runModal() == .OK else { return }
        accept(picker.urls, mode: mode)
        open(animated: true)
    }

    private func post(_ notice: MenuBarState.Notice) {
        noticeWork?.cancel()
        state.notice = notice
        let w = DispatchWorkItem { MainActor.assumeIsolated { MenuBarController.shared.state.notice = nil } }
        noticeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
}

// MARK: - Drops on the menu bar icon

extension MenuBarController: NSWindowDelegate, NSDraggingDestination {
    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.fileURL) == true else { return [] }
        state.iconTargeted = true
        if !state.isOpen {
            springLoaded = true
            open()
        }
        dragChangeCount = sender.draggingPasteboard.changeCount
        beginFileDrag()
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : []
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        state.iconTargeted = false
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !fileURLs(sender).isEmpty }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        state.iconTargeted = false
        return accept(fileURLs(sender), mode: AppModel.shared.mode)
    }
}

// MARK: - Panel window

final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: MenuBarController.width, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityLabel("Forma")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Status icon

enum StatusIcon {
    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// Template image: the regular glyph, a drop tray while files hover it, or a progress ring while working.
    static func make(running: Bool, paused: Bool, progress: Double, targeted: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            func drawCentered(_ img: NSImage?) {
                guard let img else { return }
                let s = img.size
                img.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            if targeted {
                drawCentered(symbol("tray.and.arrow.down.fill", size: 14, weight: .medium))
            } else if running {
                let ring = rect.insetBy(dx: 1.6, dy: 1.6)
                let track = NSBezierPath(ovalIn: ring)
                track.lineWidth = 1.8
                NSColor.black.withAlphaComponent(0.28).setStroke()
                track.stroke()
                let p = max(0.04, min(1, progress))
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
                drawCentered(symbol(paused ? "pause.fill" : "arrow.down", size: 7.5, weight: .bold))
            } else {
                drawCentered(symbol("arrow.triangle.2.circlepath.circle", size: 15))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// NSMenuItem running a closure (for the right-click menu).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, keyEquivalent: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
