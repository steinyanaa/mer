import AppKit
import SwiftUI
import Carbon.HIToolbox
import MerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Loc.registerAppTable(LocZhApp.table)
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        buildMainMenu()
        buildStatusItem()
        // Where did the system actually place the menu-bar icon? (off-screen = squeezed out of a crowded bar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.logStatusItemPlacement() }
        _ = HUDController.shared
        if !CommandLine.arguments.contains("--demo-wheel") { DragWatcher.shared.start() }

        HotKey.register(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.convertFinderSelection()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        // Debug helper: `Mer --demo-wheel <file> [convert|tool|file]` shows the wheel in the middle of the screen.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-wheel"), i + 1 < args.count {
            let layer: WheelLayer = args.count > i + 2 ? (args[i + 2] == "tool" ? .tool : (args[i + 2] == "file" ? .file : .convert)) : .convert
            let f = (NSScreen.main ?? NSScreen.screens[0]).frame
            WheelController.shared.show(files: [URL(fileURLWithPath: args[i + 1])], layer: layer, at: NSPoint(x: f.midX, y: f.midY))
            if let h = args.firstIndex(of: "--demo-hover"), h + 1 < args.count, let n = Int(args[h + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WheelController.shared.debugHover(n) }
            }
            return
        }
        // Debug helpers: `--demo-hud <file>` runs a conversion + toast; `--demo-float <file>` pins a Float card.
        if let i = args.firstIndex(of: "--demo-hud"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            HUDController.shared.toast(Loc.t("Copied to clipboard"))
            debugFocusReport()
            if let a = ActionRegistry.shared.actions(for: [url], kind: .convert).first {
                JobCenter.shared.submit(a, inputs: [url])
            }
            return
        }
        if let i = args.firstIndex(of: "--demo-float"), i + 1 < args.count {
            FloatShelf.shared.add([URL(fileURLWithPath: args[i + 1])])
            debugFocusReport()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo-palette"), i + 1 < CommandLine.arguments.count {
            PaletteController.shared.present(files: [URL(fileURLWithPath: CommandLine.arguments[i + 1])])
            return
        }
        if CommandLine.arguments.contains("--open-settings") { showSettings(); return }
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        PaletteController.shared.present(files: urls)
    }

    private func logStatusItemPlacement() {
        guard let item = statusItem else { DragLog.write("status item: nil"); return }
        let w = item.button?.window
        let screen = w?.screen ?? NSScreen.main
        DragLog.write("status item: isVisible=\(item.isVisible) window=\(w?.frame.debugDescription ?? "nil") windowVisible=\(w?.isVisible ?? false) screen=\(screen?.frame.debugDescription ?? "nil") activation=\(NSApp.activationPolicy().rawValue)")
    }

    /// Rebuilds everything AppKit owns (menus, window titles) after the interface language changes.
    func languageChanged() {
        buildMainMenu()
        buildStatusMenu()
        mainWindow?.title = "Mer"
        settingsWindow?.title = Loc.t("Mer Settings")
    }

    // MARK: Windows

    func showMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Mer"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 520, height: 600)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView())
            w.center()
            mainWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = Loc.t("Mer Settings")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Status item & menus

    private func buildStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Mer")
        }
        buildStatusMenu()
    }

    /// (Re)builds only the menu, so a language change never creates a second menu-bar icon.
    private func buildStatusMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = []) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            menu.addItem(i)
        }
        item(Loc.t("Open Mer"), #selector(openMain))
        item(Loc.t("Convert Files…"), #selector(chooseFilesAction))
        item(Loc.t("Convert Finder Selection"), #selector(convertSelectionAction), key: "t", mods: [.command, .option])
        menu.addItem(.separator())
        let wheel = NSMenuItem(title: Loc.t("Drag Wheel"), action: #selector(toggleWheel(_:)), keyEquivalent: "")
        wheel.target = self
        wheel.state = AppSettings.shared.wheelEnabled ? .on : .off
        menu.addItem(wheel)
        item(Loc.t("Test Wheel"), #selector(testWheel))
        item(Loc.t("Open Drag Log"), #selector(openLog))
        item(Loc.t("Settings…"), #selector(openSettings), key: ",", mods: .command)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Loc.t("Quit Mer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func buildMainMenu() {
        // Accessory apps have no visible menu bar, but text fields still need Edit shortcuts.
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: Loc.t("Quit Mer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: Loc.t("Edit")); editItem.submenu = edit
        edit.addItem(NSMenuItem(title: Loc.t("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: Loc.t("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: Loc.t("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: Loc.t("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: Loc.t("Window")); winItem.submenu = win
        win.addItem(NSMenuItem(title: Loc.t("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        NSApp.mainMenu = main
    }

    @objc private func testWheel() {
        // Shows the wheel at the centre of the screen for a few seconds so the look can be checked without dragging.
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            WheelController.shared.show(files: [Bundle.main.bundleURL], layer: .file, at: NSPoint(x: f.midX, y: f.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { WheelController.shared.hide() }
        }
    }
    @objc private func openLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mer/drag.log")
        NSWorkspace.shared.open(url)
    }
    @objc private func openMain() { showMainWindow() }
    @objc private func openSettings() { showSettings() }
    @objc private func chooseFilesAction() { chooseFiles() }
    @objc private func convertSelectionAction() { convertFinderSelection() }
    @objc private func toggleWheel(_ sender: NSMenuItem) {
        AppSettings.shared.wheelEnabled.toggle()
        sender.state = AppSettings.shared.wheelEnabled ? .on : .off
    }

    // MARK: Entry points

    func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.prompt = Loc.t("Choose")
        if p.runModal() == .OK { PaletteController.shared.present(files: p.urls) }
    }

    func convertFinderSelection() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == "com.apple.finder" {
            let urls = FinderSelection.get()
            if !urls.isEmpty { PaletteController.shared.present(files: urls); return }
            HUDController.shared.toast(Loc.t("Select a file in Finder first"))
            return
        }
        chooseFiles()
    }

    /// macOS Services entry: right-click → Services → "Convert with Mer".
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { PaletteController.shared.present(files: urls) }
    }

    // MARK: Helpers

    nonisolated static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let result = urls
            MainActor.assumeIsolated { if !result.isEmpty { completion(result) } }
        }
    }

    static func runInTerminal(_ command: String) {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    static func installCLI() -> String {
        guard let cli = Bundle.main.url(forResource: "mer", withExtension: nil) else {
            return Loc.t("Not running from a packaged app — build with Scripts/bundle.sh.")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("mer")
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
            return Loc.t("Installed at ~/.local/bin/mer (make sure it is on your PATH).")
        } catch { return "Failed: \(error.localizedDescription)" }
    }
}

enum FinderSelection {
    static func get() -> [URL] {
        let src = """
        tell application "Finder"
          set sel to selection as alias list
          set out to {}
          repeat with a in sel
            set end of out to POSIX path of a
          end repeat
          return out
        end tell
        """
        var err: NSDictionary?
        guard let desc = NSAppleScript(source: src)?.executeAndReturnError(&err) else { return [] }
        var urls: [URL] = []
        if desc.numberOfItems > 0 {
            for i in 1...desc.numberOfItems {
                if let p = desc.atIndex(i)?.stringValue { urls.append(URL(fileURLWithPath: p)) }
            }
        } else if let p = desc.stringValue {
            urls.append(URL(fileURLWithPath: p))
        }
        return urls
    }
}

enum HotKey {
    nonisolated(unsafe) static var handler: (@MainActor () -> Void)?

    @MainActor
    static func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handler?() } }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D494B4E), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

/// Debug: prints focus state 1 s after a surface appears (verifies nothing took key focus / activation).
@MainActor func debugFocusReport() {
    setbuf(stdout, nil)
    let f = NSWorkspace.shared.frontmostApplication
    print("focus-before: frontmost=\(f?.localizedName ?? "nil") appActive=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow)) main=\(String(describing: NSApp.mainWindow))")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let f = NSWorkspace.shared.frontmostApplication
        let panels = NSApp.windows.filter { $0 is GlassSurfacePanel }
        print("focus-after:  frontmost=\(f?.localizedName ?? "nil") appActive=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow)) main=\(String(describing: NSApp.mainWindow)) panels=\(panels.count) panelIsKey=\(panels.map { $0.isKeyWindow }) canBecomeKey=\(panels.map { $0.canBecomeKey }) firstResponderIsNil=\(panels.map { $0.firstResponder == nil })")
    }
}
