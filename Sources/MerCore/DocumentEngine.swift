import Foundation
import AppKit
import CoreText

enum DocumentEngine {
    /// Formats macOS's textutil can read.
    static let textutilInputs: Set<String> = ["txt", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml", "webarchive"]
    static let markdownInputs: Set<String> = ["md", "markdown"]
    static let allInputs = textutilInputs.union(markdownInputs)

    private struct Target { let ext: String; let title: String; let textutilFormat: String? }
    private static let targets: [Target] = [
        Target(ext: "docx", title: "DOCX", textutilFormat: "docx"),
        Target(ext: "pdf", title: "PDF", textutilFormat: nil),
        Target(ext: "html", title: "HTML", textutilFormat: "html"),
        Target(ext: "rtf", title: "RTF", textutilFormat: "rtf"),
        Target(ext: "txt", title: "TXT", textutilFormat: "txt"),
        Target(ext: "odt", title: "ODT", textutilFormat: "odt"),
        Target(ext: "doc", title: "DOC", textutilFormat: "doc"),
        Target(ext: "rtfd", title: "RTFD", textutilFormat: "rtfd"),
        Target(ext: "md", title: "Markdown", textutilFormat: nil),
        Target(ext: "epub", title: "EPUB", textutilFormat: nil),
    ]

    static func actions() -> [MerAction] {
        var list: [MerAction] = []
        for t in targets {
            list.append(MerAction(
                id: "convert.document.\(t.ext)", kind: .convert, title: t.title, category: .document,
                symbol: "doc.text", engine: t.ext == "pdf" ? "CoreText" : (t.ext == "md" || t.ext == "epub" ? "Built-in" : "textutil"),
                accepts: { url in
                    guard !url.isDirectory, allInputs.contains(url.fullExt), url.fullExt != t.ext else { return false }
                    if url.fullExt == "htm" && t.ext == "html" { return false }
                    if t.ext == "md" && markdownInputs.contains(url.fullExt) { return false }
                    return true
                },
                work: { inputs, ctx in
                    let out = OutputNamer.url(for: inputs[0], ext: t.ext, policy: ctx.policy)
                    try await convert(inputs[0], to: out, ext: t.ext, textutilFormat: t.textutilFormat)
                    return [out]
                }))
        }
        return list
    }

    static func convert(_ input: URL, to out: URL, ext: String, textutilFormat: String?) async throws {
        let tmp = try OutputNamer.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Markdown and EPUB are produced from Markdown text, which every readable input can be turned into.
        if ext == "md" || ext == "epub" {
            let md = try await markdownText(from: input, tmp: tmp)
            if ext == "md" { try md.write(to: out, atomically: true, encoding: .utf8) }
            else { try await EPUBWriter.write(markdown: md, title: input.baseName, to: out) }
            return
        }

        // textutil's DOCX writer drops hyperlinks, so Markdown and plain text go through our own writer.
        if ext == "docx", markdownInputs.contains(input.fullExt) || input.fullExt == "txt" {
            let attributed: NSAttributedString
            if input.fullExt == "txt" {
                let plain = try String(contentsOf: input, encoding: .utf8)
                attributed = NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            } else {
                let md = try String(contentsOf: input, encoding: .utf8)
                let html = tmp.appendingPathComponent("source.html"), rtf = tmp.appendingPathComponent("source.rtf")
                try MarkdownRenderer.html(md, title: input.baseName).write(to: html, atomically: true, encoding: .utf8)
                try await textutil(html, format: "rtf", to: rtf)
                attributed = try NSAttributedString(url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            }
            try await DOCXWriter.write(attributed, to: out)
            return
        }

        // 1. normalise the source into something textutil understands
        var source = input
        if markdownInputs.contains(input.fullExt) {
            let md = try String(contentsOf: input, encoding: .utf8)
            let html = MarkdownRenderer.html(md, title: input.baseName)
            source = tmp.appendingPathComponent("source.html")
            try html.write(to: source, atomically: true, encoding: .utf8)
        }

        // 2. emit the target
        if ext == "html", markdownInputs.contains(input.fullExt) {
            try FileManager.default.copyItem(at: source, to: out)   // our own renderer is cleaner than textutil's
            return
        }
        if let fmt = textutilFormat {
            if fmt == "txt" && input.fullExt == "md" || fmt == "txt" && input.fullExt == "markdown" {
                try FileManager.default.copyItem(at: input, to: out)   // markdown is already text
                return
            }
            try await textutil(source, format: fmt, to: out)
        } else {
            // PDF: go through RTF so the (main-thread-only) HTML importer is never touched.
            let rtf = tmp.appendingPathComponent("page.rtf")
            try await textutil(source, format: "rtf", to: rtf)
            let attributed = try NSAttributedString(url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                    documentAttributes: nil)
            try TextPDF.render(attributed, to: out)
        }
    }

    static func markdownText(from input: URL, tmp: URL) async throws -> String {
        if markdownInputs.contains(input.fullExt) || input.fullExt == "txt" { return try String(contentsOf: input, encoding: .utf8) }
        if input.fullExt == "docx" {
            let paras = await DOCXReader.paragraphs(from: input)
            if !paras.isEmpty { return MarkdownWriter.markdown(paragraphs: paras) }   // else fall through to textutil
        }
        // textutil → RTF (thread-safe to import) → rich text → Markdown
        let rtf = tmp.appendingPathComponent("rich.rtf")
        try await textutil(input, format: "rtf", to: rtf)
        let attributed = try NSAttributedString(url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var md = MarkdownWriter.markdown(from: attributed)
        guard !md.isEmpty else { throw MerError.failed("The document has no text") }
        if input.fullExt == "docx" { md = DOCXLinks.apply(await DOCXLinks.extract(from: input), to: md) }
        return md
    }

    static func textutil(_ source: URL, format: String, to out: URL) async throws {
        try await Shell.run("/usr/bin/textutil", ["-convert", format, "-output", out.path, source.path])
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw MerError.failed("textutil produced no output")
        }
    }
}

// MARK: - Paginated text → PDF

enum TextPDF {
    static func render(_ text: NSAttributedString, to url: URL,
                       pageSize: CGSize = CGSize(width: 595, height: 842), margin: CGFloat = 54) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw MerError.failed("Cannot create PDF") }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frameRect = box.insetBy(dx: margin, dy: margin)
        var location = 0
        let length = text.length
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            location += visible.length
        } while location < length
        ctx.closePDF()
    }
}

// MARK: - Minimal Markdown → HTML

enum MarkdownRenderer {
    static func html(_ source: String, title: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var paragraph: [String] = []
        var listKind: String?
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>"); paragraph = [] }
        }
        func closeList() {
            if let k = listKind { out.append("</\(k)>"); listKind = nil }
        }

        for raw in lines {
            if raw.hasPrefix("```") {
                if inCode {
                    out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                    code = []; inCode = false
                } else { flushParagraph(); closeList(); inCode = true }
                continue
            }
            if inCode { code.append(raw); continue }

            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); closeList(); continue }

            if let m = line.firstMatch(#"^(#{1,6})\s+(.*)$"#) {
                flushParagraph(); closeList()
                out.append("<h\(m[1].count)>\(inline(m[2]))</h\(m[1].count)>")
            } else if line.firstMatch(#"^(\*{3,}|-{3,}|_{3,})$"#) != nil {
                flushParagraph(); closeList(); out.append("<hr/>")
            } else if let m = line.firstMatch(#"^>\s?(.*)$"#) {
                flushParagraph(); closeList(); out.append("<blockquote>\(inline(m[1]))</blockquote>")
            } else if let m = line.firstMatch(#"^[-*+]\s+(.*)$"#) {
                flushParagraph()
                if listKind != "ul" { closeList(); out.append("<ul>"); listKind = "ul" }
                out.append("<li>\(inline(m[1]))</li>")
            } else if let m = line.firstMatch(#"^\d+[.)]\s+(.*)$"#) {
                flushParagraph()
                if listKind != "ol" { closeList(); out.append("<ol>"); listKind = "ol" }
                out.append("<li>\(inline(m[1]))</li>")
            } else {
                closeList(); paragraph.append(line)
            }
        }
        if inCode { out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>") }
        flushParagraph(); closeList()
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(escape(title))</title></head><body>
        \(out.joined(separator: "\n"))
        </body></html>
        """
    }

    /// Body-only markup that is also well-formed XML (for EPUB).
    static func bodyXHTML(_ source: String) -> String {
        let page = html(source, title: "")
        guard let a = page.range(of: "<body>\n"), let b = page.range(of: "\n</body>", options: .backwards) else { return "" }
        return String(page[a.upperBound..<b.lowerBound])
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, "<img alt=\"$1\" src=\"$2\"/>"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"\*([^*]+)\*"#, "<em>$1</em>"),
            (#"(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}

extension String {
    /// Returns capture groups (index 0 = whole match) of the first match.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
