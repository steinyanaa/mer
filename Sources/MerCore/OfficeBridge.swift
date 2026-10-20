import Foundation
import AppKit

/// Uses Apple's own Pages / Keynote / Numbers (when installed) for iWork and Office conversions
/// that cannot be done faithfully by any library.
enum OfficeBridge {
    private struct App {
        let bundleID: String
        let name: String
        let inputs: Set<String>
        let category: Category
        /// (output ext, title, AppleScript export format)
        let outputs: [(String, String, String)]
    }

    private static let apps: [App] = [
        App(bundleID: "com.apple.iWork.Pages", name: "Pages",
            inputs: ["pages", "docx", "doc", "rtf", "odt"], category: .document,
            outputs: [("pdf", "PDF", "PDF"), ("docx", "DOCX", "Microsoft Word"), ("epub", "EPUB", "EPUB")]),
        App(bundleID: "com.apple.iWork.Keynote", name: "Keynote",
            inputs: ["key", "pptx", "ppt", "pps", "ppsx"], category: .slides,
            outputs: [("pdf", "PDF", "PDF"), ("pptx", "PPTX", "Microsoft PowerPoint")]),
        App(bundleID: "com.apple.iWork.Numbers", name: "Numbers",
            inputs: ["numbers", "xlsx", "xls"], category: .spreadsheet,
            outputs: [("pdf", "PDF", "PDF"), ("xlsx", "XLSX", "Microsoft Excel"), ("csv", "CSV", "CSV")]),
    ]

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func actions() -> [MerAction] {
        var list: [MerAction] = []
        for app in apps where isInstalled(app.bundleID) {
            for (ext, title, format) in app.outputs {
                list.append(MerAction(
                    id: "iwork.\(app.name.lowercased()).\(ext)", kind: .convert, title: title,
                    subtitle: "via \(app.name)", category: app.category, symbol: nil, engine: app.name,
                    accepts: { url in !url.isDirectory && app.inputs.contains(url.fullExt) && url.fullExt != ext },
                    work: { inputs, ctx in
                        let out = OutputNamer.url(for: inputs[0], ext: ext, policy: ctx.policy)
                        try await export(app: app.bundleID, input: inputs[0], output: out, format: format)
                        return [out]
                    }))
            }
            if app.name == "Keynote" {
                for (ext, title, fmt) in [("png", "PNG", "PNG"), ("jpg", "JPG", "JPEG")] {
                    list.append(MerAction(
                        id: "iwork.keynote.\(ext)", kind: .convert, title: title, subtitle: "One image per slide, via Keynote",
                        category: .slides, symbol: nil, engine: "Keynote",
                        accepts: { url in !url.isDirectory && app.inputs.contains(url.fullExt) },
                        work: { inputs, ctx in
                            let dir = OutputNamer.folder(for: inputs[0], policy: ctx.policy)
                            try await exportSlides(input: inputs[0], dir: dir, format: fmt)
                            return [dir]
                        }))
                }
            }
        }
        return list
    }

    private static func export(app: String, input: URL, output: URL, format: String) async throws {
        let script = """
        on run argv
          tell application id "\(app)"
            set theDoc to open POSIX file (item 1 of argv)
            try
              export theDoc to POSIX file (item 2 of argv) as \(format)
            on error e
              close theDoc saving no
              error e
            end try
            close theDoc saving no
          end tell
        end run
        """
        try await Shell.run("/usr/bin/osascript", ["-e", script, input.path, output.path])
    }

    private static func exportSlides(input: URL, dir: URL, format: String) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        on run argv
          tell application id "com.apple.iWork.Keynote"
            set theDoc to open POSIX file (item 1 of argv)
            try
              export theDoc to POSIX file (item 2 of argv) as slide images with properties {image format:\(format)}
            on error e
              close theDoc saving no
              error e
            end try
            close theDoc saving no
          end tell
        end run
        """
        try await Shell.run("/usr/bin/osascript", ["-e", script, input.path, dir.path])
    }
}
