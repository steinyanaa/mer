import AppKit
import SwiftUI
import MerCore

struct WheelItem {
    enum Payload {
        case action(MerAction)
        case file(FileAction)
        case more, back
    }
    let title: String
    let symbol: String?
    let payload: Payload
}

// MARK: - Glass model & view

final class WheelGlassModel: ObservableObject {
    struct Entry: Identifiable { let id: Int; let title: String; let symbol: String }
    @Published var entries: [Entry] = []
    @Published var hover: Int?
    @Published var layerTitle = "Convert"
    @Published var fileLabel = ""
    @Published var fileIcon: NSImage?
    @Published var hint = ""
    @Published var emptyMessage = ""
    @Published var shown = false
}

/// One petal of the ring: constant-width gaps between neighbours and softly rounded corners.
struct SectorShape: Shape {
    let index: Int, count: Int
    let inner: CGFloat, outer: CGFloat
    var gap: CGFloat = 7
    var rounding: CGFloat = 11

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let step = 360.0 / Double(max(count, 1))
        let r0 = inner + rounding, r1 = outer - rounding
        let h = Double(count > 1 ? gap / 2 + rounding : 0)          // perpendicular offset of each side edge
        // an edge offset by h from the radial line meets a circle of radius R at angle asin(h / R) from it
        func inset(_ r: CGFloat) -> Double { asin(min(h / Double(r), 0.99)) * 180 / .pi }
        let s0 = -90 + Double(index) * step, s1 = s0 + step
        func pt(_ r: CGFloat, _ deg: Double) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(cos(deg * .pi / 180)), y: c.y + r * CGFloat(sin(deg * .pi / 180)))
        }
        var p = Path()
        p.addArc(center: c, radius: r1, startAngle: .degrees(s0 + inset(r1)), endAngle: .degrees(s1 - inset(r1)), clockwise: false)
        p.addLine(to: pt(r0, s1 - inset(r0)))
        p.addArc(center: c, radius: r0, startAngle: .degrees(s1 - inset(r0)), endAngle: .degrees(s0 + inset(r0)), clockwise: true)
        p.closeSubpath()
        let rim = p.strokedPath(StrokeStyle(lineWidth: rounding * 2, lineCap: .round, lineJoin: .round))
        return p.union(rim)
    }
}

struct WheelGlassView: View {
    @ObservedObject var model: WheelGlassModel
    private let d: CGFloat = (WheelView.outerRadius + 6) * 2

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassGroup(spacing: 0) {
                ZStack {
                    ForEach(model.entries) { e in sector(e) }
                    core
                }
                .frame(width: d, height: d)
            }
            .position(x: WheelView.size.width / 2, y: WheelView.size.height - WheelView.ringCenter.y)

            if model.entries.isEmpty {
                Text(model.emptyMessage).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    .position(x: WheelView.size.width / 2, y: WheelView.size.height - WheelView.ringCenter.y + 110)
            }
            if !model.hint.isEmpty {
                Text(model.hint).font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 15).padding(.vertical, 6)
                    .glassCard(Capsule())
                    .position(x: WheelView.size.width / 2, y: WheelView.size.height - 23)
            }
        }
        .frame(width: WheelView.size.width, height: WheelView.size.height)
        .scaleEffect(model.shown ? 1 : 0.86, anchor: UnitPoint(x: 0.5, y: 1 - WheelView.ringCenter.y / WheelView.size.height))
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: model.shown)
        .allowsHitTesting(false)
        .environment(\.controlActiveState, .key)      // non-key panels get a flatter, more frosted glass
    }

    private func sector(_ e: WheelGlassModel.Entry) -> some View {
        let n = model.entries.count
        let hovered = model.hover == e.id
        let step = 360.0 / Double(n)
        let mid = (-90 + (Double(e.id) + 0.5) * step) * .pi / 180
        let r = (WheelView.outerRadius + WheelView.innerRadius) / 2 + 4
        let c = d / 2
        let shape = SectorShape(index: e.id, count: n, inner: WheelView.innerRadius + 4, outer: WheelView.outerRadius + 4)
        return ZStack {
            VStack(spacing: 3) {
                Image(systemName: e.symbol).font(.system(size: hovered ? 22 : 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(e.title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(2).multilineTextAlignment(.center).frame(width: n >= 9 ? 74 : 92)
            }
            .foregroundStyle(Color.primary)
            .position(x: c + cos(mid) * r, y: c + sin(mid) * r)
        }
        .frame(width: d, height: d)
        .glassShape(shape, tint: hovered ? Theme.accent.opacity(0.55) : nil, interactive: true, clear: true)
        .overlay { sheen(shape, hovered: hovered) }
        .overlay { rim(shape, hovered: hovered) }
        .background { shape.fill(Color.black.opacity(hovered ? 0.14 : 0.08)).blur(radius: 10).offset(y: 8) }
        .animation(.easeOut(duration: 0.16), value: hovered)
    }

    /// Thick-glass reflection: a soft diagonal highlight across the upper half and a faint caustic along the bottom.
    private func sheen<S: Shape>(_ shape: S, hovered: Bool) -> some View {
        shape.fill(LinearGradient(stops: [.init(color: .white.opacity(hovered ? 0.55 : 0.34), location: 0),
                                          .init(color: .white.opacity(0.06), location: 0.42),
                                          .init(color: .clear, location: 0.62),
                                          .init(color: .white.opacity(0.16), location: 1)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing))
            .allowsHitTesting(false)
    }

    /// Specular rim: bright on the upper-left edge, fading across, with a faint return light bottom-right.
    private func rim<S: Shape>(_ shape: S, hovered: Bool) -> some View {
        shape.stroke(
            LinearGradient(stops: [.init(color: .white.opacity(hovered ? 0.95 : 0.75), location: 0),
                                   .init(color: .white.opacity(0.08), location: 0.45),
                                   .init(color: .white.opacity(0.35), location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1.6)
    }

    private var core: some View {
        VStack(spacing: 2) {
            if let icon = model.fileIcon { Image(nsImage: icon).resizable().frame(width: 46, height: 46) }
            Text(model.layerTitle.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accentDeep).padding(.top, 2)
            Text(model.fileLabel).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: WheelView.innerRadius * 1.6)
        }
        .frame(width: WheelView.innerRadius * 2 - 6, height: WheelView.innerRadius * 2 - 6)
        .glassShape(Circle(), tint: Theme.accent.opacity(0.30), clear: true)
        .overlay { sheen(Circle(), hovered: false) }
        .overlay { rim(Circle(), hovered: false) }
        .background { Circle().fill(Color.black.opacity(0.10)).blur(radius: 9).offset(y: 6) }
    }
}

// MARK: - Drag layer (transparent; hit-testing and drop only)

final class WheelView: NSView {
    static let size = NSSize(width: 440, height: 490)
    static let ringCenter = NSPoint(x: 220, y: 270)
    static let outerRadius: CGFloat = 200
    static let innerRadius: CGFloat = 76
    private var center: NSPoint { Self.ringCenter }

    let model: WheelGlassModel
    var items: [WheelItem] = [] {
        didSet {
            hover = nil
            model.entries = items.enumerated().map { i, item in
                let symbol: String
                switch item.payload {
                case .more: symbol = "chevron.right.circle"
                case .back: symbol = "chevron.left.circle"
                default: symbol = item.symbol ?? "circle"
                }
                return .init(id: i, title: item.title, symbol: symbol)
            }
        }
    }
    var onSelect: ((WheelItem) -> Void)?
    var onPage: ((WheelItem.Payload) -> Void)?

    private var hover: Int? { didSet { if hover != oldValue { model.hover = hover; scheduleDwell() } } }
    private var dwell: Timer?

    init(frame: NSRect, model: WheelGlassModel) {
        self.model = model
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    func debugHover(_ i: Int?) { hover = i }

    // MARK: Hit testing

    private func index(at point: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let r = hypot(dx, dy)
        guard r >= Self.innerRadius && r <= Self.outerRadius + 10 else { return nil }
        var angle = atan2(dx, dy)           // clockwise from 12 o'clock
        if angle < 0 { angle += 2 * .pi }
        let i = Int(angle / (2 * .pi / Double(items.count)))
        return min(i, items.count - 1)
    }

    private func scheduleDwell() {
        dwell?.invalidate()
        guard let h = hover, h < items.count else { return }
        switch items[h].payload {
        case .more, .back:
            let payload = items[h].payload
            dwell = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                self?.onPage?(payload)
            }
        default: break
        }
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DragLog.write("draggingEntered wheel")
        return track(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover = nil }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        hover = index(at: convert(sender.draggingLocation, from: nil))
        return hover == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hover != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DragLog.write("performDragOperation at \(convert(sender.draggingLocation, from: nil))")
        guard let i = index(at: convert(sender.draggingLocation, from: nil)), i < items.count else { return false }
        let item = items[i]
        switch item.payload {
        case .more, .back: onPage?(item.payload); return false   // paging is hover-only; a drop there does nothing
        default: onSelect?(item); return true
        }
    }
}

// MARK: - Controller

/// Becomes key without activating the app, so Liquid Glass renders in its full (active-window) form
/// while the drag keeps belonging to Finder.
private final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WheelController {
    static let shared = WheelController()

    private let panel: GlassPanel
    private let model = WheelGlassModel()
    private let view: WheelView
    private(set) var isVisible = false
    private var files: [URL] = []
    private var layer: WheelLayer = .convert
    private var all: [WheelItem] = []
    private var page = 0

    private init() {
        panel = GlassPanel(contentRect: NSRect(origin: .zero, size: WheelView.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        view = WheelView(frame: NSRect(origin: .zero, size: WheelView.size), model: model)
        let container = NSView(frame: NSRect(origin: .zero, size: WheelView.size))
        let host = NSHostingView(rootView: WheelGlassView(model: model))
        host.frame = container.bounds
        host.sizingOptions = []
        container.addSubview(host)
        container.addSubview(view)
        panel.contentView = container

        view.onSelect = { [weak self] item in self?.handle(item) }
        view.onPage = { [weak self] payload in
            guard let self else { return }
            if case .more = payload { self.page += 1 } else { self.page = max(0, self.page - 1) }
            self.refreshPage()
        }
    }

    func show(files: [URL], layer: WheelLayer, at mouse: NSPoint) {
        self.files = files
        var origin = NSPoint(x: mouse.x - 220, y: mouse.y - 270)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX - 10), f.maxX - WheelView.size.width + 10)
            origin.y = min(max(origin.y, f.minY - 30), f.maxY - WheelView.size.height + 10)
        }
        panel.setFrameOrigin(origin)

        model.fileIcon = NSWorkspace.shared.icon(forFile: files[0].path)
        model.fileLabel = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        setLayer(layer)

        if !isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.makeKey()
            isVisible = true
            DispatchQueue.main.async { self.model.shown = true }
        }
    }

    func setLayer(_ newLayer: WheelLayer) {
        layer = newLayer
        page = 0
        let s = AppSettings.shared
        model.layerTitle = newLayer.title
        let others = WheelLayer.allCases.filter { $0 != newLayer && s.key(for: $0) != .none }
        let hint = others.map { "\(s.key(for: $0).label.prefix(1))  \($0.title)" }.joined(separator: "      ")
        model.hint = hint

        switch newLayer {
        case .convert, .tool:
            let kind: ActionKind = newLayer == .convert ? .convert : .tool
            all = ActionRegistry.shared.actions(for: files, kind: kind).map {
                WheelItem(title: $0.title, symbol: $0.symbol ?? $0.category.symbol, payload: .action($0))
            }
            model.emptyMessage = newLayer == .convert ? "No conversions for this file" : "No tools for this file"
        case .file:
            all = FileAction.allCases.map { WheelItem(title: $0.title, symbol: $0.symbol, payload: .file($0)) }
        }
        refreshPage()
    }

    private func refreshPage() {
        view.items = Self.paginate(all, page: page)
    }

    /// 9 slots per page: items plus ‹ Back / More › sectors where needed.
    static func paginate(_ items: [WheelItem], page: Int, slots: Int = 9) -> [WheelItem] {
        if items.count <= slots { return items }
        let more = WheelItem(title: "More", symbol: nil, payload: .more)
        let back = WheelItem(title: "Back", symbol: nil, payload: .back)
        var start = 0
        for p in 0..<page { start += (p == 0 ? slots - 1 : slots - 2) }
        let firstPage = page == 0
        let capacity = firstPage ? slots - 1 : slots - 2
        let remaining = items.count - start
        if remaining <= (firstPage ? slots : slots - 1) {
            let slice = Array(items[start...])
            return firstPage ? slice : [back] + slice
        }
        let slice = Array(items[start..<(start + capacity)])
        return firstPage ? slice + [more] : [back] + slice + [more]
    }

    /// Debug: highlight a slice without dragging.
    func debugHover(_ i: Int?) { view.debugHover(i) }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        model.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        }
    }

    private func handle(_ item: WheelItem) {
        let urls = files
        hide()
        switch item.payload {
        case .action(let action):
            ActionLauncher.launch(action, files: urls)
        case .file(let fa):
            // Let the drag session finish before presenting UI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fa.perform(urls) }
        default: break
        }
    }
}

// MARK: - Diagnostics

/// Appends to ~/Library/Logs/Mer/drag.log so drag-detection problems can be diagnosed without a debugger.
enum DragLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drag.log")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Drag watcher

@MainActor
final class DragWatcher {
    static let shared = DragWatcher()

    private var monitors: [Any] = []
    private var downCount = 0
    private var tracking = false
    private var timer: Timer?
    private var urls: [URL] = []
    private var currentLayer: WheelLayer?
    private var sawDragThisPress = false

    func start() {
        guard monitors.isEmpty else { return }
        let s = AppSettings.shared
        DragLog.write("watcher start — wheelEnabled=\(s.wheelEnabled) keys: convert=\(s.convertKey.rawValue) tool=\(s.toolKey.rawValue) file=\(s.fileKey.rawValue)")
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e.type) } }
        }) { monitors.append(m); DragLog.write("global monitor installed") }
        else { DragLog.write("global monitor FAILED to install") }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endTracking()
    }

    private func handle(_ type: NSEvent.EventType) {
        guard AppSettings.shared.wheelEnabled else { return }
        switch type {
        case .leftMouseDown:
            downCount = NSPasteboard(name: .drag).changeCount
            sawDragThisPress = false
        case .leftMouseDragged:
            guard !tracking else { return }
            let pb = NSPasteboard(name: .drag)
            if !sawDragThisPress {
                sawDragThisPress = true
                DragLog.write("first drag event — pasteboard changeCount \(downCount) → \(pb.changeCount), types=\(pb.types?.map(\.rawValue).prefix(4) ?? [])")
            }
            guard pb.changeCount != downCount else { return }
            downCount = pb.changeCount
            let found = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            DragLog.write("drag pasteboard changed — file URLs: \(found.count)")
            guard !found.isEmpty else { return }
            urls = found
            beginTracking()
        case .leftMouseUp:
            endTracking()
        default: break
        }
    }

    private func beginTracking() {
        DragLog.write("tracking drag of \(urls.count) file(s) — hold a modifier key to open the wheel")
        tracking = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func endTracking() {
        tracking = false
        currentLayer = nil
        timer?.invalidate(); timer = nil
        // Give performDragOperation a moment to read the hover state before hiding.
        if WheelController.shared.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WheelController.shared.hide() }
        }
    }

    private func tick() {
        guard tracking else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 { endTracking(); return }
        let wanted = AppSettings.shared.layer(for: NSEvent.modifierFlags)
        if let wanted, wanted != currentLayer {
            DragLog.write("modifier → layer \(wanted) (visible=\(WheelController.shared.isVisible))")
            currentLayer = wanted
            if WheelController.shared.isVisible { WheelController.shared.setLayer(wanted) }
            else { WheelController.shared.show(files: urls, layer: wanted, at: NSEvent.mouseLocation) }
        }
    }
}
