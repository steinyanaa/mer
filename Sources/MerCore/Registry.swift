import Foundation

public final class ActionRegistry: @unchecked Sendable {
    public static let shared = ActionRegistry()

    private let lock = NSLock()
    private var _all: [MerAction] = []

    public init() { reload() }

    public var all: [MerAction] {
        lock.lock(); defer { lock.unlock() }
        return _all
    }

    /// Rebuilds the action list (call after installing an engine or editing recipes).
    public func reload() {
        Tooling.resetCache()
        var list: [MerAction] = []
        list += ImageEngine.actions()
        list += AudioEngine.actions()
        list += VideoEngine.actions()
        list += DocumentEngine.actions()
        list += PDFEngine.actions()
        list += OCREngine.actions()
        list += DataEngine.actions()
        list += SubtitleEngine.actions()
        list += ArchiveEngine.actions()
        list += OfficeBridge.actions()
        list += RecipeEngine.actions()

        // First registration of an id wins (native engines are registered before external ones).
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted }
        lock.lock(); _all = list; lock.unlock()
    }

    public func action(id: String) -> MerAction? {
        all.first { $0.id == id }
    }

    /// Actions applicable to the whole selection, ranked by usage then registration order.
    public func actions(for urls: [URL], kind: ActionKind? = nil, rankByUsage: Bool = true) -> [MerAction] {
        guard !urls.isEmpty else { return [] }
        let usage = rankByUsage ? UsageStats.counts() : [:]
        let candidates = all.enumerated().filter { _, a in
            if let kind, a.kind != kind { return false }
            if urls.count < a.minFiles { return false }
            return urls.allSatisfy(a.accepts)
        }
        let ranked = candidates.sorted { l, r in
            let lu = usage[l.element.id, default: 0], ru = usage[r.element.id, default: 0]
            if lu != ru { return lu > ru }
            return l.offset < r.offset
        }.map(\.element)
        // Several engines may offer the same target (native + ffmpeg): show it once, preferring the earlier engine.
        var seen = Set<String>()
        return ranked.filter { seen.insert("\($0.kind.rawValue)|\($0.category.rawValue)|\($0.title)").inserted }
    }

    public func search(_ query: String, in actions: [MerAction]) -> [MerAction] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return actions }
        return actions.filter { a in
            a.title.lowercased().contains(q)
                || a.id.lowercased().contains(q)
                || a.category.title.lowercased().contains(q)
                || (a.subtitle?.lowercased().contains(q) ?? false)
        }
    }
}

public enum UsageStats {
    private static let key = "mer.usage"

    public static func counts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    public static func record(_ id: String) {
        var c = counts()
        c[id, default: 0] += 1
        UserDefaults.standard.set(c, forKey: key)
    }
}

// MARK: - Helpers used by engines

enum Accept {
    static func ext(_ exts: Set<String>) -> @Sendable (URL) -> Bool {
        { url in !url.isDirectory && exts.contains(url.fullExt) }
    }
}
