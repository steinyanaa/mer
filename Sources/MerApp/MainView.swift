import SwiftUI
import AppKit
import MerCore

struct MainView: View {
    @ObservedObject var center = JobCenter.shared
    @State private var targeted = false
    @State private var counts = (convert: 0, tool: 0)

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 18) {
                titleBar
                dropZone
                summary
                jobs
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 12)
        }
        .frame(minWidth: 520, minHeight: 600)
        .fontDesign(.rounded)
        .onAppear { refreshCounts() }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.title2).symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.accent)
                .padding(8).glassCard(Circle(), tint: Theme.accent.opacity(0.5))
            VStack(alignment: .leading, spacing: 0) {
                Text("Mer").font(.title3.weight(.semibold))
                Text("Offline file converter").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 4)      // sits level with the traffic lights
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.down.doc.fill")
                .font(.system(size: 48)).symbolRenderingMode(.hierarchical).foregroundStyle(Theme.accent)
                .contentTransition(.symbolEffect(.replace))
            Text(targeted ? "Release to choose a format" : "Drop files here").font(.title2.weight(.semibold))
            Text("Or hold ⇧ while dragging a file anywhere on your Mac to open the wheel.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Files…") { AppDelegate.shared.chooseFiles() }
                .controlSize(.large).tint(Theme.accent).glassButton(prominent: true).padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220)
        .glassCard(RoundedRectangle(cornerRadius: 34, style: .continuous), tint: targeted ? Theme.accent.opacity(0.35) : nil, interactive: true)
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            AppDelegate.load(providers) { urls in PaletteController.shared.present(files: urls) }
            return true
        }
    }

    private var summary: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                stat("\(counts.convert)", "conversions")
                stat("\(counts.tool)", "tools")
                stat("\(Engines.catalogue.filter(\.installed).count)/\(Engines.catalogue.count)", "engines")
                Spacer()
                Button { AppDelegate.shared.showSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .controlSize(.large).glassButton()
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .glassCard(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                if center.jobs.contains(where: \.isFinished) {
                    Button("Clear") { withAnimation { center.clearFinished() } }.buttonStyle(.link)
                }
            }
            if center.jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title).foregroundStyle(.tertiary)
                    Text("Converted files appear here").foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    GlassGroup(spacing: 10) {
                        VStack(spacing: 10) {
                            ForEach(center.jobs) { job in
                                JobRow(job: job)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .glassCard(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func refreshCounts() {
        let all = ActionRegistry.shared.all
        counts = (all.filter { $0.kind == .convert }.count, all.filter { $0.kind == .tool }.count)
    }
}

// MARK: - Settings

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", wheel = "Wheel", engines = "Engines", recipes = "Recipes"
        var id: String { rawValue }
        /// Debug: `--settings-tab engines` opens straight onto a tab.
        static var launchTab: Tab {
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--settings-tab"), i + 1 < a.count,
               let t = Tab.allCases.first(where: { $0.rawValue.lowercased() == a[i + 1].lowercased() }) { return t }
            return .general
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .wheel: return "circle.hexagongrid"
            case .engines: return "puzzlepiece.extension"
            case .recipes: return "text.badge.plus"
            }
        }
    }

    @State private var tab: Tab = Tab.launchTab
    @Namespace private var selection

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 16) {
                tabBar
                ScrollView {
                    VStack(spacing: 14) {
                        switch tab {
                        case .general: GeneralTab()
                        case .wheel: WheelTab()
                        case .engines: EnginesTab()
                        case .recipes: RecipesTab()
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 22)
                }
                .scrollContentBackground(.hidden)
            }
            .padding(.top, 30)
        }
        .frame(width: 600, height: 620)
        .fontDesign(.rounded)
    }

    private var tabBar: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = t } } label: {
                        Label(t.rawValue, systemImage: t.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .font(.callout.weight(tab == t ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(tab == t ? Theme.accentDeep : Color.primary)
                            .background {
                                if tab == t {
                                    Color.clear.glassCard(Capsule(), tint: Theme.accent.opacity(0.35), interactive: true)
                                        .matchedGeometryEffect(id: "tab", in: selection)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glassCard(Capsule())
        }
    }
}

/// A titled glass card that groups related rows.
private struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassCard(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject var s = AppSettings.shared
    @State private var cliMessage = ""

    var body: some View {
        SettingsCard(title: "Output") {
            SettingsRow(title: "Save results") {
                Picker("", selection: $s.outputMode) {
                    Text("Next to the original").tag(OutputMode.sameFolder)
                    Text("In a specific folder").tag(OutputMode.custom)
                }.labelsHidden().fixedSize()
            }
            if s.outputMode == .custom {
                SettingsRow(title: s.customOutputPath.isEmpty ? "No folder chosen" : s.customOutputPath) {
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { s.customOutputPath = u.path }
                    }.glassButton()
                }
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Move originals to Trash", subtitle: "After a successful conversion") {
                Toggle("", isOn: $s.trashOriginals).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
            SettingsRow(title: "Reveal results in Finder") {
                Toggle("", isOn: $s.revealWhenDone).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
        }
        SettingsCard(title: "System") {
            SettingsRow(title: "Launch at login") {
                Toggle("", isOn: $s.launchAtLogin).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Command palette", subtitle: "Opens for the current Finder selection") {
                Text("⌥⌘T").font(.callout.monospaced().weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassCard(Capsule())
            }
            Divider().opacity(0.4)
            SettingsRow(title: "Command-line tool", subtitle: cliMessage.isEmpty ? "Use Mer from Terminal as `mer`" : cliMessage) {
                Button("Install `mer`") { cliMessage = AppDelegate.installCLI() }.glassButton()
            }
        }
    }
}

private struct WheelTab: View {
    @ObservedObject var s = AppSettings.shared

    var body: some View {
        SettingsCard(title: "Drag wheel") {
            SettingsRow(title: "Show the wheel while dragging files", subtitle: "Hold a key after you start dragging") {
                Toggle("", isOn: $s.wheelEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
        }
        SettingsCard(title: "Keys") {
            keyRow("Conversions", "Turn the file into another format", $s.convertKey)
            Divider().opacity(0.4)
            keyRow("File tools", "Compress, crop, trim, merge …", $s.toolKey)
            Divider().opacity(0.4)
            keyRow("File actions", "AirDrop, float, copy, move …", $s.fileKey)
        }
        SettingsCard(title: "How it works") {
            Text("Start dragging a file from Finder, then press a key. The wheel stays open until you drop on a slice or let go. Hover “More” to page through long lists, and press another key to switch layers.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func keyRow(_ title: String, _ subtitle: String, _ binding: Binding<ModifierChoice>) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Picker("", selection: binding) { ForEach(ModifierChoice.allCases) { Text($0.label).tag($0) } }
                .labelsHidden().fixedSize()
        }
    }
}

private struct EnginesTab: View {
    @ObservedObject private var installer = EngineInstaller.shared
    @State private var tick = 0

    var body: some View {
        SettingsCard(title: nil) {
            Text("Mer converts the common formats on its own. Optional engines unlock many more and are detected automatically.")
                .font(.callout).foregroundStyle(.secondary)
            if installer.brewPath == nil {
                Label("Installing engines needs Homebrew (brew.sh).", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(Theme.accentDeep)
            }
        }
        ForEach(Engines.catalogue) { e in engineCard(e) }
        HStack {
            Spacer()
            Button { ActionRegistry.shared.reload(); tick += 1 } label: { Label("Re-scan", systemImage: "arrow.clockwise") }.glassButton()
        }
        .id(tick)
    }

    private func engineCard(_ e: EngineInfo) -> some View {
        let state = installer.state(for: e)
        return SettingsCard(title: nil) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: e.installed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title3).foregroundStyle(e.installed ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.name).font(.body.weight(.semibold))
                    Text(e.unlocks).font(.caption).foregroundStyle(.secondary)
                    switch state {
                    case .installing(let line):
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            .padding(.top, 2)
                    case .failed(let msg):
                        Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3)
                    default: EmptyView()
                    }
                }
                Spacer(minLength: 8)
                switch state {
                case .installing: Button("Cancel") { installer.cancel(e) }.glassButton()
                case .done: Text("Installed").font(.caption).foregroundStyle(.secondary)
                default:
                    Button("Install") { installer.install(e) }.tint(Theme.accent).glassButton(prominent: true)
                        .disabled(installer.brewPath == nil)
                }
            }
        }
    }
}

private struct RecipesTab: View {
    @State private var count = RecipeInfo.userCount()

    var body: some View {
        SettingsCard(title: nil) {
            Text("Recipes teach Mer new conversions by calling any command-line tool. Drop a `.json` file in the Recipes folder and press Reload.")
                .font(.callout).foregroundStyle(.secondary)
        }
        SettingsCard(title: "Example") {
            Text(RecipeInfo.example).font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Placeholders: {tool} {input} {output} {inputs} {name} {dir} {tmpdir} {param:key}")
                .font(.caption).foregroundStyle(.secondary)
        }
        SettingsCard(title: "\(count) custom recipe\(count == 1 ? "" : "s") loaded") {
            HStack(spacing: 10) {
                Button("Create Example") { RecipeInfo.writeExample(); count = RecipeInfo.userCount() }.glassButton()
                Button("Open Folder") { RecipeInfo.openFolder() }.glassButton()
                Spacer()
                Button("Reload") { ActionRegistry.shared.reload(); count = RecipeInfo.userCount() }.tint(Theme.accent).glassButton(prominent: true)
            }
        }
    }
}

enum RecipeInfo {
    static var dir: URL { Tooling.supportDirectory.appendingPathComponent("Recipes", isDirectory: true) }

    static let example = """
    {
      "id": "user.image.avif-via-magick",
      "title": "AVIF (ImageMagick)",
      "kind": "convert",
      "category": "image",
      "inputs": ["png", "jpg", "heic"],
      "output": "avif",
      "requires": "magick",
      "command": ["{tool}", "{input}", "-quality", "60", "{output}"]
    }
    """

    static func userCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    static func writeExample() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("example-avif.json")
        if !FileManager.default.fileExists(atPath: url.path) { try? example.write(to: url, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
