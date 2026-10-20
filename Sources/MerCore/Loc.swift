import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, english = "en", chinese = "zh-Hans"
}

/// Minimal runtime localisation. English source strings are the keys; the Simplified Chinese table lives in
/// `Loc+Chinese.swift` (engine/action strings) and `LocZhApp.swift` (app UI). Action ids and CLI output stay English.
public enum Loc {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: Bool?
    private static let key = "mer.language"

    public static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            lock.lock(); cached = nil; lock.unlock()
        }
    }

    /// Whether strings should currently be shown in Simplified Chinese.
    public static var isChinese: Bool {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let resolved: Bool
        switch language {
        case .english: resolved = false
        case .chinese: resolved = true
        case .system: resolved = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
        cached = resolved
        return resolved
    }

    /// Extra tables registered by the app target (its UI strings).
    public nonisolated(unsafe) static var extraTables: [[String: String]] = []

    private nonisolated(unsafe) static var mergedWithExtras: [String: String]?

    private static func table() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let m = mergedWithExtras { return m }
        var t = zhEngine
        for e in extraTables { t.merge(e) { a, _ in a } }
        mergedWithExtras = t
        return t
    }

    /// Call after registering extra tables.
    public static func registerAppTable(_ t: [String: String]) {
        lock.lock(); extraTables.append(t); mergedWithExtras = nil; lock.unlock()
    }

    public static func t(_ s: String) -> String {
        guard isChinese else { return s }
        return table()[s] ?? s
    }

    /// printf-style: the *format* is translated, then filled in.
    public static func f(_ format: String, _ args: CVarArg...) -> String {
        String(format: t(format), arguments: args)
    }

    /// Translates engine/error messages, including ones with embedded names (file names, tool names …).
    public static func message(_ s: String) -> String {
        guard isChinese else { return s }
        if let exact = table()[s] { return exact }
        for (pattern, template) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            var out = template
            for i in 1..<m.numberOfRanges {
                let part = Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
                out = out.replacingOccurrences(of: "$\(i)", with: table()[part] ?? part)
            }
            return out
        }
        return s
    }
}

public extension MerAction {
    var displayTitle: String { Loc.t(title) }
    var displaySubtitle: String? { subtitle.map(Loc.message) }
}

public extension Param {
    var displayLabel: String { Loc.t(label) }
}

public extension Category {
    var displayTitle: String { Loc.t(title) }
}

public extension EngineInfo {
    var displayUnlocks: String { Loc.t(unlocks) }
}
