import Foundation

/// Pandoc recipes. Kept in their own file so each engine can be maintained independently.
extension BuiltinRecipes {
    // MARK: Pandoc

    /// Lua filter that gives the document a title (the source file's name) only when it has none.
    /// EPUB needs a `dc:title`; `--metadata title=…` cannot be used for this because on the command
    /// line it *overrides* a title the document already has (and one that pandoc promoted from a
    /// lone top-level heading), whereas a filter can leave a real title alone.
    private static let defaultTitleFilter = """
        function Pandoc(doc)
          if doc.meta.title == nil or #pandoc.utils.stringify(doc.meta.title) == 0 then
            local path = (PANDOC_STATE.input_files or {})[1] or ""
            local base = path:match("([^/]+)$") or path
            base = base:gsub("%.[^.]*$", "")
            if base ~= "" and base ~= "-" then doc.meta.title = pandoc.MetaString(base) end
          end
          return doc
        end

        """

    /// Writes the filter next to the user's other Mer support files; nil if that fails
    /// (the recipes then simply run without it).
    private static func defaultTitleFilterPath() -> String? {
        let dir = Tooling.supportDirectory.appendingPathComponent("Pandoc", isDirectory: true)
        let file = dir.appendingPathComponent("default-title.lua")
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing == defaultTitleFilter { return file.path }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try defaultTitleFilter.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch { return nil }
    }

    static var pandoc: [Recipe] {
        guard Tooling.find("pandoc") != nil else { return [] }
        let ins = ["md", "markdown", "html", "htm", "docx", "odt", "epub", "rst", "tex", "org"]
        let titleFilter = defaultTitleFilterPath().map { ["--lua-filter", $0] } ?? []

        // Text writers: `-s` keeps the document title/author (otherwise they are dropped), `--wrap=none`
        // avoids hard-wrapping paragraphs at 72 columns, and images in DOCX/ODT/EPUB sources are
        // extracted next to the output (only created when the source actually contains images).
        let text = ["-s", "--wrap=none", "--extract-media={outdir}/{name}_media"]

        let targets: [(String, String, [String])] = [
            ("md", "Markdown", ["-t", "gfm"] + text),
            ("docx", "DOCX", []),
            ("epub", "EPUB", titleFilter),
            ("html", "HTML", ["-s", "--embed-resources"]),
            ("odt", "ODT", []),
            ("rst", "reStructuredText", text),
            ("tex", "LaTeX", text),
            ("txt", "TXT", ["-t", "plain", "-s", "--wrap=none"]),   // plain text has no images to extract
        ]
        return targets.map { ext, title, extra in
            Recipe(id: "pandoc.\(ext)", title: title, subtitle: nil, kind: .convert, category: .document,
                   symbol: "doc.text", inputs: ins, output: ext, requires: "pandoc",
                   // --resource-path: relative image links resolve against the source's folder, not the cwd.
                   command: ["{tool}", "{input}", "--resource-path={dir}"] + extra + ["-o", "{output}"],
                   params: nil, collect: false, batch: false, suffix: nil, accepts: nil)
        }
    }
}
