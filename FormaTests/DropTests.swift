import Foundation
import Testing

private func files(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/forma-tests/\($0)") } }

private func menuConfig(drop: Bool, finder: Bool = true) -> MenuConfig {
    var c = MenuConfig()
    if drop { c.drop = DropMenuConfig(finder: finder, share: true, expiry: .never, host: "drop.example.com") }
    return c
}

private func titles(_ nodes: [MenuNode]) -> [String] { nodes.flatMap { $0.entries }.map { $0.path.joined(separator: " › ") } }

@Suite("Drop · liens")
struct DropLinkTests {
    let base = URL(string: "https://drop.example.com")!

    @Test func linkEncodesLikeTheDashboard() {
        #expect(DropLinks.url(base: base, key: "Ab3dEf/Capture d'écran (1).png", style: .page)
                == "https://drop.example.com/Ab3dEf/Capture%20d'%C3%A9cran%20(1).png")
        #expect(DropLinks.url(base: base, key: "x/a b.png", style: .direct) == "https://drop.example.com/x/a%20b.png?raw")
    }

    @Test func keyIsRecoveredFromAnyShapeOfLink() {
        #expect(DropLinks.key(from: "https://drop.example.com/Ab3dEf/photo%20un.png?raw", base: base) == "Ab3dEf/photo un.png")
        #expect(DropLinks.key(from: "https://drop.example.com/v/Ab3dEf/photo.png", base: base) == "Ab3dEf/photo.png")
        #expect(DropLinks.key(from: "Ab3dEf/photo.png", base: base) == "Ab3dEf/photo.png")
    }

    @Test func expiryParsing() {
        #expect(DropExpiry.parse("7d") == .week)
        #expect(DropExpiry.parse("never") == .never)
        #expect(DropExpiry.parse("24h") == .day)
        #expect(DropExpiry.parse("bientôt") == nil)
        #expect(DropExpiry.day.seconds == 86_400)
        #expect(DropExpiry.never.seconds == nil)
    }
}

@Suite("Drop · requêtes")
struct DropRequestTests {
    @Test func uploadRequestSurvivesTheInbox() throws {
        var r = ExternalRequest(source: .finder, action: .upload, paths: ["/tmp/a.zip"])
        r.drop = DropOptions(expiry: .week, copyLink: false)
        let back = try RequestCodec.decode(RequestCodec.encode(r))
        #expect(back.action == .upload)
        #expect(back.drop == DropOptions(expiry: .week, copyLink: false))
    }

    @Test func requestWrittenBeforeDropStillDecodes() throws {
        let old = #"{"id":"6F0A1E2B-0001-4F6D-9A3B-7C1E5D2A9B01","date":"2026-11-15T10:00:00Z","source":"finder","action":"process","mode":"convert","paths":["/tmp/a.png"]}"#
        let r = try RequestCodec.decode(Data(old.utf8))
        #expect(r.drop == nil)
    }

    @Test func oldMenuJSONStillDecodes() throws {
        // A menu.json written by Forma 1.3 has neither `drop` nor `sendsToDrop`.
        var c = MenuConfig()
        c.recipes = [RecipeSummary(id: UUID(), name: "Web", symbol: "globe", mode: .convert, kinds: [.image], showInFinder: true, showInShare: true)]
        let data = try #require(MenuConfigStore.encode(c))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["drop"] = nil
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let back = try #require(MenuConfigStore.decode(stripped))
        #expect(back.drop == nil)
        #expect(back.recipes.first?.sendsToDrop == nil)
    }
}

@Suite("Drop · menu du Finder")
struct DropMenuTests {
    private func menu(_ urls: [URL], _ config: MenuConfig, place: MenuPlace = .items) -> [MenuNode] {
        MenuBuilder.build(MenuBuilder.summarize(urls), config: config, place: place)
    }

    @Test func nothingChangesUntilDropIsConfigured() {
        #expect(!titles(menu(files("a.jpg"), menuConfig(drop: false))).contains { $0.contains("Drop") })
        #expect(menu(files("archive.zip"), menuConfig(drop: false)).isEmpty)
    }

    @Test func imageGetsSendAndCompressAndSend() {
        let t = titles(menu(files("a.jpg"), menuConfig(drop: true)))
        #expect(t.contains("Forma › Envoyer sur Drop"))
        #expect(t.contains("Forma › Compresser et envoyer sur Drop"))
        #expect(t.contains("Forma › Envoyer sur Drop, expire dans… › 7 jours"))
    }

    @Test func anyFileTypeCanBeSent() {
        let nodes = menu(files("archive.zip", "notes"), menuConfig(drop: true))
        let t = titles(nodes)
        #expect(t.contains("Forma › Envoyer la sélection sur Drop"))
        #expect(!t.contains { $0.contains("Convertir") })
        let entry = nodes.flatMap { $0.entries }.first { $0.entry.action == .upload }?.entry
        #expect(entry?.drop == DropOptions())
    }

    @Test func foldersAreSentAsZip() {
        let folder = URL(fileURLWithPath: "/tmp/forma-tests/Projet", isDirectory: true)
        #expect(titles(menu([folder], menuConfig(drop: true))).contains("Forma › Envoyer le dossier sur Drop"))
        #expect(titles(menu([], menuConfig(drop: true), place: .container)).contains("Forma › Envoyer ce dossier sur Drop"))
    }

    @Test func hiddenWhenDisabledForTheFinder() {
        #expect(menu(files("archive.zip"), menuConfig(drop: true, finder: false)).isEmpty)
    }

    @Test func menuEntryBecomesAnUploadRequest() {
        let entry = MenuEntry(action: .upload, drop: DropOptions(expiry: .hour))
        let r = MenuBuilder.request(for: entry, paths: ["/tmp/a.zip"], source: .finder)
        #expect(r.action == .upload)
        #expect(r.drop?.expiry == .hour)
    }
}
