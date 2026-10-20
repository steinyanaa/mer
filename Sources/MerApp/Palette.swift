import AppKit
import SwiftUI
import MerCore

enum ActionLauncher {
    /// Runs the action, asking for parameters first when it has any.
    @MainActor
    static func launch(_ action: MerAction, files: [URL]) {
        if action.params.isEmpty {
            Runner.run(action, files: files)
        } else {
            PaletteController.shared.present(files: files, pending: action)
        }
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PaletteController {
    static let shared = PaletteController()
    private var panel: KeyPanel?
    private var model: PaletteModel?

    func present(files: [URL], pending: MerAction? = nil) {
        guard !files.isEmpty else { return }
        close()
        let model = PaletteModel(files: files, pending: pending)
        model.onClose = { [weak self] in self?.close() }
        self.model = model

        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 608, height: 488),
                         styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: PaletteView(model: model))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 304, y: f.midY - 134))
        }
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let p = panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: p)
            p.orderOut(nil)
        }
        panel = nil
        model = nil
    }
}

@MainActor
final class PaletteModel: ObservableObject {
    enum Scope: String, CaseIterable { case all = "All", convert = "Convert", tool = "Tools" }

    let files: [URL]
    @Published var query = ""
    @Published var scope: Scope = .all
    @Published var selected = 0
    @Published var pending: MerAction?
    @Published var values: [String: String] = [:]
    var onClose: () -> Void = {}

    init(files: [URL], pending: MerAction?) {
        self.files = files
        if let pending { begin(pending) }
    }

    var results: [MerAction] {
        let kind: ActionKind? = scope == .convert ? .convert : (scope == .tool ? .tool : nil)
        let base = ActionRegistry.shared.actions(for: files, kind: kind)
        return ActionRegistry.shared.search(query, in: base)
    }

    func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selected = (selected + delta + n) % n
    }

    func cycleScope() {
        let all = Scope.allCases
        scope = all[(all.firstIndex(of: scope)! + 1) % all.count]
        selected = 0
    }

    func choose(_ action: MerAction) {
        if action.params.isEmpty { run(action) } else { begin(action) }
    }

    func chooseSelected() {
        let r = results
        guard selected < r.count else { return }
        choose(r[selected])
    }

    private func begin(_ action: MerAction) {
        pending = action
        values = Dictionary(uniqueKeysWithValues: action.params.map { ($0.key, $0.defaultValue) })
    }

    func run(_ action: MerAction) {
        Runner.run(action, files: files, params: values)
        onClose()
    }
}

struct PaletteView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var model: PaletteModel
    @FocusState private var searchFocused: Bool
    @State private var appeared = false

    private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            if let action = model.pending { paramForm(action) } else { searchAndList }
        }
        .frame(width: 580, height: 460)
        .fontDesign(.rounded)
        .glassCard(shape)
        .padding(14)                                   // room for the glass shadow
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            searchFocused = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true }
        }
        .onKeyPress(.escape) {
            if model.pending != nil { model.pending = nil } else { model.onClose() }
            return .handled
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.files[0].path))
                .resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.files.count == 1 ? model.files[0].lastPathComponent : Loc.f("%d files", model.files.count))
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(model.files.count == 1 ? model.files[0].deletingLastPathComponent().path
                                            : model.files.map(\.lastPathComponent).prefix(3).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if model.pending == nil {
                Picker("", selection: $model.scope) {
                    ForEach(PaletteModel.Scope.allCases, id: \.self) { Text(Loc.t($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                .onChange(of: model.scope) { model.selected = 0 }
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
    }

    // MARK: search + list

    private var searchAndList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Loc.t("Search formats and tools"), text: $model.query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onSubmit { model.chooseSelected() }
                    .onChange(of: model.query) { model.selected = 0 }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassCard(Capsule())
            .padding(.horizontal, 16).padding(.bottom, 6)

            let results = model.results
            if results.isEmpty {
                Spacer()
                Text(Loc.t("Nothing matches")).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, a in
                                row(a, selected: i == model.selected)
                                    .id(a.id)
                                    .onTapGesture { model.choose(a) }
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selected) { _, i in
                        if i < results.count { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(results[i].id) } }
                    }
                }
            }
            HStack(spacing: 12) {
                hint("↑↓", Loc.t("navigate")); hint("↩", Loc.t("run")); hint("⇥", Loc.t("switch")); hint("esc", Loc.t("close"))
                Spacer()
                Text("\(results.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.tab) { model.cycleScope(); return .handled }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption2.monospaced().weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ a: MerAction, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.symbol ?? a.category.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28)
                .foregroundStyle(selected ? Theme.accentDeep : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.displayTitle).font(.body.weight(.medium))
                if let s = a.displaySubtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !a.params.isEmpty { Image(systemName: "slider.horizontal.3").font(.caption) }
            Text(a.category.displayTitle).font(.caption2.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? Theme.accent.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
            Text(a.kind == .convert ? Loc.t("Convert") : Loc.t("Tool")).font(.caption2)
                .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(Color.primary)
        .background {
            if selected {
                Color.clear
                    .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Theme.accent.opacity(0.38), interactive: true)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: parameter form

    private func paramForm(_ action: MerAction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(action.displayTitle, systemImage: action.symbol ?? action.category.symbol)
                .font(.title3.weight(.semibold)).symbolRenderingMode(.hierarchical)
            if let s = action.displaySubtitle { Text(s).foregroundStyle(.secondary) }
            ForEach(action.params) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.displayLabel).font(.caption).foregroundStyle(.secondary)
                    TextField(p.displayLabel, text: Binding(get: { model.values[p.key] ?? "" }, set: { model.values[p.key] = $0 }))
                        .textFieldStyle(.plain).padding(.horizontal, 14).padding(.vertical, 9)
                        .glassCard(Capsule())
                        .onSubmit { model.run(action) }
                }
            }
            Spacer()
            HStack {
                Button(Loc.t("Back")) { model.pending = nil }.keyboardShortcut(.cancelAction).glassButton()
                Spacer()
                Button(Loc.t("Run")) { model.run(action) }.keyboardShortcut(.defaultAction).tint(Theme.accent).glassButton(prominent: true)
            }
            .controlSize(.large)
        }
        .padding(22)
    }
}
