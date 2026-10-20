import Foundation

/// Reads Word documents straight from their XML so that style-based headings, numbering, tables and hyperlinks
/// survive (macOS's own importers ignore paragraph styles and drop hyperlinks).
enum DOCXReader {
    static func paragraphs(from docx: URL) async -> [RichPara] {
        func part(_ path: String) async -> Data? {
            guard let r = try? await Shell.run("/usr/bin/unzip", ["-p", docx.path, path], allowFailure: true), r.status == 0,
                  !r.out.isEmpty else { return nil }
            return r.out.data(using: .utf8)
        }
        guard let body = await part("word/document.xml") else { return [] }
        let styles = (await part("word/styles.xml")).map(StylesParser.parse) ?? [:]
        let numbering = (await part("word/numbering.xml")).map(NumberingParser.parse) ?? NumberingInfo()
        let rels = (await part("word/_rels/document.xml.rels")).map(DOCXLinks.relationships) ?? [:]
        return BodyParser.parse(body, styles: styles, numbering: numbering, rels: rels)
    }

    // MARK: styles

    struct StyleInfo { var name = "", basedOn = "", outline: Int? }

    private static func headingLevel(_ id: String, in styles: [String: StyleInfo]) -> Int? {
        var current = id
        for _ in 0..<6 {
            guard let s = styles[current] else { return nil }
            let n = s.name.lowercased()
            if let m = n.firstMatch(#"^heading\s*([1-9])$"#) { return Int(m[1]) }
            if n == "title" { return 1 }
            if n == "subtitle" { return 2 }
            if let o = s.outline { return min(o + 1, 6) }
            if s.basedOn.isEmpty { return nil }
            current = s.basedOn
        }
        return nil
    }

    private final class StylesParser: NSObject, XMLParserDelegate {
        var styles: [String: StyleInfo] = [:]
        private var current: String?
        static func parse(_ d: Data) -> [String: StyleInfo] {
            let p = StylesParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.styles
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch name {
            case "w:style": current = a["w:styleId"]; if let c = current { styles[c] = StyleInfo() }
            case "w:name": if let c = current { styles[c]?.name = a["w:val"] ?? "" }
            case "w:basedOn": if let c = current { styles[c]?.basedOn = a["w:val"] ?? "" }
            case "w:outlineLvl": if let c = current, let v = a["w:val"].flatMap(Int.init) { styles[c]?.outline = v }
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "w:style" { current = nil }
        }
    }

    // MARK: numbering

    struct NumberingInfo {
        var numToAbstract: [String: String] = [:]
        var formats: [String: [Int: String]] = [:]      // abstractNumId → ilvl → numFmt
        func isBullet(numId: String, level: Int) -> Bool {
            guard let abs = numToAbstract[numId], let fmt = formats[abs]?[level] else { return true }
            return fmt == "bullet" || fmt == "none"
        }
    }

    private final class NumberingParser: NSObject, XMLParserDelegate {
        var info = NumberingInfo()
        private var abstractID: String?, numID: String?, level: Int?
        static func parse(_ d: Data) -> NumberingInfo {
            let p = NumberingParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.info
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch name {
            case "w:abstractNum": abstractID = a["w:abstractNumId"]
            case "w:lvl": level = a["w:ilvl"].flatMap(Int.init)
            case "w:numFmt": if let abs = abstractID, let l = level { info.formats[abs, default: [:]][l] = a["w:val"] ?? "" }
            case "w:num": numID = a["w:numId"]
            case "w:abstractNumId": if let n = numID, abstractID == nil || true, let v = a["w:val"] { info.numToAbstract[n] = v }
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "w:abstractNum" { abstractID = nil } else if name == "w:lvl" { level = nil } else if name == "w:num" { numID = nil }
        }
    }

    // MARK: body

    private final class BodyParser: NSObject, XMLParserDelegate {
        let styles: [String: StyleInfo], numbering: NumberingInfo, rels: [String: String]
        var result: [RichPara] = []

        // paragraph state
        private var inPara = false, inPPr = false, inRun = false, inRPr = false, inText = false
        private var styleID = "", numID: String?, ilvl = 0
        private var runs: [RichPara.Run] = []
        private var run = RichPara.Run(text: "")
        private var linkTarget: String?
        private var counters: [String: Int] = [:]

        // table state
        private var tableDepth = 0
        private var rows: [[String]] = [], cells: [String] = [], cellText: [String] = []

        init(styles: [String: StyleInfo], numbering: NumberingInfo, rels: [String: String]) {
            self.styles = styles; self.numbering = numbering; self.rels = rels
        }

        static func parse(_ d: Data, styles: [String: StyleInfo], numbering: NumberingInfo, rels: [String: String]) -> [RichPara] {
            let p = BodyParser(styles: styles, numbering: numbering, rels: rels)
            let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.result
        }

        private func on(_ v: String?) -> Bool { !(v == "0" || v == "false" || v == "off") }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch name {
            case "w:tbl": tableDepth += 1; if tableDepth == 1 { rows = [] }
            case "w:tr": if tableDepth == 1 { cells = [] }
            case "w:tc": if tableDepth == 1 { cellText = [] }
            case "w:p":
                inPara = true; styleID = ""; numID = nil; ilvl = 0; runs = []
            case "w:pPr": inPPr = true
            case "w:pStyle": if inPPr { styleID = a["w:val"] ?? "" }
            case "w:numId": if inPPr { numID = a["w:val"] }
            case "w:ilvl": if inPPr { ilvl = Int(a["w:val"] ?? "0") ?? 0 }
            case "w:hyperlink": if let id = a["r:id"] { linkTarget = rels[id] } else if let anchor = a["w:anchor"] { linkTarget = "#" + anchor }
            case "w:r": inRun = true; run = RichPara.Run(text: ""); run.link = linkTarget
            case "w:rPr": if inRun { inRPr = true }
            case "w:rStyle": if inRPr, let v = a["w:val"]?.lowercased(), v.contains("verbatim") || v.contains("code") { run.mono = true }
            case "w:b": if inRPr { run.bold = on(a["w:val"]) }
            case "w:i": if inRPr { run.italic = on(a["w:val"]) }
            case "w:rFonts": if inRPr, let f = a["w:ascii"], ["courier", "menlo", "consolas", "monaco", "mono"].contains(where: { f.lowercased().contains($0) }) { run.mono = true }
            case "w:t": if inRun { inText = true }
            case "w:tab", "w:br", "w:noBreakHyphen": if inRun { run.text += " " }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) { if inText { run.text += s } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "w:t": inText = false
            case "w:rPr": inRPr = false
            case "w:pPr": inPPr = false
            case "w:r":
                inRun = false
                if !run.text.isEmpty { runs.append(run) }
            case "w:hyperlink": linkTarget = nil
            case "w:p": finishParagraph()
            case "w:tc": if tableDepth == 1 { cells.append(cellText.joined(separator: " ")) }
            case "w:tr": if tableDepth == 1, !cells.isEmpty { rows.append(cells) }
            case "w:tbl":
                if tableDepth == 1, !rows.isEmpty { result.append(RichPara(kind: .table(rows), runs: [])) }
                tableDepth = max(0, tableDepth - 1)
            default: break
            }
        }

        private func finishParagraph() {
            inPara = false
            // merge neighbouring runs with identical formatting so Markdown markers don't fragment
            var merged: [RichPara.Run] = []
            for r in runs {
                if var last = merged.last, last.bold == r.bold, last.italic == r.italic, last.mono == r.mono, last.link == r.link {
                    last.text += r.text; merged[merged.count - 1] = last
                } else { merged.append(r) }
            }
            let plain = merged.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

            if tableDepth >= 1 {                      // paragraphs inside a table cell
                if tableDepth == 1, !plain.isEmpty { cellText.append(plain.replacingOccurrences(of: "|", with: "\\|")) }
                return
            }
            guard !plain.isEmpty else { return }

            var para = RichPara(kind: .body, runs: merged)
            if let level = DOCXReader.headingLevel(styleID, in: styles), plain.count < 300 {
                para.kind = .heading(level)
                for i in para.runs.indices { para.runs[i].bold = false }
            } else if let id = numID, id != "0" {
                para.indent = ilvl
                if numbering.isBullet(numId: id, level: ilvl) { para.kind = .bullet }
                else {
                    let key = "\(id)/\(ilvl)"
                    counters[key, default: 0] += 1
                    for deeper in (ilvl + 1)..<(ilvl + 9) { counters["\(id)/\(deeper)"] = nil }
                    para.kind = .numbered(counters[key]!)
                }
            }
            result.append(para)
        }
    }
}
