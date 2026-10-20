import AppKit
import Combine
import ServiceManagement
import MerCore

enum ModifierChoice: String, CaseIterable, Identifiable {
    case shift, command, control, option, none
    var id: String { rawValue }

    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .none: return Loc.t("Off")
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .none: return nil
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case sameFolder, custom
    var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var language: AppLanguage {
        didSet {
            Loc.language = language
            AppDelegate.shared?.languageChanged()
        }
    }
    @Published var wheelEnabled: Bool { didSet { d.set(wheelEnabled, forKey: "wheelEnabled") } }
    @Published var convertKey: ModifierChoice { didSet { d.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var toolKey: ModifierChoice { didSet { d.set(toolKey.rawValue, forKey: "toolKey") } }
    @Published var fileKey: ModifierChoice { didSet { d.set(fileKey.rawValue, forKey: "fileKey") } }
    @Published var outputMode: OutputMode { didSet { d.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var customOutputPath: String { didSet { d.set(customOutputPath, forKey: "customOutputPath") } }
    @Published var trashOriginals: Bool { didSet { d.set(trashOriginals, forKey: "trashOriginals") } }
    @Published var revealWhenDone: Bool { didSet { d.set(revealWhenDone, forKey: "revealWhenDone") } }
    @Published var launchAtLogin: Bool {
        didSet {
            d.set(launchAtLogin, forKey: "launchAtLogin")
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("Launch at login failed: \(error)") }
        }
    }

    private init() {
        func bool(_ k: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }
        func choice(_ k: String, _ def: ModifierChoice) -> ModifierChoice {
            UserDefaults.standard.string(forKey: k).flatMap(ModifierChoice.init) ?? def
        }
        language = Loc.language
        wheelEnabled = bool("wheelEnabled", true)
        convertKey = choice("convertKey", .shift)
        toolKey = choice("toolKey", .command)
        fileKey = choice("fileKey", .control)
        outputMode = UserDefaults.standard.string(forKey: "outputMode").flatMap(OutputMode.init) ?? .sameFolder
        customOutputPath = UserDefaults.standard.string(forKey: "customOutputPath") ?? ""
        trashOriginals = bool("trashOriginals", false)
        revealWhenDone = bool("revealWhenDone", false)
        launchAtLogin = bool("launchAtLogin", false)
    }

    var outputPolicy: OutputPolicy {
        if outputMode == .custom, !customOutputPath.isEmpty {
            return OutputPolicy(directory: URL(fileURLWithPath: customOutputPath, isDirectory: true))
        }
        return OutputPolicy()
    }

    /// Which layer a currently-held modifier set selects, if any.
    func layer(for flags: NSEvent.ModifierFlags) -> WheelLayer? {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        if let k = convertKey.flag, f.contains(k) { return .convert }
        if let k = toolKey.flag, f.contains(k) { return .tool }
        if let k = fileKey.flag, f.contains(k) { return .file }
        return nil
    }

    func key(for layer: WheelLayer) -> ModifierChoice {
        switch layer { case .convert: return convertKey; case .tool: return toolKey; case .file: return fileKey }
    }
}

enum WheelLayer: CaseIterable {
    case convert, tool, file
    var title: String {
        switch self { case .convert: return Loc.t("Convert"); case .tool: return Loc.t("Tools"); case .file: return Loc.t("Actions") }
    }
}

/// Submits jobs with the user's current output preferences.
@MainActor
enum Runner {
    static func run(_ action: MerAction, files: [URL], params: [String: String] = [:]) {
        let s = AppSettings.shared
        JobCenter.shared.submit(action, inputs: files, params: params, policy: s.outputPolicy, trashOriginals: s.trashOriginals)
        HUDController.shared.show()
    }
}
