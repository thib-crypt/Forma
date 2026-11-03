# Forma

Native macOS converter and compressor (SwiftUI, macOS 26, Apple Silicon), modeled on the *features* of Picmal
(analyzed with REA: bundle, App Intents, binary strings). Original code, design and icon; nothing copied from Picmal.

## Features
- **Convert**: 59 image formats, 27 audio, 27 video (incl. video → animated GIF / WebP / APNG, audio extraction).
  RAW, PSD, SVG, PDF (page by page), EPS and AI as input.
- **Compress**: 7 image presets (+ quality, target file size), video presets (HEVC VideoToolbox), audio presets.
  pngquant + oxipng, MozJPEG (jpegtran), gifsicle, Ghostscript for PDFs. Never makes a file bigger ("Already optimized").
- **Upscale ×2 (AI)**: Apple's on-device super-resolution model (VideoToolbox `VTSuperResolutionScaler`, Neural Engine).
  Tiles ≤ 1920 px with clamped context at ×4, Lanczos down to ×2 (supersampling, no seams/borders), alpha and
  16-bit preserved, EXIF orientation applied. ~1 s per input megapixel on an M3 Pro. Lanczos fallback on Intel.
  `forma upscale <images> [--to fmt]`, Shortcut "Agrandir des images ×2", Finder service, ⌘3.
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

## Engines
Native first: ImageIO / Core Graphics (HEIC, AVIF, JPEG, PNG, TIFF, JP2, ICO, ICNS, PSD, EXR, DDS…), FFmpeg + VideoToolbox/AudioToolbox.
Homebrew (optional): `brew install imagemagick ffmpeg ghostscript webp jpeg-xl mozjpeg pngquant oxipng gifsicle`.

## Build
```
xcodegen generate
xcodebuild -scheme Forma -configuration Release -derivedDataPath build-release build
cp -R build-release/Build/Products/Release/Forma.app /Applications/
```
CLI: Settings › Engines › "`forma` command", then `forma convert *.heic --to jpg`, `forma compress clip.mov`, `forma formats`.
