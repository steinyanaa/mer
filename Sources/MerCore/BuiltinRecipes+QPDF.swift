import Foundation

/// QPDF recipes. Kept in their own file so each engine can be maintained independently.
extension BuiltinRecipes {
    // MARK: qpdf

    static var qpdf: [Recipe] {
        [Recipe(id: "qpdf.decrypt", title: "Remove PDF Password…", subtitle: nil, kind: .tool, category: .pdf,
                symbol: "lock.open", inputs: ["pdf"], output: "pdf", requires: "qpdf",
                command: ["{tool}", "--password={param:password}", "--decrypt", "{input}", "{output}"],
                params: [.init(key: "password", label: "Password", defaultValue: "", type: "text", required: true)],
                collect: false, batch: false, suffix: " (unlocked)", accepts: nil),
         Recipe(id: "qpdf.encrypt", title: "Protect with Password…", subtitle: nil, kind: .tool, category: .pdf,
                symbol: "lock", inputs: ["pdf"], output: "pdf", requires: "qpdf",
                command: ["{tool}", "--encrypt", "{param:password}", "{param:password}", "256", "--", "{input}", "{output}"],
                params: [.init(key: "password", label: "Password", defaultValue: "", type: "text", required: true)],
                collect: false, batch: false, suffix: " (protected)", accepts: nil)]
    }
}
