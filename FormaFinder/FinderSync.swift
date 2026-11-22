import Cocoa
import FinderSync

/// Finder context menu, window-background menu and toolbar button.
///
/// The extension is sandboxed and converts nothing itself: each click becomes an `ExternalRequest` written to the
/// App Group inbox, and Forma (launched in the background if needed) does the work.
///
/// Finder keeps only the title, image, tag, state and submenu of each `NSMenuItem`; every action lands on
/// `run(_:)` and the tag indexes `actions`, rebuilt each time a menu is requested.
final class FinderSync: FIFinderSync {
    private let reader = MenuConfigStore.Reader()
    private var actions: [MenuEntry] = []
    private var menuSelection: [URL] = []
    private var menuContainer: URL?
    private var volumeObserver: NSObjectProtocol?

    override init() {
        super.init()
        updateDirectories()
        let nc = NSWorkspace.shared.notificationCenter
        volumeObserver = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateDirectories()
        }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<FinderSync>.fromOpaque(obs).takeUnretainedValue().reader.invalidate()
        }, GroupContainer.menuChangedNotification as CFString, nil, .deliverImmediately)
    }

    /// The whole disk plus every mounted volume (external disks are not under "/" for Finder Sync).
    private func updateDirectories() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            urls.insert(v)
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: Toolbar

    override var toolbarItemName: String { "Forma" }
    override var toolbarItemToolTip: String { "Convertir ou compresser la sélection avec Forma" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: "Forma") ?? NSImage()
    }

    // MARK: Menus

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let place: MenuPlace
        switch menuKind {
        case .contextualMenuForItems: place = .items
        case .contextualMenuForContainer: place = .container
        case .contextualMenuForSidebar: place = .sidebar
        case .toolbarItemMenu: place = .toolbar
        @unknown default: return nil
        }
        let config = reader.config
        let summary = MenuBuilder.summarize(place == .container ? [] : selection)
        let nodes = MenuBuilder.build(summary, config: config, place: place)
        guard !nodes.isEmpty else { return nil }

        actions.removeAll(keepingCapacity: true)
        menuSelection = selection
        menuContainer = controller.targetedURL()
        let menu = NSMenu(title: "Forma")
        for node in nodes { add(node, to: menu, icons: config.showIcons) }
        return menu
    }

    private func add(_ node: MenuNode, to menu: NSMenu, icons: Bool) {
        switch node {
        case .separator:
            menu.addItem(.separator())
        case .header(let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .item(let title, let symbol, let entry):
            let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
            item.tag = actions.count
            actions.append(entry)
            if icons, let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        case .submenu(let title, let symbol, let children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if icons, let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            let sub = NSMenu(title: title)
            for c in children { add(c, to: sub, icons: icons) }
            item.submenu = sub
            menu.addItem(item)
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        let entry = actions[sender.tag]
        let controller = FIFinderSyncController.default()
        var urls: [URL]
        if entry.usesContainer {
            urls = (controller.targetedURL() ?? menuContainer).map { [$0] } ?? []
        } else {
            urls = controller.selectedItemURLs() ?? []
            if urls.isEmpty { urls = menuSelection }
        }
        let needsFiles: Set<RequestAction> = [.process, .recipe, .open, .watch, .upload]
        if needsFiles.contains(entry.action), urls.isEmpty { NSSound.beep(); return }
        let request = MenuBuilder.request(for: entry, paths: urls.map(\.path), source: .finder)
        do {
            try GroupContainer.submit(request, hostApp: GroupContainer.hostAppURL())
        } catch {
            NSLog("FormaFinder: \(error.localizedDescription)")
            NSSound.beep()
        }
    }
}
