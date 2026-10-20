import SwiftUI
import AppKit

@available(macOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool, clear: Bool = false) -> Glass {
    var g = clear ? Glass.clear : Glass.regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}

/// Liquid Glass on macOS 26+, frosted material on earlier systems.
extension View {
    @ViewBuilder
    func glassCard<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background(tint?.opacity(0.35) ?? .clear, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            // .glassProminent darkens the tint into a muddy bronze; a tinted .glass keeps the airy look.
            self.buttonStyle(.glass).fontWeight(prominent ? .semibold : .regular)
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Merges neighbouring glass shapes into one fluid surface (macOS 26+), plain stack otherwise.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Soft sea haze behind windows: sky, sand, seafoam and deep water over a milky base, so glass has something gentle to refract.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.base
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Circle().fill(Theme.sky.opacity(dark ? 0.55 : 0.80)).frame(width: w * 0.95)
                    .blur(radius: 80).offset(x: -w * 0.38, y: -h * 0.30)
                Circle().fill(Theme.sand.opacity(dark ? 0.30 : 0.80)).frame(width: w * 0.80)
                    .blur(radius: 90).offset(x: w * 0.42, y: h * 0.52)
                Circle().fill(Theme.mint.opacity(dark ? 0.45 : 0.65)).frame(width: w * 0.60)
                    .blur(radius: 80).offset(x: -w * 0.30, y: h * 0.62)
                Circle().fill(Theme.deep.opacity(dark ? 0.50 : 0.60)).frame(width: w * 0.55)
                    .blur(radius: 80).offset(x: w * 0.50, y: -h * 0.20)
            }
            // milky veil gives the airy, slightly overexposed look
            LinearGradient(colors: [.white.opacity(dark ? 0.02 : 0.40), .white.opacity(dark ? 0 : 0.05)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// NSGlassEffectView when available, NSVisualEffectView otherwise. Used by the AppKit wheel.
enum NativeGlass {
    static func make(cornerRadius: CGFloat, tint: NSColor? = nil, clear: Bool = false) -> NSView {
        if #available(macOS 26.0, *) {
            let v = NSGlassEffectView()
            v.cornerRadius = cornerRadius
            v.tintColor = tint
            v.style = clear ? .clear : .regular
            return v
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        if let tint { v.layer?.backgroundColor = tint.cgColor }
        return v
    }
}

extension View {
    /// Glass for arbitrary (non-insettable) shapes such as the wheel's sectors.
    @ViewBuilder
    func glassShape<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, clear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive, clear: clear), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .background(tint?.opacity(0.35) ?? .clear, in: shape)
        }
    }
}

/// Floating surface (job HUD, Float shelf) that renders full-fidelity Liquid Glass without taking keyboard focus.
///
/// Liquid Glass drops to a flat, heavily frosted look in windows that AppKit does not consider active. Making the panel key
/// fixes that but steals keystrokes from whatever app the user is typing in. AppKit also treats a window that reports
/// *main appearance* as active for glass, so we claim that appearance while never becoming key or main: the frontmost app,
/// its first responder and the app's activation state stay untouched. `hasMainAppearance`/`hasKeyAppearance` are not in the
/// public headers; if they ever go away the override is simply never called and the glass falls back to the frosted look.
class GlassSurfacePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    @objc(hasMainAppearance) var glassHasMainAppearance: Bool { true }
    @objc(hasKeyAppearance) var glassHasKeyAppearance: Bool { true }

    convenience init(size: CGSize, level: NSWindow.Level) {
        self.init(contentRect: NSRect(origin: .zero, size: size),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // the glass draws its own soft shadow inside the (padded) window
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

/// Room around a glass card so its own shadow is not clipped into a visible rectangle by the window bounds.
enum GlassSurface {
    static let shadowPad: CGFloat = 36
}
