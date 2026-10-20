import AppKit
import SwiftUI
import Combine
import MerCore

/// Small floating job list in the bottom-right corner.
@MainActor
final class HUDController: ObservableObject {
    static let shared = HUDController()

    @Published var message: String?
    private var panel: GlassSurfacePanel?
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        JobCenter.shared.onJobFinished = { [weak self] job in
            guard let self else { return }
            if case .done = job.state, AppSettings.shared.revealWhenDone, !job.outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
            }
            if case .failed = job.state { self.scheduleHide(after: 20) }   // errors must be readable, not flash by
            else { self.scheduleHide() }
        }
    }

    func toast(_ text: String) {
        message = text
        show()
        scheduleHide(after: 2.2)
    }

    func show() {
        hideTask?.cancel()
        if panel == nil { makePanel() }
        position()
        panel?.orderFrontRegardless()
        scheduleHide()
    }

    private func makePanel() {
        let p = GlassSurfacePanel(size: CGSize(width: 360, height: 100), level: .statusBar)
        let host = NSHostingView(rootView: HUDView(hud: self, center: JobCenter.shared))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        panel = p

        // Keep the panel fitted to its content.
        JobCenter.shared.objectWillChange.merge(with: objectWillChange).sink { [weak self] _ in
            DispatchQueue.main.async { self?.position() }
        }.store(in: &cancellables)
    }

    private func position() {
        guard let panel, let host = panel.contentView as? NSHostingView<HUDView> else { return }
        let size = host.fittingSize
        guard size.height > 1 else { return }
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(NSRect(x: screen.maxX - size.width - 22 + GlassSurface.shadowPad, y: screen.minY + 22 - GlassSurface.shadowPad, width: size.width, height: size.height), display: true)
    }

    private func scheduleHide(after seconds: Double = 5) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let busy = JobCenter.shared.jobs.contains { !$0.isFinished }
            if busy { self.scheduleHide(after: 2); return }
            self.message = nil
            self.panel?.orderOut(nil)
        }
    }
}

struct HUDView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var hud: HUDController
    @ObservedObject var center: JobCenter

    var body: some View {
        let recent = Array(center.jobs.prefix(3))
        GlassGroup(spacing: 10) {
            VStack(alignment: .trailing, spacing: 8) {
                if let m = hud.message {
                    Label(m, systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassCard(Capsule())
                }
                ForEach(recent) { job in
                    JobRow(job: job, compact: true)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .glassCard(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: recent.map(\.id))
        }
        .frame(width: 360, alignment: .trailing)
        .padding(GlassSurface.shadowPad)
        .fontDesign(.rounded)
        .opacity(recent.isEmpty && hud.message == nil ? 0 : 1)
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .queued: Text(Loc.t("Waiting…")).font(.caption).foregroundStyle(.secondary)
                case .running: ProgressView(value: max(job.progress, 0.02)).progressViewStyle(.linear).tint(Theme.accent)
                        .animation(.easeOut(duration: 0.2), value: job.progress)
                case .done:
                    Text(job.outputs.count == 1 ? job.outputs[0].lastPathComponent : Loc.f("%d files", job.outputs.count))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .failed(let msg): Text(Loc.message(msg)).font(.caption).foregroundStyle(.red).lineLimit(compact ? 2 : 4)
                case .cancelled: Text(Loc.t("Cancelled")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .done: Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        default: Image(systemName: job.action.symbol ?? job.action.category.symbol).font(.title3)
            .symbolRenderingMode(.hierarchical).foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .done:
            Button { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help(Loc.t("Reveal in Finder"))
        case .running, .queued:
            Button { job.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help(Loc.t("Cancel"))
        case .failed:
            Button { JobCenter.shared.dismiss(job) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(Loc.t("Dismiss"))
        default: EmptyView()
        }
    }
}
