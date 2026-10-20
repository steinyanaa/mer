import Foundation

// MARK: - Subtitles

enum SubtitleEngine {
    static let inputExts: Set<String> = ["srt", "vtt"]

    static func actions() -> [MerAction] {
        ["srt", "vtt", "txt"].map { ext in
            MerAction(
                id: "convert.subtitle.\(ext)", kind: .convert, title: ext.uppercased(), category: .subtitle,
                symbol: "captions.bubble", engine: "Built-in",
                accepts: { url in !url.isDirectory && inputExts.contains(url.fullExt) && url.fullExt != ext },
                work: { inputs, ctx in
                    let text = try readText(inputs[0])
                    let out = OutputNamer.url(for: inputs[0], ext: ext, policy: ctx.policy)
                    let converted: String
                    switch (inputs[0].fullExt, ext) {
                    case ("srt", "vtt"): converted = srtToVTT(text)
                    case ("vtt", "srt"): converted = vttToSRT(text)
                    default: converted = toPlain(text)
                    }
                    try converted.write(to: out, atomically: true, encoding: .utf8)
                    return [out]
                })
        }
    }

    private static func readText(_ url: URL) throws -> String {
        var enc = String.Encoding.utf8
        let s = try String(contentsOf: url, usedEncoding: &enc)
        return s.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static let timeLine = #"(\d{1,2}:)?\d{2}:\d{2}[,.]\d{3}\s+-->\s+(\d{1,2}:)?\d{2}:\d{2}[,.]\d{3}"#

    static func srtToVTT(_ srt: String) -> String {
        var out = ["WEBVTT", ""]
        for line in srt.components(separatedBy: "\n") {
            if line.range(of: timeLine, options: .regularExpression) != nil {
                out.append(line.replacingOccurrences(of: ",", with: "."))
            } else { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    static func vttToSRT(_ vtt: String) -> String {
        var cues: [(String, [String])] = []
        for block in vtt.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let ti = lines.firstIndex(where: { $0.range(of: timeLine, options: .regularExpression) != nil }) else { continue }
            var time = lines[ti].replacingOccurrences(of: ".", with: ",")
            if let r = time.range(of: #"(?<=\d{3})\s+[a-z].*$"#, options: .regularExpression) { time.removeSubrange(r) }   // cue settings
            // short timestamps (mm:ss.mmm) need an hour part for SRT
            time = time.replacingOccurrences(of: #"(?<![\d:])(\d{2}:\d{2},\d{3})"#, with: "00:$1", options: .regularExpression)
            cues.append((time, Array(lines[(ti + 1)...])))
        }
        return cues.enumerated().map { "\($0.offset + 1)\n\($0.element.0)\n\($0.element.1.joined(separator: "\n"))\n" }
            .joined(separator: "\n")
    }

    static func toPlain(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "WEBVTT" || Int(t) != nil || t.range(of: timeLine, options: .regularExpression) != nil { continue }
            lines.append(t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Archives

enum ArchiveEngine {
    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "tar.gz", "tar.bz2", "tbz2", "bz2", "tar.xz", "txz", "xz", "7z", "rar"]
    static let isArchive: @Sendable (URL) -> Bool = { !$0.isDirectory && archiveExts.contains($0.fullExt) }
    static let anything: @Sendable (URL) -> Bool = { _ in true }

    static func actions() -> [MerAction] {
        var list: [MerAction] = []

        list.append(MerAction(
            id: "tool.archive.extract", kind: .tool, title: "Extract", subtitle: "ZIP, TAR, GZ, BZ2, XZ, 7Z, RAR",
            category: .archive, symbol: "archivebox", engine: "bsdtar", accepts: isArchive,
            work: { inputs, ctx in
                let dir = OutputNamer.folder(for: inputs[0], policy: ctx.policy)
                try await extract(inputs[0], into: dir)
                return [dir]
            }))

        for (ext, title) in [("zip", "ZIP"), ("tar.gz", "TAR.GZ"), ("tar", "TAR")] {
            // convert: archive → other archive
            list.append(MerAction(
                id: "convert.archive.\(ext)", kind: .convert, title: title, category: .archive,
                symbol: "archivebox", engine: "bsdtar",
                accepts: { url in isArchive(url) && url.fullExt != ext && !(ext == "tar.gz" && url.fullExt == "tgz") },
                work: { inputs, ctx in
                    let tmp = try OutputNamer.makeTempDir()
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    let content = tmp.appendingPathComponent(inputs[0].baseName, isDirectory: true)
                    try await extract(inputs[0], into: content)
                    let out = OutputNamer.url(for: inputs[0], ext: ext, policy: ctx.policy)
                    try await pack(content, to: out, ext: ext)
                    return [out]
                }))
            // tool: any file/folder → archive
            list.append(MerAction(
                id: "tool.archive.pack-\(ext)", kind: .tool, title: "Compress to \(title)", category: .archive,
                symbol: "archivebox.fill", engine: "bsdtar", accepts: { url in !isArchive(url) },
                work: { inputs, ctx in
                    let out = OutputNamer.url(for: inputs[0], ext: ext, policy: ctx.policy)
                    try await pack(inputs[0], to: out, ext: ext)
                    return [out]
                }))
        }
        list.append(MerAction(
            id: "tool.archive.pack-together", kind: .tool, title: "Zip Together", category: .archive,
            symbol: "archivebox.fill", engine: "zip", batch: true, minFiles: 2, accepts: anything,
            work: { inputs, ctx in
                let dir = inputs[0].deletingLastPathComponent()
                let out = OutputNamer.unique(dir: ctx.policy.directory ?? dir, base: "Archive", ext: "zip")
                // zip stores paths relative to cwd, so files from different folders are staged via symlinks.
                let tmp = try OutputNamer.makeTempDir()
                defer { try? FileManager.default.removeItem(at: tmp) }
                var names: [String] = []
                for url in inputs {
                    var name = url.lastPathComponent, n = 2
                    while names.contains(name) { name = "\(n)-\(url.lastPathComponent)"; n += 1 }
                    try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent(name), withDestinationURL: url)
                    names.append(name)
                }
                try await Shell.run("/usr/bin/zip", ["-r", "-X", "-q", out.path] + names, cwd: tmp)
                ZipFix.markUTF8Names(out)
                return [out]
            }))
        return list
    }

    static func extract(_ archive: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if archive.fullExt == "zip" {
                try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path])
            } else {
                try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        // Plain .gz/.bz2/.xz hold a single file; tar -xf cannot unpack those to a directory.
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == true,
           ["gz", "bz2", "xz"].contains(archive.fullExt) {
            let tool = ["gz": "/usr/bin/gunzip", "bz2": "/usr/bin/bunzip2", "xz": "/usr/bin/unxz"][archive.fullExt]!
            let out = dir.appendingPathComponent(archive.baseName)
            try await Shell.run("/bin/sh", ["-c", "\"$0\" -c \"$1\" > \"$2\"", tool, archive.path, out.path])
        }
    }

    static func pack(_ source: URL, to out: URL, ext: String) async throws {
        let parent = source.deletingLastPathComponent()
        let name = source.lastPathComponent
        switch ext {
        case "zip":
            try await Shell.run("/usr/bin/zip", ["-r", "-X", "-q", out.path, name], cwd: parent)
            ZipFix.markUTF8Names(out)
        case "tar.gz": try await Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", parent.path, name])
        case "tar": try await Shell.run("/usr/bin/tar", ["-cf", out.path, "-C", parent.path, name])
        default: throw MerError.unsupported(ext)
        }
    }
}


/// macOS's zip, ditto and bsdtar all write UTF-8 file names *without* setting the "UTF-8" flag (general-purpose bit 11),
/// so Windows Explorer and many libraries show non-ASCII names as garbage. This sets the flag on entries whose names
/// contain non-ASCII bytes (the bytes are already UTF-8), in both the local headers and the central directory.
enum ZipFix {
    static func markUTF8Names(_ url: URL) {
        guard var data = try? Data(contentsOf: url), data.count > 22 else { return }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func set(_ o: Int) { data[o + 1] |= 0x08 }   // bit 11 = 0x0800: the HIGH byte of the little-endian flags (low byte 0x08 would be bit 3)

        // end-of-central-directory record
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 22 - 65_535) {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return }
        let count = u16(eocd + 10), cdStart = u32(eocd + 16)
        guard cdStart != 0xFFFF_FFFF else { return }                  // zip64: leave untouched

        var pos = cdStart
        var changed = false
        for _ in 0..<count {
            guard pos + 46 <= data.count, u32(pos) == 0x0201_4b50 else { break }
            let nameLen = u16(pos + 28), extraLen = u16(pos + 30), commentLen = u16(pos + 32), local = u32(pos + 42)
            let name = data[(pos + 46)..<(pos + 46 + nameLen)]
            if name.contains(where: { $0 >= 0x80 }) {
                set(pos + 8)
                if local + 8 <= data.count, u32(local) == 0x0403_4b50 { set(local + 6) }
                changed = true
            }
            pos += 46 + nameLen + extraLen + commentLen
        }
        if changed { try? data.write(to: url) }
    }
}
