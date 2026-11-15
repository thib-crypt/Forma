import Foundation
import Testing

private func files(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/forma-tests/\($0)") } }
private func folder(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/forma-tests/\(name)", isDirectory: true) }

private func menu(_ urls: [URL], _ config: MenuConfig = MenuConfig(), place: MenuPlace = .items) -> [MenuNode] {
    MenuBuilder.build(MenuBuilder.summarize(urls), config: config, place: place)
}

/// Every actionable entry, flattened: "Forma › Convertir en WebP".
private func entries(_ nodes: [MenuNode]) -> [(title: String, entry: MenuEntry)] {
    nodes.flatMap { $0.entries }.map { ($0.path.joined(separator: " › "), $0.entry) }
}

private func titles(_ nodes: [MenuNode]) -> [String] { entries(nodes).map(\.title) }

@Suite("Menu du Finder")
struct MenuBuilderTests {

    @Test func singleImageKindOffersFavouritesWithoutItsOwnFormat() {
        let t = titles(menu(files("a.jpg", "b.jpeg")))
        #expect(t.contains("Forma › Convertir en WebP"))
        #expect(t.contains("Forma › Convertir en PNG"))
        #expect(!t.contains("Forma › Convertir en JPEG"))       // already JPEG
        #expect(t.contains("Forma › Convertir en… › Populaires ›") == false)
        #expect(t.contains("Forma › Convertir en… › Modernes › JPEG XL"))
        #expect(t.contains("Forma › Compresser · Équilibré"))
        #expect(t.contains("Forma › Agrandir ×2 (IA)"))
        #expect(t.filter { $0.hasPrefix("Forma › Compresser avec… ›") }.count == 6)
    }

    @Test func unsupportedSelectionShowsNoMenu() {
        #expect(menu(files("archive.zip", "notes")).isEmpty)
    }

    @Test func disabledConfigShowsNoMenu() {
        var c = MenuConfig(); c.enabled = false
        #expect(menu(files("a.png"), c).isEmpty)
    }

    @Test func mixedSelectionGetsOneSectionPerKind() {
        let e = entries(menu(files("a.png", "b.mov", "c.mp3")))
        let image = e.first { $0.title == "Forma › 1 image → WebP" }
        #expect(image?.entry.kinds == [.image])
        #expect(image?.entry.target == "WEBP")
        #expect(e.contains { $0.title == "Forma › 1 vidéo → MP4" && $0.entry.kinds == [.video] })
        #expect(e.contains { $0.title == "Forma › 1 audio → MP3" })
        #expect(e.contains { $0.title == "Forma › Convertir chaque type avec ses réglages par défaut" && $0.entry.target == nil })
        #expect(e.contains { $0.title == "Forma › Agrandir les images ×2 (IA)" && $0.entry.kinds == [.image] })
        #expect(!e.contains { $0.title == "Forma › Agrandir ×2 (IA)" })
    }

    @Test func videoAndAudioHaveNoUpscale() {
        let t = titles(menu(files("clip.mov")))
        #expect(t.contains("Forma › Convertir en MP4"))
        #expect(!t.contains { $0.contains("Agrandir") })
        #expect(!t.contains { $0.contains("Compresser avec") })
    }

    @Test func folderEntriesFilterByKind() {
        let e = entries(menu([folder("Photos")]))
        let webp = e.first { $0.title == "Forma › Convertir les images du dossier en › WebP" }
        #expect(webp?.entry.kinds == [.image])
        #expect(webp?.entry.recursive == nil)
        #expect(e.contains { $0.title == "Forma › Surveiller ce dossier avec Forma…" && $0.entry.action == .watch })
        #expect(e.contains { $0.title.hasPrefix("Forma › Convertir les vidéos du dossier en") })
    }

    @Test func windowBackgroundActsOnTheFolderNonRecursively() {
        let e = entries(menu([], place: .container))
        #expect(!e.isEmpty)
        #expect(e.allSatisfy { $0.entry.usesContainer })
        #expect(e.filter { $0.entry.action == .process }.allSatisfy { $0.entry.recursive == false })
        #expect(!e.contains { $0.entry.action == .open })
        #expect(e.contains { $0.title.contains("de ce dossier") })
    }

    @Test func toolbarMenuAlwaysHasAppEntries() {
        let t = titles(menu([], place: .toolbar))
        #expect(t == ["Optimiser le presse-papiers", "Ouvrir Forma", "Réglages du menu Finder…"])
    }

    @Test func packagesAreDocumentsNotFolders() {
        let s = MenuBuilder.summarize([folder("Lettre.rtfd"), folder("Budget.numbers")])
        #expect(s.folders == 0)
        #expect(s.counts[.office] == 2)
    }

    @Test func officeOutputsDependOnTheFamilyAndLibreOffice() {
        let text = titles(menu(files("rapport.docx")))
        #expect(text.contains("Forma › Convertir en PDF"))
        #expect(!text.contains { $0.contains("Excel") })
        #expect(text.contains("Forma › Compresser"))           // DOCX is a ZIP package

        let md = titles(menu(files("notes.md")))
        #expect(!md.contains("Forma › Compresser"))

        var lo = MenuConfig(); lo.libreOffice = false
        let sheet = titles(menu(files("budget.xls"), lo))
        #expect(!sheet.contains { $0.contains("Convertir en") })   // only LibreOffice reads .xls
        lo.libreOffice = true
        #expect(titles(menu(files("budget.xls"), lo)).contains("Forma › Convertir en… › Tableurs › CSV"))
    }

    @Test func favouritesAndHabitsDriveTheTopEntries() {
        var c = MenuConfig()
        c.favorites[MediaKind.image.rawValue] = ["AVIF"]
        c.ranked[MediaKind.image.rawValue] = ["HEIC"]
        let top = titles(menu(files("a.png"), c)).filter { $0.hasPrefix("Forma › Convertir en ") && !$0.contains("…") }
        #expect(top.first == "Forma › Convertir en HEIC")
        #expect(top.contains("Forma › Convertir en AVIF"))
        c.rankByHabits = false
        let noHabits = titles(menu(files("a.png"), c)).filter { $0.hasPrefix("Forma › Convertir en ") && !$0.contains("…") }
        #expect(!noHabits.contains("Forma › Convertir en HEIC"))
    }

    @Test func favouritesCanBePromotedOutOfTheSubmenu() {
        var c = MenuConfig(); c.topLevelCount = 2
        let root = menu(files("a.heic"), c)
        #expect(root.count == 3)
        #expect(root.first?.title == "Forma : convertir en JPEG")
        #expect(root.last?.title == "Forma")
        // Never for mixed selections.
        #expect(menu(files("a.heic", "b.mov"), c).count == 1)
    }

    @Test func recipesAppearForTheKindsTheyAccept() {
        var c = MenuConfig()
        let web = RecipeSummary(id: UUID(), name: "Web", symbol: "globe", mode: .convert, kinds: [.image], showInFinder: true, showInShare: true)
        let hidden = RecipeSummary(id: UUID(), name: "Caché", symbol: "eye.slash", mode: .convert, kinds: [], showInFinder: false, showInShare: true)
        c.recipes = [web, hidden]
        let onImage = entries(menu(files("a.png"), c))
        #expect(onImage.contains { $0.title == "Forma › Web" && $0.entry.recipe == web.id && $0.entry.action == .recipe })
        #expect(!onImage.contains { $0.title.contains("Caché") })
        #expect(!titles(menu(files("a.mp3"), c)).contains("Forma › Web"))
    }

    @Test func undoEntryOnlyForRecentBatches() {
        var c = MenuConfig()
        let id = UUID()
        c.lastBatch = BatchSummary(id: id, title: "Conversion en WebP de 3 fichiers", date: Date(), count: 3)
        let e = entries(menu(files("a.png"), c))
        #expect(e.contains { $0.title == "Forma › Annuler « Conversion en WebP de 3 fichiers »" && $0.entry.batch == id })
        c.lastBatch?.date = Date().addingTimeInterval(-2 * 86_400)
        #expect(!titles(menu(files("a.png"), c)).contains { $0.contains("Annuler") })
    }

    @Test func bigSelectionsStayFast() {
        let many = (0..<5000).map { URL(fileURLWithPath: "/tmp/forma-tests/img\($0).\($0 % 2 == 0 ? "jpg" : "png")") }
        let t = Date()
        let s = MenuBuilder.summarize(many)
        _ = MenuBuilder.build(s, config: MenuConfig(), place: .items)
        #expect(Date().timeIntervalSince(t) < 0.25)
        #expect(s.truncated)
        #expect(s.scanned == MenuBuilder.maxScanned)
    }

    @Test func entriesBecomeRequests() {
        let entry = MenuEntry(action: .process, mode: .compress, preset: .webOptimized, recursive: false)
        let r = MenuBuilder.request(for: entry, paths: ["/a.png"], source: .finder)
        #expect(r.source == .finder)
        #expect(r.mode == .compress)
        #expect(r.overrides?.preset == .webOptimized)
        #expect(r.recursive == false)
        #expect(r.paths == ["/a.png"])
    }
}

@Suite("Demandes et configuration")
struct CodecTests {
    @Test func requestRoundTrips() throws {
        var r = ExternalRequest(source: .share, action: .process, mode: .convert, target: "WEBP", paths: ["/x/a.heic", "/x/b.png"])
        r.kinds = [.image, .document]
        r.overrides = RequestOverrides(preset: .socialMedia, quality: 70, maxDimension: 1600, metadata: .stripAll)
        r.destination = .folder("/Users/me/Downloads")
        r.stagedDirectory = "/tmp/inbox/files"
        r.reveal = true
        let back = try RequestCodec.decode(RequestCodec.encode(r))
        #expect(back.id == r.id)
        #expect(back.kinds == r.kinds)
        #expect(back.overrides == r.overrides)
        #expect(back.destination == .folder("/Users/me/Downloads"))
        #expect(back.paths == r.paths)
        #expect(abs(back.date.timeIntervalSince(r.date)) < 1)
    }

    @Test func allDestinationsRoundTrip() throws {
        for d in [RequestDestination.standard, .alongside, .clipboard, .folder("/tmp")] {
            var r = ExternalRequest(source: .finder)
            r.destination = d
            #expect(try RequestCodec.decode(RequestCodec.encode(r)).destination == d)
        }
    }

    @Test func menuConfigRoundTrips() throws {
        var c = MenuConfig()
        c.topLevelCount = 2
        c.recipes = [RecipeSummary(id: UUID(), name: "Web", symbol: "globe", mode: .convert, kinds: [.image], showInFinder: true, showInShare: false)]
        c.lastBatch = BatchSummary(id: UUID(), title: "T", date: Date(), count: 2)
        let data = try #require(MenuConfigStore.encode(c))
        let back = try #require(MenuConfigStore.decode(data))
        #expect(back.topLevelCount == 2)
        #expect(back.recipes == c.recipes)
        #expect(back.lastBatch?.id == c.lastBatch?.id)
    }

    @Test func hostAppIsFoundFromTheExtensionBundle() {
        let ext = Bundle(path: "/Applications/Forma.app/Contents/PlugIns/FormaFinder.appex")
        if let ext { #expect(GroupContainer.hostAppURL(of: ext)?.path == "/Applications/Forma.app") }
    }
}
