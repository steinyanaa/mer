import Foundation

/// QPDF recipes. Kept in their own file so each engine can be maintained independently.
extension BuiltinRecipes {
    // MARK: qpdf

    static var qpdf: [Recipe] {
        [Recipe(id: "qpdf.decrypt", title: "Remove PDF Password…", subtitle: nil, kind: .tool, category: .pdf,
                symbol: "lock.open", inputs: ["pdf"], output: "pdf", requires: "qpdf",
                // Many PDFs open without a password but forbid copying/editing (owner restrictions). Those are removed with
                // an empty password, so the password is optional here (it is only needed for PDFs that ask for one to open).
                command: ["{tool}", "--password={param:password}", "--decrypt", "{input}", "{output}"],
                params: [.init(key: "password", label: "Password (leave empty if none)", defaultValue: "", type: "text")],
                collect: false, batch: false, suffix: " (unlocked)", accepts: nil),
         Recipe(id: "qpdf.encrypt", title: "Protect with Password…", subtitle: nil, kind: .tool, category: .pdf,
                symbol: "lock", inputs: ["pdf"], output: "pdf", requires: "qpdf",
                command: ["{tool}", "--encrypt", "{param:password}", "{param:password}", "256", "--", "{input}", "{output}"],
                params: [.init(key: "password", label: "Password", defaultValue: "", type: "text", required: true)],
                collect: false, batch: false, suffix: " (protected)", accepts: nil)]
    }
}
