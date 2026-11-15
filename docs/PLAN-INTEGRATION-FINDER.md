# Forma — Intégration Finder & Partage

Plan d'implémentation · rédigé le 15/11/2026 · cible : Forma 1.3 · macOS 27.0.1, Xcode 27

Objectif : clic droit sur des fichiers dans le Finder → **Forma ▸ Convertir en WebP**, et la conversion se fait
sans qu'aucune fenêtre de Forma ne s'ouvre. Même chose depuis le menu **Partager** de n'importe quelle app.

---

## 1. Ce que l'analyse du code a montré

### Ce qui existe déjà et sera réutilisé tel quel

| Brique | Où | Intérêt pour ce chantier |
|---|---|---|
| `Pipeline.run(input:mode:snapshot:targetOverride:outputFolder:origin:batch:)` | `Forma/Engines/Pipeline.swift` | Point d'entrée unique, sans dépendance à l'UI. Historique et corbeille déjà gérés dedans. |
| `Core/` et `Engines/` | — | Aucune référence à `AppModel`, `MenuBarController`, `Toast` ou `NSApp` : partageables avec d'autres cibles. |
| `FormatCatalog.outputs(for:)`, `FileDetection.classify` | `Forma/Core/Formats.swift` | Savent déjà quels formats proposer pour quel fichier, par simple extension (aucune E/S). C'est exactement ce qu'il faut pour construire un menu vite. |
| `PreferencesStore.loadSnapshot()` | `Forma/Core/Settings.swift:646` | Lecture des réglages hors thread principal. |
| Historique SQLite partagé entre processus + `HistoryUndo` | `Forma/Core/History.swift` | « Annuler » depuis le Finder est quasi gratuit. |
| Anneau de progression dans l'icône de la barre des menus, résultats récents | `Forma/MenuBar/MenuBarController.swift:100-108` | Retour visuel déjà en place pour un travail en arrière-plan. |
| 4 services Finder (`NSServices`) | `project.yml`, `Forma/Services/Services.swift:68` | Restent utiles comme filet (voir §3.5). |

### Ce qui manque ou gêne

1. **Les services actuels ouvrent la fenêtre.** `ServicesProvider.handle` (`Services.swift:81`) appelle
   `AppDelegate.showMainWindow()` avant tout. C'est l'inverse du but recherché. Ils sont aussi statiques
   (4 entrées fixes, aucun choix de format) et rangés dans le sous-menu « Services ».
2. **La file de `AppModel` ne convient pas à des demandes externes.**
   - `start()` sort immédiatement si un lot tourne déjà (`AppModel.swift:140`). Une demande arrivée pendant un
     traitement ajoute des fichiers qui restent « en attente » pour toujours. Le dépôt sur l'icône de la barre
     des menus (`MenuBarController.accept`, ligne 417) a le même défaut aujourd'hui.
   - `start(mode:)` traite **tous** les fichiers en attente du mode, avec un seul format cible. Une demande
     « convertir en WebP » depuis le Finder embarquerait aussi les fichiers que tu préparais dans la fenêtre.
3. **Aucun schéma d'URL, aucune extension, aucun App Group.** L'app est signée ad hoc (`CODE_SIGN_IDENTITY: "-"`),
   ce qui interdit les App Groups et fait redemander les autorisations (Bureau, Documents…) à chaque build.
4. **`application(_:open:)`** (`FormaApp.swift:164`) traite toute URL comme un fichier à ajouter.
5. **L'app se lance toujours avec sa fenêtre** (`.defaultLaunchBehavior(.presented)`, `FormaApp.swift:30`) et
   reste dans le Dock.
6. Le dépôt a beaucoup de travail non commité (1.1 et 1.2 : historique, presse-papiers, barre des menus, documents).
   **À commiter avant de commencer**, ce chantier touche `project.yml`, la signature et `FormaApp.swift`.

### État de la machine (vérifié)

- Deux identités de signature valides dans le trousseau : `Developer ID Application … (PG46BWSK3T)` et
  `Apple Development`. Donc App Group possible, sans profil de provisionnement.
- Bureau et Documents ne sont **pas** dans iCloud Drive. OneDrive est installé (`~/Library/CloudStorage/OneDrive-Personnel`).
- Extensions Finder Sync déjà présentes : CleanMyMac (active), OneDrive. Elles cohabitent sans problème.
- Picmal n'embarque aucune extension : cette intégration irait plus loin que le modèle d'origine.

---

## 2. Choix techniques

### 2.1 Quel mécanisme pour le menu contextuel ?

| Mécanisme | Menu dynamique, sous-menus, icônes | Où ça apparaît | Verdict |
|---|---|---|---|
| **Extension Finder Sync** (`FIFinderSync`) | Oui | Premier niveau du menu contextuel, fond de fenêtre, barre latérale, bouton de barre d'outils | **Retenu** pour le menu principal |
| `NSServices` (existant) | Non, entrées figées dans l'Info.plist | Sous-menu Services / Actions rapides, raccourcis clavier assignables | **Conservé** en filet et pour les raccourcis clavier |
| **Extension de partage** | Interface libre | Menu Partager de toutes les apps | **Retenu** pour le partage |
| Raccourcis utilisés comme Action rapide | Non | Actions rapides, panneau d'aperçu | Déjà possible avec les intents existants, rien à coder |

Limites de Finder Sync à connaître :
- L'extension doit être en bac à sable. Elle ne convertit donc rien elle-même : elle transmet la demande à l'app.
- Il faut l'activer une fois (Réglages Système › Général › Ouverture et extensions › Extensions, ou `pluginkit -e use -i …`).
- Finder place les entrées dans la partie basse du menu ; l'ordre ne se choisit pas.
- Finder ne conserve d'un `NSMenuItem` que le titre, l'image, le `tag`, l'état et le sous-menu. `representedObject`
  et `target` sont perdus : toutes les actions arrivent sur la sous-classe `FIFinderSync`.
- Les menus n'apparaissent en principe pas dans les dossiers gérés par un File Provider (iCloud Drive, OneDrive).
  **À vérifier pendant le spike.** C'est là que les services servent de filet.
- Pas de menu dans les panneaux Ouvrir/Enregistrer.

### 2.2 Qui fait le travail ?

**L'app principale, en mode discret.** Un seul processus moteur : il réutilise la barre des menus, l'historique,
les notifications, et évite deux files concurrentes qui se disputeraient le processeur.

- Si Forma tourne déjà (cas courant avec la barre des menus), la demande est traitée en arrière-plan.
- Sinon Forma est lancée sans fenêtre et sans icône de Dock (`NSApp.setActivationPolicy(.accessory)` décidé dans
  `applicationWillFinishLaunching` d'après l'Apple Event de lancement), puis quitte une fois la file vide si
  l'option barre des menus est désactivée.

Alternative gardée en réserve si le spike montre un flash de fenêtre ou un rebond dans le Dock : un petit agent
`FormaAgent.app` (LSUIElement) embarqué dans le bundle, qui compile `Core/` + `Engines/`. Plus propre côté
lancement, mais deux processus et une cible de plus.

### 2.3 Communication extension → app

App Group `PG46BWSK3T.com.thibault.forma` (forme macOS préfixée par l'équipe : pas de profil requis).
Conteneur : `~/Library/Group Containers/PG46BWSK3T.com.thibault.forma/`.

```
 Finder ──clic──▶ FormaFinder.appex ──┐                         ┌─▶ HUD de progression
                  (bac à sable)       │  Inbox/<id>.json        │
                                      ├──────────────────▶ Forma.app ─▶ JobCenter ─▶ Pipeline.run
 App X ─Partager─▶ FormaShare.appex ──┘  + open forma://job/<id>│                        │
                  (bac à sable)          (sans activation)      └─▶ barre des menus      ▼
                                                                                   History.sqlite
        ◀──────────── menu.json (favoris, recettes, options) ◀── écrit par Forma à chaque changement
```

- **Demande** : un fichier JSON dans `Inbox/`, puis `NSWorkspace.open(forma://job/<id>)` avec
  `activates = false`. L'URL ne porte que l'identifiant : pas de limite de longueur avec 500 fichiers.
- **Configuration du menu** : Forma écrit `menu.json` à chaque changement de réglages et poste une notification
  Darwin `com.thibault.forma.menu-changed`. L'extension le relit et le garde en mémoire.
- **Fichiers sans chemin** (image partagée depuis Photos, Safari, Mail) : l'extension de partage les copie dans
  `Inbox/<id>/files/`.
- **Sécurité** : seul un binaire signé par l'équipe peut écrire dans le conteneur de groupe, donc une demande
  présente dans `Inbox/` est authentique. Une URL `forma://` qui porterait elle-même des chemins (voir §6, idée 6)
  devra être limitée aux options non destructives, puisque n'importe quelle page web peut ouvrir une URL.

### 2.4 Signature

Passer de ad hoc à `Developer ID Application`, équipe `PG46BWSK3T`, pour les trois cibles.
Effet de bord unique : macOS redemandera une fois les accès Bureau/Documents/Téléchargements et l'élément
d'ouverture devra être réactivé. En contrepartie ces autorisations deviennent **stables d'un build à l'autre**,
ce qui n'est pas le cas aujourd'hui. Pas besoin de notarisation pour un usage local.

---

## 3. Conception

### 3.1 Le menu contextuel

Construit à partir de la sélection (classée par extension, sans lire les fichiers) et de `menu.json`.

```
Forma ▸
   Convertir en JPEG                  ← favoris, puis formats les plus utilisés pour ce type (historique)
   Convertir en WebP
   Convertir en PNG
   Convertir en… ▸                    ← FormatCatalog.outputs(for:) regroupé (Populaires, Modernes, Pro…)
   ─────────
   Compresser                         ← préréglage courant, indiqué dans le titre
   Compresser avec… ▸                 ← les 7 préréglages
   Agrandir ×2 (IA)                   ← images uniquement
   ─────────
   Recettes ▸                         ← voir §3.6
   ─────────
   Ouvrir dans Forma…                 ← ajoute à la fenêtre, comme aujourd'hui
   Annuler la dernière conversion     ← si un lot récent venant du Finder existe
```

Règles :
- **Un seul type** dans la sélection (ex. que des images) : le menu ci-dessus, filtré.
- **Types mélangés** : une section par type (« Images → WebP », « Vidéos → MP4 ») limitée aux favoris, plus
  « Convertir chaque type avec ses réglages par défaut ».
- **Dossier** sélectionné : pas d'énumération dans l'extension (trop lent). Entrées génériques « Convertir les
  images du dossier en… », le tri se fait dans l'app via `Pipeline.expand`.
- **Rien de compatible** : le menu Forma n'apparaît pas.
- Option « favoris au premier niveau » : les 2-3 premières entrées sortent du sous-menu.
- Icônes SF Symbols (les `symbol` de `ProcessMode` et `MediaKind` existent déjà).

Autres emplacements fournis par la même extension :
- **Fond de fenêtre** : « Convertir les images de ce dossier… », « Surveiller ce dossier avec Forma… »
  (crée un `WatchedFolder` pré-rempli et ouvre l'onglet Automatisation).
- **Bouton de barre d'outils du Finder** : même menu sur la sélection, plus « Optimiser le presse-papiers »
  et « Ouvrir Forma ».

Mécanique des actions : une seule méthode `@objc func run(_:)`, le `tag` de l'entrée indexe une table
`[Int: MenuAction]` reconstruite à chaque `menu(for:)`.

### 3.2 Le modèle de demande (partagé)

```swift
struct ExternalRequest: Codable {
    var id: UUID
    var source: Source              // .finder, .share, .service, .url
    var mode: ProcessMode
    var target: String?             // id de FormatCatalog, nil = réglage par défaut du type
    var recipe: UUID?               // recette à appliquer (prioritaire sur le reste)
    var paths: [String]             // fichiers ou dossiers en place
    var stagedDirectory: String?    // copies faites par l'extension de partage
    var overrides: Overrides?       // préréglage, qualité, redimensionnement, métadonnées
    var destination: Destination?   // .default, .alongside, .folder(path), .clipboard
    var openWindow: Bool            // « Ouvrir dans Forma… »
}
```

### 3.3 `JobCenter` : la file des travaux en arrière-plan

Nouveau composant `@MainActor @Observable`, indépendant des listes de la fenêtre.

- File FIFO de lots ; chaque lot a son propre `ProcessingSnapshot` (réglages courants + surcharges de la demande)
  et sa cible. Une demande qui arrive pendant un lot s'ajoute derrière, elle n'est jamais perdue.
- Même parallélisme que `AppModel` (`SystemInfo.imageParallelism`, `maxParallelVideos`), via un limiteur commun
  pour ne pas doubler la charge si la fenêtre traite aussi un lot.
- Publie progression globale, lot courant, résultats : consommés par l'icône de la barre des menus, le HUD et
  les « résultats récents ».
- Annulation par lot. `HistoryOrigin` gagne `.finder` et `.share`.
- En fin de lot : notification si le HUD est désactivé, sélection des résultats dans le Finder si demandé,
  copie dans le presse-papiers si `destination == .clipboard`.
- Le dépôt sur l'icône de la barre des menus passe aussi par `JobCenter`, ce qui corrige le défaut signalé en §1.

### 3.4 Retour visuel sans fenêtre

`Toast` (`Services/Clipboard.swift:269`) devient un HUD de progression : panneau non activant en verre, en haut à
droite sous la barre des menus.

- Pendant : « Conversion de 12 fichiers en WebP · 5/12 », barre de progression, bouton Annuler.
- Après (5 s, ou tant que la souris est dessus) : « 12 fichiers · −64 % » avec **Afficher**, **Annuler** (undo
  via l'historique), **Partager**, et la possibilité de faire glisser les résultats hors du HUD.
- Erreurs : le HUD reste jusqu'à ce qu'on le ferme, avec le détail par fichier.

### 3.5 Extension de partage

Panneau compact SwiftUI hébergé dans un `NSViewController` :
- résumé de ce qui est partagé (vignettes, nombre, poids) ;
- mode (Convertir / Compresser / Agrandir) ;
- formats en pastilles (favoris puis populaires, selon le type détecté) et préréglage ;
- destination : à côté de l'original (si l'élément est un fichier), dossier des partages (Téléchargements par
  défaut), presse-papiers ;
- **Convertir** : écrit la demande, réveille Forma, ferme le panneau. Le suivi se fait dans le HUD.

Règle d'activation : fichiers, images, vidéos, audio, PDF. Les éléments fournis sous forme de données sont copiés
dans `Inbox/<id>/files/`, que `JobCenter` supprime une fois le lot terminé.

Partage **sortant** : bouton Partager (`NSSharingServicePicker`) dans le HUD, sur les lignes de l'historique et
sur les résultats récents de la barre des menus.

Les services existants sont conservés mais rebranchés sur `JobCenter` (sans fenêtre), sauf « Forma — Ajouter ».
Ils couvrent les dossiers iCloud/OneDrive et permettent d'assigner un raccourci clavier dans Réglages Système.

### 3.6 Recettes

Aujourd'hui `NamedPreset` ne stocke que des réglages par type. Une **recette** décrit une action complète,
utilisable partout :

```swift
struct Recipe: Codable, Identifiable {
    var id: UUID; var name: String; var symbol: String
    var mode: ProcessMode
    var targets: [MediaKind: String]      // ex. image → WEBP
    var overrides: Overrides              // qualité, redimensionnement, métadonnées, filigrane…
    var destination: Destination
    var showInFinder: Bool; var showInShare: Bool
}
```

Exemples : « Web » (WebP, 1920 px max, sans métadonnées), « E-mail » (JPEG, ≤ 500 Ko), « Archive » (HEIC, tout
conserver). Une recette apparaît dans le menu Finder, le panneau de partage, la barre des menus, `forma run <nom>`
et les Raccourcis. C'est ce qui rend le menu réellement personnalisable sans le surcharger.

### 3.7 Réglages : nouvel onglet « Finder »

- État de l'extension (`FIFinderSyncController.isExtensionEnabled`) et bouton d'activation
  (`showExtensionManagementInterface()`).
- Favoris par type, réordonnables ; option « classer selon mes habitudes » (fréquences tirées de l'historique).
- Entrées affichées : compresser, agrandir, recettes, annuler ; favoris au premier niveau ; icônes.
- Comportement : destination des travaux lancés du Finder, HUD ou notification, révéler à la fin.
- Dossier des partages.
- Gestion des recettes (peut aussi vivre dans l'onglet Préréglages).

---

## 4. Changements dans le projet

```
Forma/
  Shared/                      ← compilé dans les 3 cibles
    Formats.swift                (déplacé depuis Core/, inchangé)
    ExternalRequest.swift
    MenuConfig.swift             (contenu de menu.json)
    MenuBuilder.swift            (sélection + config → modèle de menu ; fonction pure, testable)
    GroupContainer.swift         (chemins Inbox/, menu.json, notification Darwin)
  Integration/                 ← app uniquement
    JobCenter.swift
    RequestRouter.swift          (forma://, Inbox, services)
    MenuConfigPublisher.swift    (prefs → menu.json)
    ProgressHUD.swift
    Recipes.swift
  Views/FinderSettingsView.swift
FormaFinder/                   ← extension Finder Sync
  FinderSync.swift  Info.plist  FormaFinder.entitlements
FormaShare/                    ← extension de partage
  ShareViewController.swift  ShareView.swift  Info.plist  FormaShare.entitlements
Forma/Forma.entitlements       ← application-groups
scripts/install.sh
```

Fichiers existants modifiés :

| Fichier | Changement |
|---|---|
| `project.yml` | 2 cibles `app-extension` embarquées, `Shared/` dans les trois, entitlements, signature Developer ID, `CFBundleURLTypes` (`forma`). Rappel : `Forma/Info.plist` est régénéré par XcodeGen, tout passe par `project.yml`. |
| `App/FormaApp.swift` | `application(_:open:)` distingue `forma://` des fichiers ; lancement discret ; `.defaultLaunchBehavior` conditionnel ; arrêt automatique quand la file est vide. |
| `Services/Services.swift` | `ServicesProvider.handle` → `RequestRouter` sans fenêtre. |
| `MenuBar/MenuBarController.swift` | `accept` → `JobCenter` ; l'icône observe aussi `JobCenter`. |
| `Core/History.swift` | `HistoryOrigin` : `.finder`, `.share`. |
| `Core/Settings.swift` | `Preferences.finder` (favoris, options), `Preferences.recipes`. Le décodage tolérant existant couvre la migration. |
| `Intents/Intents.swift` | Intents « Appliquer une recette », « Annuler le dernier traitement ». |
| `CLI/CLI.swift` | `forma run <recette>`, `forma finder status|enable|disable|reset`. |
| `Views/SettingsView.swift` | Onglet Finder. |
| `README.md` | Section intégration. |

`scripts/install.sh` : build Release, quitter Forma, copier dans `/Applications`, **désenregistrer l'appex resté
dans `build-release/`** (sinon Launch Services peut charger la mauvaise copie), `pluginkit -a` puis
`pluginkit -e use -i com.thibault.forma.FinderMenu`, relancer.

---

## 5. Phases

### Phase 0 — Spike de validation (½ journée)

Une extension Finder Sync vide avec une entrée et un sous-menu, sur une branche jetable. Chaque point est une
porte de décision :

| À vérifier | Si ça échoue |
|---|---|
| L'appex signé Developer ID, non notarisé, se charge (`pluginkit -m -p com.apple.FinderSync` sans « ! ») | Essayer l'identité Apple Development |
| `directoryURLs = ["/"]` + volumes montés : menu présent sur le Bureau, Téléchargements, disque externe | Lister les dossiers racine explicitement |
| Le `tag` est conservé dans les sous-menus, les images s'affichent | Retrouver l'action par le chemin des titres |
| Lecture/écriture du conteneur de groupe des deux côtés, sans alerte « accéder aux données d'autres apps » | Repli : charge utile dans l'URL + exception `shared-preference.read-only` |
| `open forma://…` depuis le bac à sable, sans activation | Notification distribuée + app résidente |
| Lancement à froid sans fenêtre ni rebond dans le Dock | Passer à l'agent `FormaAgent.app` (§2.2) |
| Menu dans `~/Library/CloudStorage/OneDrive-Personnel` et iCloud Drive | Documenter, les services prennent le relais |
| Temps d'affichage du menu avec 500 fichiers sélectionnés | Plafonner l'analyse aux N premiers |

Livrable : ce tableau rempli, et les décisions de §2 confirmées ou corrigées.

### Phase 1 — Fondations dans l'app (1,5 jour)

Signature, App Group, `Shared/`, `ExternalRequest`, `JobCenter`, `RequestRouter`, schéma `forma://`,
lancement discret, HUD, origines d'historique, `MenuConfigPublisher`.

Critères : `forma request convert --to webp a.png b.png` (commande de débogage qui écrit dans `Inbox/` et ouvre
l'URL) convertit sans fenêtre, app lancée ou non ; deux demandes rapprochées s'enchaînent ; l'annulation depuis
le HUD fonctionne ; l'historique affiche l'origine ; un lot en cours dans la fenêtre n'est pas perturbé.

### Phase 2 — Extension Finder (1,5 jour)

`MenuBuilder`, `FinderSync.swift` (éléments, fond, barre latérale, barre d'outils), onglet Réglages,
`forma finder …`, script d'installation.

Critères : menu correct pour image seule, lot d'images, vidéo, audio, PDF, DOCX, sélection mixte, dossier ;
rien pour un `.zip` ; changer un favori dans les réglages se reflète au clic droit suivant ; le menu s'affiche
sans latence perceptible.

### Phase 3 — Partage (1 jour)

Extension de partage, mise en attente des données, dossier des partages, partage sortant.

Critères : depuis le Finder, Photos, Aperçu, Safari (image) et Mail (pièce jointe) ; résultat au bon endroit ;
`Inbox/` vide après le lot.

### Phase 4 — Recettes et extras (1 jour)

Recettes (modèle, éditeur, menu, partage, CLI, intents), services rebranchés, classement selon les habitudes,
« Surveiller ce dossier », « Annuler la dernière conversion ».

### Phase 5 — Finitions (½ journée)

Cas limites : fichiers disparus, volume éjecté pendant un lot, 1 000 fichiers, demande pendant un
agrandissement IA, extension désactivée (message clair dans les réglages), première alerte d'autorisation.
Tests de `MenuBuilder` et du codec de demande. README. Version 1.3.

**Total : environ 6 jours.** Les phases 0 à 2 donnent déjà le clic droit complet ; 3 et 4 sont indépendantes
l'une de l'autre.

---

## 6. Autres idées

Classées par rapport intérêt / effort.

1. **Recettes** (§3.6). Intégrées au plan, c'est ce qui donne de la valeur au menu.
2. **Classement selon les habitudes.** L'historique sait déjà que tes HEIC finissent en JPEG : le proposer en
   premier. Une requête SQL sur `entries`.
3. **« Surveiller ce dossier avec Forma… »** au clic droit sur un dossier. La surveillance existe, il ne manque
   que le point d'entrée.
4. **Palette de conversion rapide.** Un raccourci global (ou un service avec raccourci) ouvre une mini-palette
   façon Spotlight sur la sélection du Finder : taper `webp 80` puis Entrée. Pour les formats rares, plus rapide
   que trois niveaux de sous-menus.
5. **Spotlight et Raccourcis.** Sur macOS 26+, les App Intents sont proposés comme actions dans Spotlight. Les
   trois intents existants y sont déjà ; ajouter « Appliquer une recette », « Annuler le dernier traitement » et
   « Optimiser le presse-papiers » coûte quelques lignes.
6. **Schéma `forma://` public** (`forma://convert?to=webp&path=…`) pour Raycast, Alfred, BetterTouchTool, Copia.
   Sous-produit de la phase 1 ; limité aux actions non destructives (voir §2.3).
7. **Icône du Dock.** Déposer des fichiers dessus pourrait proposer le même menu (formats favoris, recettes) au
   lieu d'ouvrir la fenêtre ; menu du Dock avec les recettes.
8. **Mode discret permanent.** Option « ne pas afficher Forma dans le Dock quand seule la barre des menus est
   active ». Le mécanisme est celui du lancement discret.
9. **Marquer les fichiers déjà optimisés** (attribut étendu `com.thibault.forma.optimized`) pour que
   « Compresser » les saute instantanément sur de gros dossiers. Les pastilles Finder Sync permettraient de
   l'afficher, mais elles coûtent en performance : à ne faire que si le besoin se confirme.

---

## 7. Risques

| Risque | Parade |
|---|---|
| L'extension ne se charge pas ou le menu n'apparaît pas à certains endroits | Phase 0 avant tout le reste ; services conservés |
| Mauvaise copie de l'appex chargée (celle de `build-release/`) | `scripts/install.sh` la désenregistre ; `forma finder status` affiche le chemin chargé |
| Changement de signature : autorisations redemandées une fois | Prévenir dans le README ; le faire en phase 1, pas à la fin |
| Finder ne transmet pas les infos attendues du menu | Table d'actions indexée par `tag`, repli par titres |
| Lancement à froid visible | Politique d'activation `.accessory`, sinon agent dédié |
| Charge double (fenêtre + Finder) | Limiteur de parallélisme commun |
| Demande forgée via `forma://` | Seul `Inbox/` est de confiance ; URL directes restreintes |

## 8. Sources consultées

- En-tête `FinderSync.h` du SDK macOS 27 (API inchangée : `menu(for:)`, `directoryURLs`, `selectedItemURLs()`,
  `isExtensionEnabled`, `showExtensionManagementInterface()`).
- Forums développeurs Apple : [806607](https://developer.apple.com/forums/thread/806607) (extension bloquée par
  un profil MDM, pas un défaut du système) et [819937](https://developer.apple.com/forums/thread/819937)
  (extension marquée « ! », cause non identifiée).
- Configuration des extensions de Gemini (Finder Sync) et Dropover (partage) installées sur ce Mac.
