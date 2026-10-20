import Foundation

/// CSV / TSV / JSON / XLSX conversions, implemented without third-party libraries.
enum DataEngine {
    static let inputExts: Set<String> = ["csv", "tsv", "xlsx", "json"]

    private struct Target { let ext: String; let title: String }
    private static let targets = [
        Target(ext: "xlsx", title: "XLSX"), Target(ext: "csv", title: "CSV"),
        Target(ext: "tsv", title: "TSV"), Target(ext: "json", title: "JSON"),
    ]

    static func actions() -> [MerAction] {
        targets.map { t in
            MerAction(
                id: "convert.sheet.\(t.ext)", kind: .convert, title: t.title, category: .spreadsheet,
                symbol: "tablecells", engine: "Built-in",
                accepts: { url in
                    guard !url.isDirectory, inputExts.contains(url.fullExt), url.fullExt != t.ext else { return false }
                    return true
                },
                work: { inputs, ctx in
                    let rows = try await read(inputs[0])
                    let out = OutputNamer.url(for: inputs[0], ext: t.ext, policy: ctx.policy)
                    try await write(rows, to: out, ext: t.ext)
                    return [out]
                })
        }
    }

    static func read(_ url: URL) async throws -> [[String]] {
        switch url.fullExt {
        case "csv": return CSV.parse(try String(contentsOf: url, encoding: .utf8), delimiter: ",")
        case "tsv": return CSV.parse(try String(contentsOf: url, encoding: .utf8), delimiter: "\t")
        case "json": return try jsonRows(Data(contentsOf: url))
        case "xlsx": return try await XLSX.read(url)
        default: throw MerError.unsupported(url.fullExt)
        }
    }

    static func write(_ rows: [[String]], to url: URL, ext: String) async throws {
        switch ext {
        case "csv": try CSV.serialize(rows, delimiter: ",").write(to: url, atomically: true, encoding: .utf8)
        case "tsv": try CSV.serialize(rows, delimiter: "\t").write(to: url, atomically: true, encoding: .utf8)
        case "json":
            guard let header = rows.first else { throw MerError.failed("Empty table") }
            let objects = rows.dropFirst().map { row -> [String: String] in
                var d: [String: String] = [:]
                for (i, h) in header.enumerated() { d[h.isEmpty ? "column\(i + 1)" : h] = i < row.count ? row[i] : "" }
                return d
            }
            let data = try JSONSerialization.data(withJSONObject: Array(objects), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        case "xlsx": try await XLSX.write(rows, to: url)
        default: throw MerError.unsupported(ext)
        }
    }

    static func jsonRows(_ data: Data) throws -> [[String]] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let array = obj as? [[String: Any]], !array.isEmpty else {
            throw MerError.failed("JSON must be an array of objects")
        }
        var headers: [String] = []
        for item in array { for k in item.keys.sorted() where !headers.contains(k) { headers.append(k) } }
        let body = array.map { item in headers.map { stringify(item[$0]) } }
        return [headers] + body
    }

    private static func stringify(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default:
            if let v, let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) { return s }
            return "\(v!)"
        }
    }
}

enum CSV {
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: ""))[...]
        while let c = chars.popFirst() {
            if inQuotes {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == delimiter { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""; rows.append(row); row = []
            } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func serialize(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { f in
                f.contains(delimiter) || f.contains("\"") || f.contains("\n") || f.contains("\r")
                    ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: - XLSX

enum XLSX {
    static func read(_ url: URL) async throws -> [[String]] {
        func entry(_ path: String) async -> Data? {
            guard let r = try? await Shell.run("/usr/bin/unzip", ["-p", url.path, path], allowFailure: true), r.status == 0 else { return nil }
            return r.out.data(using: .utf8)
        }
        var shared: [String] = []
        if let d = await entry("xl/sharedStrings.xml") { shared = SharedStringsParser.parse(d) }
        var sheet = await entry("xl/worksheets/sheet1.xml")
        if sheet == nil {
            // First sheet might not be sheet1.xml — find it.
            let list = try await Shell.run("/usr/bin/unzip", ["-Z1", url.path]).out
            if let name = list.split(separator: "\n").map(String.init).filter({ $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }).sorted().first {
                sheet = await entry(name)
            }
        }
        guard let sheet else { throw MerError.failed("No worksheet found in XLSX") }
        return SheetParser.parse(sheet, shared: shared)
    }

    static func write(_ rows: [[String]], to url: URL) async throws {
        let tmp = try OutputNamer.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        for d in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ s: String) throws { try s.write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        try put("[Content_Types].xml", head + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#)
        try put("_rels/.rels", head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        try put("xl/workbook.xml", head + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#)
        try put("xl/_rels/workbook.xml.rels", head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#)

        var xml = head + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                if Double(value) != nil, !value.hasPrefix("0") || value == "0" || value.contains(".") {
                    xml += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        try put("xl/worksheets/sheet1.xml", xml)

        try? fm.removeItem(at: url)
        try await Shell.run("/usr/bin/zip", ["-X", "-q", url.path, "[Content_Types].xml", "_rels/.rels",
                                              "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"], cwd: tmp)
    }

    static func columnName(_ index: Int) -> String {
        var n = index, s = ""
        repeat { s = String(UnicodeScalar(65 + n % 26)!) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    static func columnIndex(_ ref: String) -> Int {
        var idx = 0
        for ch in ref.unicodeScalars where ch.value >= 65 && ch.value <= 90 { idx = idx * 26 + Int(ch.value - 64) }
        return idx - 1
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = "", inT = false, inSI = false

    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser()
        let xml = XMLParser(data: data); xml.delegate = p; xml.parse()
        return p.strings
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "si" { inSI = true; current = "" } else if name == "t" { inT = true }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inT && inSI { current += s } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inT = false } else if name == "si" { strings.append(current); inSI = false }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    private var row: [String] = []
    private var shared: [String] = []
    private var cellType = "", cellRef = "", text = "", inV = false, inT = false

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let p = SheetParser(); p.shared = shared
        let xml = XMLParser(data: data); xml.delegate = p; xml.parse()
        return p.rows
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "row": row = []
        case "c": cellType = a["t"] ?? ""; cellRef = a["r"] ?? ""; text = ""
        case "v": inV = true
        case "t": inT = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inV || inT { text += s } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inV = false
        case "t": inT = false
        case "c":
            var value = text
            if cellType == "s", let i = Int(text), i < shared.count { value = shared[i] }
            if cellType == "b" { value = text == "1" ? "TRUE" : "FALSE" }
            let col = XLSX.columnIndex(cellRef)
            while col >= 0 && row.count < col { row.append("") }
            row.append(value)
        case "row": rows.append(row)
        default: break
        }
    }
}
