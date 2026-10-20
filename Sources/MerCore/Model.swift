import Foundation

public enum Category: String, CaseIterable, Codable, Sendable {
    case image, video, audio, document, pdf, spreadsheet, slides, subtitle, archive, file

    public var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .pdf: return "PDF"
        case .spreadsheet: return "Spreadsheet"
        case .slides: return "Slides"
        case .subtitle: return "Subtitle"
        case .archive: return "Archive"
        case .file: return "File"
        }
    }

    public var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .pdf: return "doc.richtext"
        case .spreadsheet: return "tablecells"
        case .slides: return "rectangle.on.rectangle"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .file: return "doc"
        }
    }
}

public enum ActionKind: String, Codable, Sendable {
    case convert   // "turn this into format X"
    case tool      // "do something to this file" (compress, trim, merge …)
}

public struct Param: Identifiable, Sendable {
    public enum Kind: Sendable {
        case text
        case number
        case choice([String])
    }
    public var id: String { key }
    public let key: String
    public let label: String
    public let kind: Kind
    public let defaultValue: String

    public init(key: String, label: String, kind: Kind = .text, defaultValue: String = "") {
        self.key = key
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

public struct OutputPolicy: Sendable {
    /// nil → write next to the source file.
    public var directory: URL?
    public init(directory: URL? = nil) { self.directory = directory }
}

public struct RunContext: Sendable {
    public var policy: OutputPolicy
    public var params: [String: String]
    public var progress: @Sendable (Double) -> Void

    public init(policy: OutputPolicy = OutputPolicy(),
                params: [String: String] = [:],
                progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.policy = policy
        self.params = params
        self.progress = progress
    }

    public func param(_ key: String, default value: String = "") -> String {
        let v = params[key] ?? value
        return v.isEmpty ? value : v
    }
}

public struct MerAction: Identifiable, Sendable {
    public let id: String
    public let kind: ActionKind
    public let title: String
    public let subtitle: String?
    public let category: Category
    public let symbol: String?
    public let engine: String
    public let params: [Param]
    /// Needs the whole selection in one call (merge, combine …).
    public let batch: Bool
    public let minFiles: Int
    public let accepts: @Sendable (URL) -> Bool
    public let work: @Sendable (_ inputs: [URL], _ ctx: RunContext) async throws -> [URL]

    public init(id: String,
                kind: ActionKind,
                title: String,
                subtitle: String? = nil,
                category: Category,
                symbol: String? = nil,
                engine: String,
                params: [Param] = [],
                batch: Bool = false,
                minFiles: Int = 1,
                accepts: @escaping @Sendable (URL) -> Bool,
                work: @escaping @Sendable ([URL], RunContext) async throws -> [URL]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.symbol = symbol
        self.engine = engine
        self.params = params
        self.batch = batch
        self.minFiles = minFiles
        self.accepts = accepts
        self.work = work
    }
}

public enum MerError: LocalizedError {
    case unsupported(String)
    case toolMissing(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Unsupported: \(s)"
        case .toolMissing(let s): return "Required tool not installed: \(s)"
        case .failed(let s): return s
        }
    }
}

// MARK: - File helpers

public extension URL {
    /// Lowercased extension, aware of compound archive extensions (tar.gz, tar.bz2 …).
    var fullExt: String {
        let name = lastPathComponent.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz"] where name.hasSuffix("." + compound) {
            return compound
        }
        return pathExtension.lowercased()
    }

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// File name without its (possibly compound) extension.
    var baseName: String {
        let ext = fullExt
        let name = lastPathComponent
        if ext.isEmpty || isDirectory { return name }
        return String(name.dropLast(ext.count + 1))
    }
}

public enum OutputNamer {
    public static func url(for input: URL, ext: String, suffix: String = "", policy: OutputPolicy) -> URL {
        let dir = policy.directory ?? input.deletingLastPathComponent()
        return unique(dir: dir, base: input.baseName + suffix, ext: ext)
    }

    public static func folder(for input: URL, suffix: String = "", policy: OutputPolicy) -> URL {
        let dir = policy.directory ?? input.deletingLastPathComponent()
        return unique(dir: dir, base: input.baseName + suffix, ext: "")
    }

    public static func unique(dir: URL, base: String, ext: String) -> URL {
        func make(_ b: String) -> URL {
            let name = ext.isEmpty ? b : "\(b).\(ext)"
            return dir.appendingPathComponent(name)
        }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    public static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
