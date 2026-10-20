import Foundation
import MerCore

let usage = """
mer — offline file converter and toolbox

USAGE
  mer list [file …]                       Actions available for the files (or every action)
  mer convert <file …> --to <format>      Convert, e.g. --to png
  mer run <action-id|title> <file …>      Run a tool, e.g. "Resize…" --param size=800
  mer engines                             Show optional engines (ffmpeg, pandoc …)
  mer install <engine>                    Install an engine through Homebrew (e.g. mer install ffmpeg)
  mer recipes                             Print the folder for custom JSON recipes

OPTIONS
  --to <fmt>          Target format (convert)
  --out <dir>         Write results to this folder instead of next to the source
  --param key=value   Parameter for tools that take one (repeatable)
  --json              Machine-readable output for list
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
if command == "-h" || command == "--help" || command == "help" { print(usage); exit(0) }
args.removeFirst()

var files: [URL] = []
var target: String?
var outDir: URL?
var params: [String: String] = [:]
var json = false
var positional: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--to": i += 1; target = i < args.count ? args[i].lowercased() : nil
    case "--out": i += 1; if i < args.count { outDir = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath, isDirectory: true) }
    case "--param":
        i += 1
        if i < args.count, let eq = args[i].firstIndex(of: "=") {
            params[String(args[i][..<eq])] = String(args[i][args[i].index(after: eq)...])
        }
    case "--json": json = true
    case "-h", "--help": print(usage); exit(0)
    default: positional.append(a)
    }
    i += 1
}

func fileURLs(_ paths: [String]) -> [URL] {
    paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
}

let registry = ActionRegistry.shared

switch command {
case "list":
    let urls = fileURLs(positional)
    let actions = urls.isEmpty ? registry.all : registry.actions(for: urls)
    if json {
        let rows = actions.map { ["id": $0.id, "title": $0.title, "kind": $0.kind.rawValue, "category": $0.category.rawValue, "engine": $0.engine] }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        for kind in [ActionKind.convert, .tool] {
            let group = actions.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            print(kind == .convert ? "CONVERSIONS (\(group.count))" : "TOOLS (\(group.count))")
            for cat in Category.allCases {
                let items = group.filter { $0.category == cat }
                guard !items.isEmpty else { continue }
                print("  \(cat.title): " + items.map(\.title).joined(separator: ", "))
            }
        }
        if urls.isEmpty {
            let conv = actions.filter { $0.kind == .convert }.count, tools = actions.filter { $0.kind == .tool }.count
            print("\n\(conv) conversions, \(tools) tools registered.")
        }
    }

case "convert", "run":
    var name: String?
    if command == "run" { guard !positional.isEmpty else { fail("run needs an action") }; name = positional.removeFirst() }
    let urls = fileURLs(positional)
    guard !urls.isEmpty else { fail("No files given.") }
    for u in urls where !FileManager.default.fileExists(atPath: u.path) { fail("No such file: \(u.path)") }

    // registration order, not usage ranking: native engines must win over external ones for the same title
    let candidates = registry.actions(for: urls, rankByUsage: false)
    let match: MerAction?
    if command == "convert" {
        guard let t = target else { fail("convert needs --to <format>") }
        // exact title first ("mp4" must not pick "MP4 (HEVC)" just because it was used more), then id suffix, then title prefix
        let converts = candidates.filter { $0.kind == .convert }
        match = converts.first { $0.title.lowercased() == t }
            ?? converts.first { $0.id.hasSuffix(".\(t)") }
            ?? converts.first { $0.title.lowercased().hasPrefix(t + " ") }
    } else {
        let n = name!.lowercased()
        // an exact id always wins, even when a native action with the same title hides it in the deduped list
        let exact = registry.action(id: name!).flatMap { a in urls.count >= a.minFiles && urls.allSatisfy(a.accepts) ? a : nil }
        match = exact
            ?? candidates.first { $0.id.lowercased() == n || $0.title.lowercased() == n }
            ?? candidates.first { $0.title.lowercased().hasPrefix(n) || $0.id.lowercased().hasSuffix(n) }
    }
    guard let action = match else {
        fail("No matching action for these files. Try: mer list \(urls.map(\.lastPathComponent).joined(separator: " "))")
    }
    // fill defaults for params the user did not supply
    for p in action.params where params[p.key] == nil { params[p.key] = p.defaultValue }

    if let outDir { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
    let job = await JobCenter.shared.runAndWait(action, inputs: urls, params: params, policy: OutputPolicy(directory: outDir))
    switch job.state {
    case .done:
        for o in job.outputs { print(o.path) }
    case .failed(let msg): fail("Failed: \(msg)")
    default: fail("Cancelled")
    }

case "engines":
    for e in Engines.catalogue {
        let status = e.path.map { "✓ \($0)" } ?? "✗ not installed  →  \(e.installCommand)"
        print("\(e.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(status)")
        print("             unlocks: \(e.unlocks)")
    }

case "install":
    guard let name = positional.first?.lowercased(),
          let engine = Engines.catalogue.first(where: { $0.binary == name || $0.name.lowercased() == name }) else {
        fail("Unknown engine. Available: " + Engines.catalogue.map { $0.name.lowercased() }.joined(separator: ", "))
    }
    if engine.installed { print("\(engine.name) is already installed at \(engine.path!)"); exit(0) }
    let installer = EngineInstaller.shared
    installer.install(engine)
    var last = ""
    while true {
        let state = installer.state(for: engine)
        switch state {
        case .installing(let line): if line != last { print("  \(line)"); last = line }
        case .done: print("✓ \(engine.name) installed. \(ActionRegistry.shared.all.count) actions available."); exit(0)
        case .failed(let msg): fail("✗ \(msg)")
        case .idle: break
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

case "recipes":
    let dir = Tooling.supportDirectory.appendingPathComponent("Recipes").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    print(dir)

default:
    print(usage)
    exit(command == "help" ? 0 : 1)
}
