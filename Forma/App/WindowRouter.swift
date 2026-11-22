import AppKit
import SwiftUI

/// Owns Forma's windows (main, history, Drop uploads, settings).
///
/// They used to be SwiftUI `Window` / `Settings` scenes, opened through an `openWindow` action captured by a view
/// inside the main window. After a headless launch (Finder menu, Share, Services) that view had never existed,
/// so a click on the Dock icon turned Forma into a regular app with nothing to show. Windows created here can be
/// opened from anywhere, at any time, and keep their content (file list, scroll position) when closed.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    static let shared = WindowRouter()

    enum Kind: String, CaseIterable {
        case main, history, drop

        var title: String {
            switch self {
            case .main: "Forma"
            case .history: "Historique"
            case .drop: "Envois Drop"
            }
        }
        var defaultSize: NSSize {
            switch self {
            case .main: NSSize(width: 980, height: 660)
            case .history: NSSize(width: 820, height: 640)
            case .drop: NSSize(width: 640, height: 480)
            }
        }
        var minSize: NSSize {
            switch self {
            case .main: NSSize(width: 760, height: 520)
            case .history: NSSize(width: 620, height: 420)
            case .drop: NSSize(width: 520, height: 360)
            }
        }
    }

    private var windows: [Kind: NSWindow] = [:]
    private var settings: SettingsWindowController?

    override private init() {
        super.init()
        observeAppearance()
    }

    // MARK: Showing

    func show(_ kind: Kind) {
        let window = self.window(kind)
        present(window)
    }

    func showSettings(tab: SettingsNavigation.Tab? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
        let controller = settings ?? SettingsWindowController()
        settings = controller
        controller.select(SettingsNavigation.shared.tab)
        present(controller.window!)
    }

    /// Global shortcut / Dock: show the main window, or hide Forma if it is already what the user is looking at.
    func toggleMain() {
        if NSApp.isActive, let w = windows[.main], w.isKeyWindow, w.isVisible {
            NSApp.hide(nil)
        } else {
            show(.main)
        }
    }

    func isVisible(_ kind: Kind) -> Bool { windows[kind]?.isVisible == true }

    private func present(_ window: NSWindow) {
        MenuBarController.shared.close(animated: false)
        LaunchContext.becomeInteractive()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        if NSApp.activationPolicy() == .accessory {
            // Without a Dock icon, cooperative activation is usually declined: the window would open unfocused.
            NSRunningApplication.current.activate(from: NSWorkspace.shared.frontmostApplication ?? .current, options: [])
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate()
        }
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14: if it was refused (launched from another app's extension),
        // the window must still come forward rather than open behind everything.
        if !NSApp.isActive { window.orderFrontRegardless() }
        LaunchContext.updateDockPolicy()
    }

    // MARK: Building

    private func window(_ kind: Kind) -> NSWindow {
        if let w = windows[kind] { return w }
        let model = AppModel.shared
        let store = PreferencesStore.shared
        let root: AnyView = switch kind {
        case .main: AnyView(MainView().environment(model).environment(store))
        case .history: AnyView(HistoryView().environment(model).environment(store))
        case .drop: AnyView(DropWindowView().environment(store))
        }
        let host = NSHostingController(rootView: root.frame(minWidth: kind.minSize.width, minHeight: kind.minSize.height))
        host.sceneBridgingOptions = [.toolbars]

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: kind.defaultSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        w.title = kind.title
        w.toolbarStyle = .unified
        w.titleVisibility = kind == .main ? .hidden : .visible
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentMinSize = kind.minSize
        // Listed by the Fenêtre menu commands instead (with their shortcuts), so they don't appear twice.
        w.isExcludedFromWindowsMenu = true
        w.delegate = self
        w.appearance = Self.appearance
        w.setContentSize(kind.defaultSize)
        w.center()
        // Restores the size and position of the last session (and saves them from now on).
        w.setFrameAutosaveName("Forma.\(kind.rawValue)")
        windows[kind] = w
        return w
    }

    // MARK: Appearance (Settings › Général › Apparence)

    static var appearance: NSAppearance? {
        switch PreferencesStore.shared.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func observeAppearance() {
        let appearance = withObservationTracking { Self.appearance } onChange: {
            DispatchQueue.main.async { WindowRouter.shared.observeAppearance() }
        }
        for w in windows.values { w.appearance = appearance }
        settings?.window?.appearance = appearance
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The Dock icon (in "only while a window is open" mode) goes away once the window is really gone.
        DispatchQueue.main.async { LaunchContext.updateDockPolicy() }
    }
}

// MARK: - Settings window

/// Native preferences window: toolbar tabs (NSTabViewController), one SwiftUI page per tab.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 820, height: 620)
    private let tabs = SettingsTabsController()

    init() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: w)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for page in SettingsPage.all {
            let host = NSHostingController(rootView: page.content
                .environment(AppModel.shared)
                .environment(PreferencesStore.shared)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height))
            host.sizingOptions = []
            host.preferredContentSize = Self.contentSize
            let item = NSTabViewItem(viewController: host)
            item.identifier = page.tab.rawValue
            item.label = page.label
            item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.label)
            tabs.addTabViewItem(item)
        }
        w.contentViewController = tabs
        w.toolbarStyle = .preference
        w.identifier = NSUserInterfaceItemIdentifier("settings")
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.isExcludedFromWindowsMenu = false
        w.appearance = WindowRouter.appearance
        w.delegate = self
        w.setContentSize(Self.contentSize)
        w.center()
        w.setFrameAutosaveName("Forma.settings")
        select(SettingsNavigation.shared.tab)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: SettingsNavigation.Tab) {
        guard let i = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == tab.rawValue }) else { return }
        if tabs.selectedTabViewItemIndex != i { tabs.selectedTabViewItemIndex = i }
        window?.title = tabs.tabViewItems[i].label
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { LaunchContext.updateDockPolicy() }
    }
}

private final class SettingsTabsController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        guard let item, let raw = item.identifier as? String, let tab = SettingsNavigation.Tab(rawValue: raw) else { return }
        view.window?.title = item.label
        if SettingsNavigation.shared.tab != tab { SettingsNavigation.shared.tab = tab }
    }
}
