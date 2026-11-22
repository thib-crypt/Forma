# Forma

Native macOS converter and compressor (SwiftUI, macOS 26, Apple Silicon), modeled on the *features* of Picmal
(analyzed with REA: bundle, App Intents, binary strings). Original code, design and icon; nothing copied from Picmal.

**Requires** macOS 26 (Tahoe) · Apple Silicon. UI in French.

## Install
Download the latest `Forma-<version>.dmg` from [Releases](https://github.com/thib-crypt/Forma/releases), open it and drag
Forma to Applications. The app is signed with a Developer ID and notarized by Apple.
Optional engines (see [Engines](#engines)) are installed with Homebrew; Forma tells you which one a format needs.

## Features
- **Convert**: 59 image formats, 27 audio, 27 video (incl. video → animated GIF / WebP / APNG, audio extraction).
  RAW, PSD, SVG, PDF (page by page), EPS and AI as input.
- **Documents** (22 output formats): DOCX, DOC, ODT, RTF, TXT, Markdown, HTML, EPUB, PDF, LaTeX, Typst, reST,
  AsciiDoc, Org, MediaWiki, FB2, PPTX, plus XLSX / ODS / CSV / ODP with LibreOffice. Inputs: Word (doc/docx), ODT, RTF(D),
  Pages, text, Markdown, HTML, web archives, EPUB, LaTeX, reST, Org, Typst, Jupyter, CSV, Excel, PowerPoint, Keynote, Numbers.
  Routing: LibreOffice (if installed) for faithful Office layouts and spreadsheets/slides → Pandoc for anything structural →
  Cocoa text system for RTF/.doc/text. **PDF output** is native: pandoc renders a styled HTML, TextKit paginates it into a
  vector PDF (A4 or Letter by region, page numbers) — ~0.1–0.5 s per document, no LaTeX or browser. Markup outputs get their
  pictures in a `<name>_images/` folder. **PDF → text** (per-file format, mappings or `--to docx`) uses the PDF's text layer,
  or Vision OCR (French + English) for scans. **Compressing** a DOCX / PPTX / XLSX / ODT / EPUB recompresses the pictures
  inside (image preset, capped at 2560 px), rezipped with ODF/EPUB's stored `mimetype` first.
- **Compress**: 7 image presets (+ quality, target file size), video presets (HEVC VideoToolbox), audio presets.
  pngquant + oxipng, MozJPEG (jpegtran), gifsicle, Ghostscript for PDFs. Never makes a file bigger ("Already optimized").
- **Upscale ×2 (AI)**: Apple's on-device super-resolution model (VideoToolbox `VTSuperResolutionScaler`, Neural Engine).
  Tiles ≤ 1920 px with clamped context at ×4, Lanczos down to ×2 (supersampling, no seams/borders), alpha and
  16-bit preserved, EXIF orientation applied. ~1 s per input megapixel on an M3 Pro. Lanczos fallback on Intel.
  `forma upscale <images> [--to fmt]`, Shortcut "Agrandir des images ×2", Finder service, ⌘3.
- **Before/after preview**: live re-encode with the current settings (exact size, ≈ for video from a 4 s excerpt),
  split slider / side by side / ×8 difference map, pinch & ⌘+/⌘− zoom to real pixels. Space on a row, or the eye icon.
- **History & undo** (⌘Y): every run from the app, CLI, Shortcuts, watched folders and schedules is logged
  (SQLite in Application Support, shared across processes). Undo trashes the outputs and restores whatever Forma
  had trashed (originals, overwritten files); modified outputs are kept, and undo is refused if the only copy is gone.
  ⌥⌘Z undoes the last batch; `forma history [--json]`, `forma undo [<id>]`.
- **Image processing**: resize (fit, width, height, exact with padding, stretch, %), color space + rendering intent,
  DPI, orientation, metadata (keep all / essentials / strip), copyright, watermark (image, position, opacity, tile).
- **Video**: codec, quality, speed, hardware acceleration with software fallback, instant remux, resolution, fps,
  playback speed, trim, sidecar subtitles (soft or burned in), audio bitrate.
- **Audio**: CBR/VBR/ABR, sample rate, mono, loudness normalization, cover art from the folder.
- **Output**: next to the original / subfolder / folder; name patterns `{original} {date} {camera}…`; conflicts;
  replace or delete originals (Trash); preserved dates; default conversions per extension.
- **Automation**: watched folders (FSEvents), clipboard optimization, scheduled processing, saved presets.
- **System integration**: menu bar with drop zone, Finder Services, Shortcuts (Convert / Compress),
  `forma` CLI, launch at login, notifications.

## Finder, Share menu & recipes (1.3)
- **Right-click in the Finder › Forma**: favourite formats first (“Convertir en WebP”), every format in “Convertir en…”,
  compress (with any preset), AI upscale, recipes, “Ouvrir dans Forma…”, undo the last Finder batch. Mixed selections get one
  section per kind; folders get “Convertir les images du dossier en…” and “Surveiller ce dossier”. Also on the window
  background and as a Finder toolbar button. Nothing opens: Forma works in the background with a small progress HUD.
- **Share › Forma** from any app (Finder, Photos, Preview, Safari images, Mail attachments): pick a format, a preset or a
  recipe; results next to the original, in the shares folder (Downloads by default) or on the clipboard.
- **Recipes**: complete reusable actions (“Web”: WebP, ≤ 1920 px, no metadata…), in the Finder menu, the Share panel, the menu
  bar item, `forma run <name>` and Shortcuts (“Appliquer une recette Forma”).
- Services (“Forma — Convertir / Compresser / Agrandir”) now run in the background too; they cover iCloud Drive / OneDrive
  folders, where macOS hides extension menus, and accept keyboard shortcuts.
- Links for launchers: `forma://convert?to=webp&path=/a.png`, `forma://compress?preset=web_optimized&path=…`,
  `forma://recipe?name=Web&path=…`. Any web page can open such a link, so they never replace or delete originals.
- Settings › Finder: extension status, favourites per kind, “rank by my habits”, menu entries, destination, HUD /
  notification, shares folder, “hide from the Dock when no window is open”, recipe editor.

How it works: the sandboxed extensions (`FormaFinder`, `FormaShare`) only write a request into the App Group
(`~/Library/Group Containers/PG46BWSK3T.com.thibault.forma/Inbox/<id>.json`) and open `forma://job/<id>`; the app (launched
headless, without window or Dock icon, if needed) runs it in `JobCenter`, a FIFO queue separate from the window, sharing
the parallelism slots with it. The app writes `menu.json` for the extensions whenever settings or history change.
Code shared by the three targets lives in `Forma/Shared/` (`MenuBuilder` is pure and unit-tested).

Since 1.3 Forma is signed with the Developer ID of team PG46BWSK3T (App Groups need it). macOS asks once again for
Desktop / Documents / Downloads access and the login item may need re-enabling; after that, permissions survive rebuilds.

## Drop (1.4)

Integration with [Drop](../Drop), the self-hosted S3 share service. Settings › Drop takes the server address and the
dashboard password (kept in the Keychain). Once connected:

- **Finder** › Forma › *Envoyer sur Drop* (any file; a folder goes up as a `.zip`), with an expiry submenu and
  *Compresser et envoyer sur Drop*. **Share** › Forma › *Envoyer*, **Services**, menu bar strip (drop files, or send the clipboard), ⇧⌘U / ⌥⌘U.
- **Recipes** can send their results to Drop; the main window can send every result (bottom bar › ⋯).
- The link is copied as soon as the upload ends (page or direct `?raw` link). HUD shows progress, copy/open/delete.
- Every upload is logged locally (⇧⌘D opens the list; expiry and deletion are synced with the server). Undoing a
  conversion also deletes its Drop link.
- CLI: `forma drop <files> [--expiry 7d] [--direct]`, `forma drop login|status|list|rm|expire`, `--drop` on `convert`,
  `compress`, `upscale`; `forma request upload …`. Shortcuts action *Envoyer sur Drop*.

## Presence & windows (1.5)

- **Where Forma lives** (Settings › Général › Présence): *Dock et barre des menus*, *Barre des menus* (no Dock icon, not in
  ⌘⇥; optionally a Dock icon only while a window is open) or *Dock* (a classic app that quits with its last window).
  Also from the menu bar icon's right-click menu and the panel's ⋯ menu (*Afficher dans le Dock*), and the Dock menu.
- **Windows are owned by AppKit** (`WindowRouter`), no longer by SwiftUI scenes: they open from the Dock, the menu bar,
  the Finder, a shortcut or a link, even after a headless launch. That fixes "Forma is in the Dock but shows no window"
  (a headless launch never created the SwiftUI view that held `openWindow`). Closed windows keep their content and every
  window remembers its size and position. Settings is a native toolbar-tab window.
- **Launch**: a login launch stays in the menu bar; a manual launch opens the main window, or (option off) the menu bar
  panel under its icon. Launches made for a `forma://` link stay in the background.
- **Global shortcut** (recorded in Settings › Général): opens the menu bar panel or the main window from any app; press
  again to close / hide.
- **Dock**: a progress bar on the icon while Forma works (orange when paused), and a Dock menu (pause/stop, add files,
  clipboard, history, Drop, undo).

## Engines
Native first: ImageIO / Core Graphics (HEIC, AVIF, JPEG, PNG, TIFF, JP2, ICO, ICNS, PSD, EXR, DDS…), FFmpeg + VideoToolbox/AudioToolbox.
Homebrew (optional): `brew install imagemagick ffmpeg ghostscript webp jpeg-xl mozjpeg pngquant oxipng gifsicle pandoc`,
and `brew install --cask libreoffice` for faithful Word/Excel/PowerPoint layouts and spreadsheet/slide outputs.

## Updates
Forma updates itself with [Sparkle](https://sparkle-project.org): it checks
[`appcast.xml`](appcast.xml) once a day (and on demand from « Rechercher les mises à jour… »), downloads the new DMG from
GitHub Releases, verifies its EdDSA signature and Apple notarization, then replaces and relaunches the app.

## Build
Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The project signs with a Developer ID certificate (team `PG46BWSK3T`): change `DEVELOPMENT_TEAM` and the App Group
in `project.yml` to build under your own account.
```
scripts/install.sh          # xcodegen + Release build + install in /Applications + register/enable the extensions
xcodebuild test -scheme Forma -derivedDataPath build -only-testing:FormaTests
```
`install.sh` unregisters the extensions left in `build-release/`, otherwise PlugInKit may load that copy.
Troubleshooting: `forma finder status` (loaded copy, pending requests), `forma finder reset`,
`forma finder menu <files…>` (prints the exact menu the Finder would show), `forma request convert --to webp <files…>`
(goes through the same path as a Finder click).
CLI: Settings › Engines › "`forma` command", then `forma convert *.heic --to jpg`, `forma compress clip.mov`, `forma formats`,
`forma run Web *.png`, `forma run --list`.

## Release
```
scripts/release.sh            # dist/Forma-<version>.dmg — hardened runtime, signed, notarized, stapled
scripts/release.sh --publish  # + tag v<version>, GitHub Release with the DMG, appcast.xml pushed (update goes live)
```
The version is `MARKETING_VERSION` in `project.yml`. Only that version needs bumping: the build number Sparkle compares is the commit count.
Notarization uses the Keychain profile `notary`
(`xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id PG46BWSK3T`, once); the update signature uses the Sparkle EdDSA key in the
Keychain (`generate_keys`, once — back it up with `generate_keys -x <file>`).

## License
[MIT](LICENSE)
