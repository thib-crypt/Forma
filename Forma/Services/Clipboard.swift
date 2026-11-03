import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Watches the clipboard and transparently optimizes copied images (screenshots, images copied from apps).
@MainActor
final class ClipboardOptimizer {
    static let shared = ClipboardOptimizer()
    static let marker = NSPasteboard.PasteboardType("com.thibault.forma.optimized")
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var busy = false

    func apply() {
        if PreferencesStore.shared.prefs.clipboardEnabled { start() } else { stop() }
    }

    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
        timer?.tolerance = 0.2
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard !busy, pb.types?.contains(Self.marker) != true else { return }
        // Ignore copied files and transient/concealed data (password managers).
        let types = pb.types ?? []
        if types.contains(.fileURL) || types.contains(.init("org.nspasteboard.ConcealedType")) || types.contains(.init("org.nspasteboard.TransientType")) { return }
        let candidates: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.init("public.jpeg"), "jpg"), (.init("public.heic"), "heic"), (.tiff, "tiff")]
        guard let (type, ext) = candidates.first(where: { types.contains($0.0) }), let data = pb.data(forType: type) else { return }
        Task { await optimize(data, ext: ext) }
    }

    func optimizeNow() {
        lastChange = -1
        poll()
    }

    private func optimize(_ data: Data, ext: String) async {
        busy = true
        defer { busy = false }
        let prefs = PreferencesStore.shared.prefs
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Forma/Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Clean previous clipboard files.
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.forEach { try? FileManager.default.removeItem(at: $0) }

        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: ".")
        let input = dir.appendingPathComponent("Image \(stamp)").appendingPathExtension(ext == "tiff" ? "png" : ext)
        do {
            if ext == "tiff" { // screenshots arrive as TIFF: store as PNG first
                guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return }
                try png.write(to: input)
            } else { try data.write(to: input) }

            var image = prefs.processing.image
            image.preset = .custom
            image.customQuality = prefs.clipboardQuality
            image.metadata = .stripAll
            image.watermark.enabled = false
            if let m = prefs.clipboardMaxDimension { image.resizeMode = .fit; image.width = m; image.height = m } else { image.resizeMode = .none }
            let format = prefs.clipboardTarget == "SAME" ? (FileDetection.sameFormat(for: input) ?? FormatCatalog.format("PNG")!) : (FormatCatalog.format(prefs.clipboardTarget) ?? FormatCatalog.format("WEBP")!)
            let job = ImageEngine.Job(input: input, inputClass: .raster, format: format, settings: image, mode: .compress, compress: true, near: dir)
            guard let produced = try await ImageEngine.process(job, progress: { _ in }).first else { return }
            let out = dir.appendingPathComponent("Image \(stamp) (optimisée)").appendingPathExtension(format.ext)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: produced.url, to: out)
            try? FileManager.default.removeItem(at: input)

            let before = Int64(data.count), after = out.fileSize
            guard after > 0, after < before || prefs.clipboardTarget != "SAME" else {
                Toast.show("Presse-papiers déjà optimisé", symbol: "checkmark.seal")
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(out.absoluteString, forType: .fileURL)
            if let d = try? Data(contentsOf: out), let ut = UTType(filenameExtension: format.ext) {
                item.setData(d, forType: NSPasteboard.PasteboardType(ut.identifier))
                if format.id == "PNG" { item.setData(d, forType: .png) }
            }
            item.setData(Data(), forType: Self.marker)
            pb.writeObjects([item])
            lastChange = pb.changeCount
            let pct = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            Toast.show("Presse-papiers optimisé · \(format.name) · \(after.formattedBytes)\(pct > 0 ? " (−\(pct) %)" : "")", symbol: "sparkles")
        } catch {
            Toast.show("Échec de l'optimisation : \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }
}

// MARK: - Toast HUD

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String) {
        hideWork?.cancel()
        let host = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        host.frame.size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return p
        }()
        panel = p
        p.contentView = host
        if let screen = NSScreen.main {
            let size = host.fittingSize
            p.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24,
                              width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.tint)
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
        .padding(8)
    }
}
