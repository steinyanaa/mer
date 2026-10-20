import Foundation
import AppKit
import NaturalLanguage

// MARK: - Rich text model

/// A paragraph of rich text reduced to what Markdown / DOCX writers need.
struct RichPara {
    enum Kind: Equatable { case body, heading(Int), bullet, numbered(Int), table([[String]]) }
    struct Run { var text: String; var bold = false, italic = false, mono = false; var link: String? }
    var kind: Kind = .body
    var runs: [Run] = []
    var indent = 0                      // list nesting level
    var plain: String { runs.map(\.text).joined() }
}

enum RichText {
    /// Splits attributed text into paragraphs, detecting headings (by font-size rank) and list markers.
    static func paragraphs(from text: NSAttributedString) -> [RichPara] {
        let whole = text.string as NSString
        guard whole.length > 0 else { return [] }

        var weights: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let f = value as? NSFont { weights[f.pointSize.rounded(), default: 0] += range.length }
        }
        let base = weights.max { $0.value < $1.value }?.key ?? 12

        var result: [(para: RichPara, size: CGFloat)] = []
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            var runs: [RichPara.Run] = []
            var maxSize: CGFloat = 0
            text.enumerateAttributes(in: range) { attrs, r, _ in
                let piece = whole.substring(with: r).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                guard !piece.isEmpty else { return }
                let font = attrs[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                if let f = font, !piece.trimmingCharacters(in: .whitespaces).isEmpty { maxSize = max(maxSize, f.pointSize) }
                var run = RichPara.Run(text: piece, bold: traits.contains(.bold), italic: traits.contains(.italic), mono: traits.contains(.monoSpace))
                if let l = attrs[.link] { run.link = (l as? URL)?.absoluteString ?? "\(l)" }
                runs.append(run)
            }
            var para = RichPara(kind: .body, runs: runs)
            guard !para.plain.trimmingCharacters(in: .whitespaces).isEmpty else { return }

            // List marker at the start. macOS stores "1." as "1⇥" (no period) and bullets as "•⇥", so look at the
            // original text including tabs: a bare number only counts as a marker when a tab follows it.
            let original = whole.substring(with: range)
            let marker = original.firstMatch(#"^\s*([•◦▪●‣\-\*–·])[\t ]+"#) ?? original.firstMatch(#"^\s*(\d+[.)]?)(?:\t|[.)] +)"#)
            if let m = marker {
                let marker = m[1]
                // nesting: textutil indents each list level with one more leading tab
                let headIndent = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
                let tabs = original.prefix(while: { $0 == "\t" || $0 == " " }).filter { $0 == "\t" }.count
                para.indent = max(0, max(tabs - 1, Int((headIndent / 36).rounded()) - 1))
                para.kind = marker.first?.isNumber == true ? .numbered(Int(marker.filter(\.isNumber)) ?? 1) : .bullet
                var drop = m[0].count
                while drop > 0, !para.runs.isEmpty {
                    if para.runs[0].text.count <= drop { drop -= para.runs[0].text.count; para.runs.removeFirst() }
                    else { para.runs[0].text.removeFirst(drop); drop = 0 }
                }
            }
            result.append((para, maxSize))
        }

        // headings: any short, non-list paragraph noticeably larger than body text; levels follow the size ranking
        let candidateSizes = Set(result.filter { $0.para.kind == .body && $0.size >= base * 1.1 && $0.para.plain.count < 200 }.map { $0.size.rounded() })
        let ranked = candidateSizes.sorted(by: >)
        return result.map { item in
            var p = item.para
            if p.kind == .body, let idx = ranked.firstIndex(of: item.size.rounded()), item.size >= base * 1.1, p.plain.count < 200 {
                p.kind = .heading(min(idx + 1, 4))
                for i in p.runs.indices { p.runs[i].bold = false }
            }
            return p
        }
    }
}

// MARK: - Markdown writer

enum MarkdownWriter {
    static func markdown(from text: NSAttributedString) -> String {
        markdown(paragraphs: RichText.paragraphs(from: text))
    }

    static func markdown(paragraphs paras: [RichPara]) -> String {
        var out = ""
        for (i, p) in paras.enumerated() {
            let line = inline(p.runs).trimmingCharacters(in: .whitespaces)
            let formatted: String
            switch p.kind {
            case .heading(let level): formatted = String(repeating: "#", count: level) + " " + line
            case .bullet: formatted = String(repeating: "  ", count: p.indent) + "- " + line
            case .numbered(let n): formatted = String(repeating: "   ", count: p.indent) + "\(n). " + line
            case .table(let rows): formatted = table(rows)
            case .body: formatted = line
            }
            if i > 0 {
                func sameList(_ a: RichPara.Kind, _ b: RichPara.Kind) -> Bool {
                    switch (a, b) {
                    case (.bullet, .bullet), (.numbered, .numbered): return true
                    default: return false
                    }
                }
                out += sameList(paras[i - 1].kind, p.kind) ? "\n" : "\n\n"
            }
            out += formatted
        }
        return out.isEmpty ? "" : out + "\n"
    }

    private static func table(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        func row(_ r: [String]) -> String { "| " + (r + Array(repeating: "", count: width - r.count)).joined(separator: " | ") + " |" }
        guard let head = rows.first else { return "" }
        return ([row(head), "|" + String(repeating: " --- |", count: width)] + rows.dropFirst().map(row)).joined(separator: "\n")
    }

    private static func inline(_ runs: [RichPara.Run]) -> String {
        var result = ""
        for run in runs {
            let core = run.text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { result += run.text; continue }
            let lead = String(run.text.prefix(while: { $0 == " " }))
            let trail = String(run.text.reversed().prefix(while: { $0 == " " }))
            var piece = core
            if run.mono { piece = "`\(piece)`" }
            else if run.bold && run.italic { piece = "***\(piece)***" }
            else if run.bold { piece = "**\(piece)**" }
            else if run.italic { piece = "*\(piece)*" }
            if let link = run.link { piece = "[\(piece)](\(link))" }
            result += lead + piece + trail
        }
        return result
    }
}

// MARK: - Hyperlinks inside DOCX (macOS's own readers drop them)

enum DOCXLinks {
    /// (display text, URL) pairs in document order.
    static func extract(from docx: URL) async -> [(String, String)] {
        func part(_ path: String) async -> Data? {
            guard let r = try? await Shell.run("/usr/bin/unzip", ["-p", docx.path, path], allowFailure: true), r.status == 0 else { return nil }
            return r.out.data(using: .utf8)
        }
        guard let doc = await part("word/document.xml"), let relsData = await part("word/_rels/document.xml.rels") else { return [] }
        let rels = RelsParser.parse(relsData)
        return LinkParser.parse(doc).compactMap { id, text in rels[id].map { (text, $0) } }
    }

    /// Wraps the first unlinked occurrence (in order) of each link text.
    static func apply(_ links: [(String, String)], to markdown: String) -> String {
        var md = markdown
        var from = md.startIndex
        for (text, url) in links {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let r = md.range(of: t, range: from..<md.endIndex) else { continue }
            if r.lowerBound > md.startIndex, md[md.index(before: r.lowerBound)] == "[" { from = r.upperBound; continue }
            let replacement = "[\(t)](\(url))"
            md.replaceSubrange(r, with: replacement)
            from = md.index(r.lowerBound, offsetBy: replacement.count)
        }
        return md
    }

    static func relationships(_ data: Data) -> [String: String] { RelsParser.parse(data) }

    private final class RelsParser: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]
        static func parse(_ d: Data) -> [String: String] {
            let p = RelsParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.map
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if name == "Relationship", let id = a["Id"], let t = a["Target"], a["TargetMode"] == "External" { map[id] = t }
        }
    }

    private final class LinkParser: NSObject, XMLParserDelegate {
        var links: [(String, String)] = []
        private var currentID: String?, text = "", inT = false
        static func parse(_ d: Data) -> [(String, String)] {
            let p = LinkParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.links
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if name == "w:hyperlink" { currentID = a["r:id"]; text = "" }
            else if name == "w:t", currentID != nil { inT = true }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { if inT { text += s } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "w:t" { inT = false }
            else if name == "w:hyperlink", let id = currentID { links.append((id, text)); currentID = nil }
        }
    }
}

// MARK: - Native DOCX writer (keeps hyperlinks, which textutil's DOCX writer silently drops)

enum DOCXWriter {
    static func write(_ text: NSAttributedString, to out: URL) async throws {
        let paras = RichText.paragraphs(from: text)
        guard !paras.isEmpty else { throw MerError.failed("The document has no text") }
        let tmp = try OutputNamer.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        for d in ["_rels", "word/_rels"] { try fm.createDirectory(at: tmp.appendingPathComponent(d), withIntermediateDirectories: true) }
        func put(_ path: String, _ s: String) throws { try s.write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let esc = XLSX.xmlEscape

        var rels: [String] = []
        func link(_ url: String) -> String {
            rels.append("<Relationship Id=\"rId\(rels.count + 10)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(esc(url).replacingOccurrences(of: "\"", with: "&quot;"))\" TargetMode=\"External\"/>")
            return "rId\(rels.count + 9)"
        }

        func runXML(_ r: RichPara.Run, heading: Int?) -> String {
            var props = ""
            if let level = heading { props += "<w:b/><w:sz w:val=\"\([40, 32, 26, 23][min(level, 4) - 1])\"/>" }
            if r.link != nil { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if r.mono { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>" }
            if r.bold && heading == nil { props += "<w:b/>" }
            if r.italic { props += "<w:i/>" }
            let t = "<w:r>\(props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>")<w:t xml:space=\"preserve\">\(esc(r.text))</w:t></w:r>"
            if let url = r.link { return "<w:hyperlink r:id=\"\(link(url))\">\(t)</w:hyperlink>" }
            return t
        }

        // Real Word lists: numId 1 = bullets; every new numbered list gets its own w:num so it restarts at 1.
        var numberedInstances: [Int] = []
        var currentNumbered: Int?
        func numPr(_ id: Int, _ level: Int) -> String { "<w:numPr><w:ilvl w:val=\"\(min(level, 2))\"/><w:numId w:val=\"\(id)\"/></w:numPr>" }

        var body = ""
        for p in paras {
            var ppr = ""
            let prefix = ""
            switch p.kind {
            case .heading(let level): ppr = "<w:pStyle w:val=\"Heading\(level)\"/>"
            case .bullet: ppr = numPr(1, p.indent)
            case .numbered(let n):
                if currentNumbered == nil || n == 1 && p.indent == 0 {
                    numberedInstances.append(3 + numberedInstances.count)
                    currentNumbered = numberedInstances.last
                }
                ppr = numPr(currentNumbered!, p.indent)
            case .table(let rows):
                for r in rows { body += "<w:p><w:r><w:t xml:space=\"preserve\">\(esc(r.joined(separator: "   ")))</w:t></w:r></w:p>" }
                currentNumbered = nil
                continue
            case .body: break
            }
            if case .numbered = p.kind {} else if p.indent == 0 || p.kind != .bullet { currentNumbered = nil }
            var runs = prefix.isEmpty ? "" : "<w:r><w:t xml:space=\"preserve\">\(prefix)</w:t></w:r>"
            var runList = p.runs
            if let first = runList.first { runList[0].text = String(first.text.drop(while: { $0 == " " })) }
            var level: Int?
            if case .heading(let l) = p.kind { level = l }
            for r in runList { runs += runXML(r, heading: level) }
            body += "<w:p>\(ppr.isEmpty ? "" : "<w:pPr>\(ppr)</w:pPr>")\(runs)</w:p>"
        }

        try put("[Content_Types].xml", head + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>"#)
        try put("_rels/.rels", head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#)
        try put("word/_rels/document.xml.rels", head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>"# + rels.joined() + "</Relationships>")
        try put("word/document.xml", head + #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>"# + body + #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>"#)

        func lvl(_ i: Int, _ fmt: String, _ text: String) -> String {
            "<w:lvl w:ilvl=\"\(i)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + i * 360)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        let bulletLevels = lvl(0, "bullet", "•") + lvl(1, "bullet", "◦") + lvl(2, "bullet", "▪")
        let decimalLevels = lvl(0, "decimal", "%1.") + lvl(1, "lowerLetter", "%2.") + lvl(2, "lowerRoman", "%3.")
        let instances = numberedInstances.map { "<w:num w:numId=\"\($0)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>" }.joined()
        try put("word/numbering.xml", head + #"<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>"# + bulletLevels + #"</w:abstractNum><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>"# + decimalLevels + #"</w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>"# + instances + "</w:numbering>")

        func heading(_ n: Int, _ size: Int) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"280\" w:after=\"100\"/><w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        try put("word/styles.xml", head + #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:eastAsia="PingFang SC"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"# + heading(1, 40) + heading(2, 32) + heading(3, 26) + heading(4, 23) + #"<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0B7A92"/><w:u w:val="single"/></w:rPr></w:style></w:styles>"#)

        try? fm.removeItem(at: out)
        try await Shell.run("/usr/bin/zip", ["-X", "-q", out.path, "[Content_Types].xml", "_rels/.rels", "word/document.xml",
                                              "word/_rels/document.xml.rels", "word/styles.xml", "word/numbering.xml"], cwd: tmp)
    }
}

// MARK: - EPUB

enum EPUBWriter {
    static func write(markdown: String, title: String, to out: URL) async throws {
        let tmp = try OutputNamer.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)

        let lang = NLLanguageRecognizer.dominantLanguage(for: String(markdown.prefix(2000)))?.rawValue ?? "en"
        let body = MarkdownRenderer.bodyXHTML(markdown)
        let esc = XLSX.xmlEscape(title)
        let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"

        func put(_ path: String, _ s: String) throws { try s.write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try put("mimetype", "application/epub+zip")
        try put("META-INF/container.xml", xmlHead + """
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        try put("OEBPS/chapter.xhtml", xmlHead + """
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(lang)"><head><meta charset="utf-8"/><title>\(esc)</title>
        <style>body{font-family:serif;line-height:1.6;margin:1.2em}h1,h2,h3{font-family:sans-serif}pre{white-space:pre-wrap}</style></head>
        <body>\n\(body)\n</body></html>
        """)
        try put("OEBPS/nav.xhtml", xmlHead + """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><meta charset="utf-8"/><title>\(esc)</title></head>
        <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">\(esc)</a></li></ol></nav></body></html>
        """)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        try put("OEBPS/content.opf", xmlHead + """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="\(lang)">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
        <dc:title>\(esc)</dc:title><dc:language>\(lang)</dc:language><meta property="dcterms:modified">\(stamp)</meta></metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/></spine></package>
        """)

        try? fm.removeItem(at: out)
        // mimetype must be the first entry and stored uncompressed
        try await Shell.run("/usr/bin/zip", ["-X0", "-q", out.path, "mimetype"], cwd: tmp)
        try await Shell.run("/usr/bin/zip", ["-Xr9", "-q", out.path, "META-INF", "OEBPS"], cwd: tmp)
    }
}
