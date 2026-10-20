import MerCore
import AppKit
import SwiftUI

/// Actions that work on any selection (folders, mixed files, unknown types) and never touch the conversion engines.
enum FileAction: String, CaseIterable, Identifiable {
    case airdrop, float, copy, move, copyPath, terminal, reveal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airdrop: return Loc.t("AirDrop")
        case .float: return Loc.t("Float")
        case .copy: return Loc.t("Copy")
        case .move: return Loc.t("Move…")
        case .copyPath: return Loc.t("Copy Path")
        case .terminal: return Loc.t("Terminal")
        case .reveal: return Loc.t("Reveal")
        }
    }

    var symbol: String {
        switch self {
        case .airdrop: return "airplayaudio"
        case .float: return "pip"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "link"
        case .terminal: return "terminal"
        case .reveal: return "magnifyingglass"
        }
    }

    @MainActor
    func perform(_ urls: [URL]) {
        switch self {
        case .airdrop:
            NSApp.activate(ignoringOtherApps: true)
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .float:
            FloatShelf.shared.add(urls)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            HUDController.shared.toast(Loc.f("Copied %@", urls.count == 1 ? urls[0].lastPathComponent : Loc.f("%d files", urls.count)))
        case .move:
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = Loc.t("Move Here")
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            var moved = 0
            for url in urls {
                var dest = dir.appendingPathComponent(url.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    let ext = url.pathExtension
                    let base = url.deletingPathExtension().lastPathComponent
                    dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                    n += 1
                }
                if (try? FileManager.default.moveItem(at: url, to: dest)) != nil { moved += 1 }
            }
            HUDController.shared.toast(Loc.f(moved == 1 ? "Moved %d item to %@" : "Moved %d items to %@", moved, dir.lastPathComponent))
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            HUDController.shared.toast(Loc.t("Path copied"))
        case .terminal:
            let first = urls[0]
            let dir = first.isDirectory ? first : first.deletingLastPathComponent()
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

// MARK: - Float shelf: an always-on-top mini window you can drag files back out of

@MainActor
final class FloatShelf {
    static let shared = FloatShelf()
    private var panels: [GlassSurfacePanel] = []

    func add(_ urls: [URL]) {
        for url in urls {
            let panel = GlassSurfacePanel(size: CGSize(width: 132, height: 150), level: .floating)
            panel.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: FloatCard(url: url) { [weak self, weak panel] in
                guard let panel else { return }
                panel.close()
                self?.panels.removeAll { $0 === panel }
            })
            host.sizingOptions = [.intrinsicContentSize]
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
            let screen = NSScreen.main?.visibleFrame ?? .zero
            let offset = CGFloat(panels.count % 6) * 28
            let pad = GlassSurface.shadowPad
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 166 - pad - offset, y: screen.maxY - 44 + pad - panel.frame.height - offset))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}

private struct FloatCard: View {
    let url: URL
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 64, height: 64)
            Text(url.lastPathComponent)
                .font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(10)
        .frame(width: 124, height: 142)
        .glassCard(RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true)
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).padding(8)
            }
        }
        .padding(GlassSurface.shadowPad)
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help(Loc.t("Drag me into any app · double-click to open"))
    }
}
