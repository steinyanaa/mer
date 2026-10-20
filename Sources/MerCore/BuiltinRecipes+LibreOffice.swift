import Foundation

/// LibreOffice recipes. Kept in their own file so each engine can be maintained independently.
extension BuiltinRecipes {
    // MARK: LibreOffice

    static var libreoffice: [Recipe] {
        func lo(_ out: String, _ title: String, cat: Category, ins: [String]) -> Recipe {
            Recipe(id: "soffice.\(cat.rawValue).\(out)", title: title, subtitle: nil, kind: .convert, category: cat,
                   symbol: nil, inputs: ins, output: out, requires: "soffice",
                   command: ["{tool}", "--headless", "--convert-to", out, "--outdir", "{tmpdir}", "{input}"],
                   params: nil, collect: true, batch: false, suffix: nil, accepts: nil)
        }
        let slides = ["ppt", "pptx", "odp", "key"]
        let sheets = ["xls", "xlsx", "ods", "csv"]
        let docs = ["doc", "docx", "odt", "rtf", "wps", "pages"]
        return [
            lo("pdf", "PDF", cat: .slides, ins: slides), lo("pptx", "PPTX", cat: .slides, ins: ["ppt", "odp", "key"]),
            lo("pdf", "PDF", cat: .spreadsheet, ins: sheets), lo("xlsx", "XLSX", cat: .spreadsheet, ins: ["xls", "ods"]),
            lo("ods", "ODS", cat: .spreadsheet, ins: ["xls", "xlsx"]), lo("xls", "XLS", cat: .spreadsheet, ins: ["xlsx", "ods"]),
            lo("pdf", "PDF", cat: .document, ins: docs), lo("docx", "DOCX", cat: .document, ins: ["doc", "odt", "wps"]),
        ].map { var r = $0; r.id = "soffice.\(r.category.rawValue).\(r.output).\(r.inputs.joined(separator: "-"))"; return r }
    }
}
