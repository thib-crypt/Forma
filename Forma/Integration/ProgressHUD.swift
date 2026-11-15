import AppKit
import SwiftUI

/// Progress panel for jobs started outside the window (Finder, Share, Services, links). Non-activating glass panel in
/// the top-right corner, under the menu bar: it never takes focus from the app you are in.
@MainActor
@Observable
final class ProgressHUD {
    static let shared = ProgressHUD()

    /// The finished job whose result is shown (until it times out, or is closed when it has errors).
    var shown: BackgroundJob?
    var hovering = false {
        didSet { if !hovering { scheduleHide() } }
    }
    private(set) var isVisible = false

    @ObservationIgnored private var panel: HUDPanel?
    @ObservationIgnored private var hideWork: DispatchWorkItem?
    @ObservationIgnored private var height: CGFloat = 80
    static let width: CGFloat = 340

    private var enabled: Bool { PreferencesStore.shared.prefs.finder.feedback == .hud }

    func jobQueued(_ job: BackgroundJob) {
        guard enabled else { return }
        hideWork?.cancel()
        show()
    }

    func jobFinished(_ job: BackgroundJob) {
        guard enabled else { return }
        if JobCenter.shared.isBusy { return }      // keep showing the progress of the next job
        shown = job
        show()
        scheduleHide()
    }

    func dismiss() {
        hideWork?.cancel()
        shown = nil
        guard let panel, isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.22; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                if !ProgressHUD.shared.isVisible { panel.orderOut(nil) }
                LaunchContext.quitIfIdle(after: 0.5)
            }
        })
    }

    /// 5 s after the end, unless the mouse is over the panel or something failed.
    private func scheduleHide() {
        hideWork?.cancel()
        guard let job = shown, !JobCenter.shared.isBusy, !hovering, job.failures.isEmpty || job.total == 0 else { return }
        let w = DispatchWorkItem { MainActor.assumeIsolated { ProgressHUD.shared.dismiss() } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (job.state == .cancelled ? 2 : 5), execute: w)
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        place(p)
        if !isVisible {
            isVisible = true
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        }
    }

    private func makePanel() -> HUDPanel {
        let p = HUDPanel()
        let host = FirstMouseHostingView(rootView: ProgressHUDView(onHeight: { h in
            MainActor.assumeIsolated { ProgressHUD.shared.heightChanged(h) }
        }))
        host.sizingOptions = []
        p.contentView = host
        return p
    }

    private func heightChanged(_ h: CGFloat) {
        guard h > 0, abs(h - height) > 0.5 else { return }
        height = h
        if let panel { place(panel) }
    }

    private func place(_ p: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let w = Self.width + 16
        p.setFrame(NSRect(x: vf.maxX - w - 4, y: vf.maxY - height - 4, width: w, height: height), display: true)
    }
}

final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ProgressHUD.width + 16, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityLabel("Progression Forma")
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons react to the first click even though Forma is not the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Content

private struct ProgressHUDView: View {
    let onHeight: @Sendable (CGFloat) -> Void
    @State private var center = JobCenter.shared
    @State private var hud = ProgressHUD.shared

    var body: some View {
        VStack(spacing: 8) {
            if let job = center.active {
                RunningCard(job: job, queued: center.queued.count)
            } else if let job = hud.shown {
                FinishedCard(job: job)
            } else if let next = center.queued.first {
                RunningCard(job: next, queued: center.queued.count - 1)
            }
        }
        .frame(width: ProgressHUD.width)
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .onHover { hud.hovering = $0 }
        .animation(.smooth(duration: 0.25), value: center.active?.id)
        .animation(.smooth(duration: 0.25), value: hud.shown?.id)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct RunningCard: View {
    let job: BackgroundJob
    let queued: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: job.mode.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: job.state == .running)
                Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if job.total > 0 {
                    Text("\(job.processed)/\(job.total)")
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Button { JobCenter.shared.cancel(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(PanelIconButtonStyle(size: 22))
                    .help("Annuler ce traitement")
            }
            ProgressView(value: job.state == .preparing ? nil : job.fraction)
                .progressViewStyle(.linear)
                .animation(.linear(duration: 0.15), value: job.fraction)
            HStack {
                Text(job.state == .preparing ? "Préparation…" : job.currentNames.isEmpty ? "…" : job.currentNames)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if queued > 0 { Text("+ \(queued) en attente") }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .modifier(CardBackground())
    }
}

private struct FinishedCard: View {
    let job: BackgroundJob
    @State private var undoMessage: String?

    private var ok: Bool { job.failures.isEmpty && job.state == .finished && job.total > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : job.state == .cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(ok ? Color.green : job.state == .cancelled ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(undoMessage ?? job.summary).font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { ProgressHUD.shared.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PanelIconButtonStyle(size: 22))
                    .help("Fermer")
            }
            if !job.outputs.isEmpty, !job.undone {
                ResultStrip(urls: job.outputs)
                HStack(spacing: 6) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) } label: {
                        Label("Afficher", systemImage: "magnifyingglass")
                    }
                    if !job.historyIDs.isEmpty {
                        Button { undoMessage = JobCenter.shared.undo(job) } label: {
                            Label("Annuler", systemImage: "arrow.uturn.backward")
                        }
                    }
                    ShareLink(items: job.outputs) { Label("Partager", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(PanelCapsuleButtonStyle())
            }
            if !job.failures.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(job.failures.prefix(5)) { f in
                        (Text(f.url.lastPathComponent).fontWeight(.medium) + Text(" — \(f.message)"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if job.failures.count > 5 {
                        Text("+ \(job.failures.count - 5) autres").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .modifier(CardBackground())
    }

    private var subtitle: String {
        var parts = [job.title, AppModel.format(job.elapsed)]
        if job.bytesIn > job.bytesOut, job.mode != .upscale { parts.append("\((job.bytesIn - job.bytesOut).formattedBytes) économisés") }
        if job.ignored > 0 { parts.append("\(job.ignored) ignoré\(job.ignored > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }
}

/// Thumbnails of the results; each one can be dragged out of the HUD.
private struct ResultStrip: View {
    let urls: [URL]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(urls.prefix(6), id: \.self) { url in
                FileThumbnail(url: url)
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .help(url.lastPathComponent)
            }
            if urls.count > 6 {
                Text("+\(urls.count - 6)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
