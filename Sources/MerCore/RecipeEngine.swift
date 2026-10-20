import Foundation

/// A declarative conversion that shells out to an external tool.
/// Built-in recipes cover ffmpeg, pandoc, LibreOffice and ImageMagick; users can add their own as
/// JSON files in `~/Library/Application Support/Mer/Recipes/`.
public struct Recipe: Codable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var kind: ActionKind
    public var category: Category
    public var symbol: String?
    /// Lowercase extensions accepted as input.
    public var inputs: [String]
    /// Output extension. Empty string = output is a folder.
    public var output: String
    /// Executable that must exist (looked up in Homebrew, MacPorts, PATH, ~/Library/Application Support/Mer/bin).
    public var requires: String
    /// Argument vector. First element may be `{tool}` for the required executable.
    /// Placeholders: {tool} {input} {output} {inputs} {outdir} {tmpdir} {name} {dir} and {param:key}.
    public var command: [String]
    public var params: [RecipeParam]?
    /// If the tool writes into {tmpdir}, move the first file with the output extension to the final path.
    public var collect: Bool?
    public var batch: Bool?
    public var suffix: String?
    public var accepts: [String]?   // extra "any" matcher: ["*"] accepts every file

    public struct RecipeParam: Codable, Sendable {
        public var key: String, label: String
        public var defaultValue: String?
        public var type: String?        // "text" | "number"
        /// When true, running with an empty value fails with a clear message instead of calling the tool.
        public var required: Bool?
    }
}

enum RecipeEngine {
    static var userRecipesDirectory: URL { Tooling.supportDirectory.appendingPathComponent("Recipes", isDirectory: true) }

    static func actions() -> [MerAction] {
        (BuiltinRecipes.all + loadUserRecipes()).compactMap(action(for:))
    }

    static func loadUserRecipes() -> [Recipe] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: userRecipesDirectory, includingPropertiesForKeys: nil) else { return [] }
        var recipes: [Recipe] = []
        let decoder = JSONDecoder()
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            if let many = try? decoder.decode([Recipe].self, from: data) { recipes += many }
            else if let one = try? decoder.decode(Recipe.self, from: data) { recipes.append(one) }
        }
        return recipes
    }

    static func action(for r: Recipe) -> MerAction? {
        guard Tooling.find(r.requires) != nil else { return nil }
        let inputs = Set(r.inputs.map { $0.lowercased() })
        let anything = r.accepts?.contains("*") ?? false
        let out = r.output.lowercased()
        let params = (r.params ?? []).map {
            Param(key: $0.key, label: $0.label, kind: $0.type == "number" ? .number : .text, defaultValue: $0.defaultValue ?? "")
        }
        return MerAction(
            id: r.id, kind: r.kind, title: r.title, subtitle: r.subtitle, category: r.category,
            symbol: r.symbol, engine: r.requires, params: params, batch: r.batch ?? false,
            minFiles: (r.batch ?? false) ? 2 : 1,
            accepts: { url in
                guard anything || (!url.isDirectory && inputs.contains(url.fullExt)) else { return false }
                return r.kind == .tool || url.fullExt != out
            },
            work: { files, ctx in try await run(r, files: files, ctx: ctx) })
    }

    static func run(_ r: Recipe, files: [URL], ctx: RunContext) async throws -> [URL] {
        let tool = try Tooling.require(r.requires)
        for p in r.params ?? [] where p.required == true {
            if ctx.param(p.key, default: p.defaultValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                throw MerError.failed("\(p.label) is required")
            }
        }
        let first = files[0]
        let tmp = try OutputNamer.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let finalOut: URL = r.output.isEmpty
            ? OutputNamer.folder(for: first, suffix: r.suffix ?? "", policy: ctx.policy)
            : OutputNamer.url(for: first, ext: r.output, suffix: r.suffix ?? "", policy: ctx.policy)
        let collect = r.collect ?? false
        let outPath = collect ? tmp.appendingPathComponent("out." + r.output).path : finalOut.path

        var args: [String] = []
        for token in r.command.dropFirst(r.command.first == "{tool}" || r.command.first == r.requires ? 1 : 0) {
            if token == "{inputs}" { args += files.map(\.path); continue }
            var t = token
            let map: [String: String] = [
                "{input}": first.path, "{output}": outPath, "{outdir}": finalOut.deletingLastPathComponent().path,
                "{tmpdir}": tmp.path, "{name}": first.baseName, "{dir}": first.deletingLastPathComponent().path,
                "{tool}": tool,
            ]
            for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
            for p in r.params ?? [] {
                t = t.replacingOccurrences(of: "{param:\(p.key)}", with: ctx.param(p.key, default: p.defaultValue ?? ""))
            }
            args.append(t)
        }

        if r.output.isEmpty { try FileManager.default.createDirectory(at: finalOut, withIntermediateDirectories: true) }
        let progress = ctx.progress
        try await Shell.run(tool, args, onStderr: { chunk in
            // ffmpeg prints "time=00:00:12.3"; we do not know the total here, so just show activity.
            if chunk.contains("time=") { progress(0.5) }
        })

        if collect {
            let produced = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
                .first { $0.pathExtension.lowercased() == r.output.lowercased() }
            guard let produced else { throw MerError.failed("\(r.requires) produced no \(r.output) file") }
            try FileManager.default.moveItem(at: produced, to: finalOut)
        }
        guard FileManager.default.fileExists(atPath: finalOut.path) else {
            throw MerError.failed("\(r.requires) finished but no output was created")
        }
        return [finalOut]
    }
}

// MARK: - Engines catalogue (for the Engines panel & `mer engines`)

public struct EngineInfo: Identifiable, Sendable {
    public var id: String { binary }
    public let name: String
    public let binary: String
    public let brew: String
    public let unlocks: String
    public var path: String? { Tooling.find(binary) }
    public var installed: Bool { path != nil }
    public var installCommand: String { brew.hasPrefix("--cask") ? "brew install \(brew)" : "brew install \(brew)" }
}

public enum Engines {
    public static let catalogue: [EngineInfo] = [
        EngineInfo(name: "FFmpeg", binary: "ffmpeg", brew: "ffmpeg",
                   unlocks: "MKV, WebM, AVI, WMV, FLV, MP3, OGG, Opus, WMA, lossless trim, loudness normalise"),
        EngineInfo(name: "Pandoc", binary: "pandoc", brew: "pandoc",
                   unlocks: "Markdown / DOCX / EPUB / HTML / ODT / LaTeX / RST in every direction"),
        EngineInfo(name: "LibreOffice", binary: "soffice", brew: "--cask libreoffice",
                   unlocks: "PPT/PPTX/ODP/XLS/DOC → PDF and back, PPTX → images"),
        EngineInfo(name: "ImageMagick", binary: "magick", brew: "imagemagick",
                   unlocks: "SVG input, ICO, PSD, JPEG XL and more image formats"),
        EngineInfo(name: "Ghostscript", binary: "gs", brew: "ghostscript",
                   unlocks: "Stronger PDF compression"),
        EngineInfo(name: "qpdf", binary: "qpdf", brew: "qpdf",
                   unlocks: "PDF encrypt / decrypt / repair"),
    ]
}
