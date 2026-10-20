import Foundation
import AVFoundation

enum AudioEngine {
    static let inputExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "alac", "ac3", "amr", "mp2"]

    private struct Target {
        let ext: String, title: String, args: [String]
    }

    private static let targets: [Target] = [
        Target(ext: "m4a", title: "M4A (AAC)", args: ["-f", "m4af", "-d", "aac", "-q", "127"]),
        Target(ext: "wav", title: "WAV", args: ["-f", "WAVE", "-d", "LEI16"]),
        Target(ext: "aiff", title: "AIFF", args: ["-f", "AIFF", "-d", "BEI16"]),
        Target(ext: "flac", title: "FLAC", args: ["-f", "flac", "-d", "flac"]),
    ]

    static func actions() -> [MerAction] {
        var list: [MerAction] = []
        for t in targets {
            list.append(MerAction(
                id: "convert.audio.\(t.ext)", kind: .convert, title: t.title,
                category: .audio, symbol: "waveform", engine: "afconvert",
                accepts: { url in !url.isDirectory && url.fullExt != t.ext && inputExts.contains(url.fullExt)
                    && !(t.ext == "aiff" && url.fullExt == "aif") },
                work: { inputs, ctx in
                    let out = OutputNamer.url(for: inputs[0], ext: t.ext, policy: ctx.policy)
                    try await Shell.run("/usr/bin/afconvert", t.args + [inputs[0].path, out.path])
                    return [out]
                }))
        }

        list.append(MerAction(
            id: "tool.audio.trim", kind: .tool, title: "Trim…", subtitle: "Cut by start and end time (seconds)",
            category: .audio, symbol: "scissors", engine: "AVFoundation",
            params: [Param(key: "start", label: "Start (s)", kind: .number, defaultValue: "0"),
                     Param(key: "end", label: "End (s, 0 = until the end)", kind: .number, defaultValue: "0")],
            accepts: Accept.ext(inputExts),
            work: { inputs, ctx in
                let out = OutputNamer.url(for: inputs[0], ext: "m4a", suffix: " (trimmed)", policy: ctx.policy)
                try await AVHelper.export(asset: AVURLAsset(url: inputs[0]), preset: AVAssetExportPresetAppleM4A,
                                          fileType: .m4a, to: out,
                                          range: try await AVHelper.range(for: AVURLAsset(url: inputs[0]), params: ctx.params),
                                          progress: ctx.progress)
                return [out]
            }))

        list.append(MerAction(
            id: "tool.audio.merge", kind: .tool, title: "Merge into One Track",
            category: .audio, symbol: "arrow.triangle.merge", engine: "AVFoundation",
            batch: true, minFiles: 2, accepts: Accept.ext(inputExts),
            work: { inputs, ctx in
                let out = OutputNamer.url(for: inputs[0], ext: "m4a", suffix: " (merged)", policy: ctx.policy)
                let comp = AVMutableComposition()
                var cursor = CMTime.zero
                for url in inputs {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    guard let src = try await asset.loadTracks(withMediaType: .audio).first,
                          let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { continue }
                    try dst.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: src, at: cursor)
                    cursor = cursor + duration
                }
                try await AVHelper.export(asset: comp, preset: AVAssetExportPresetAppleM4A, fileType: .m4a,
                                          to: out, range: nil, progress: ctx.progress)
                return [out]
            }))
        return list
    }
}

// MARK: - Shared AVFoundation helpers

enum AVHelper {
    final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }

    /// Parses `start` / `end` params (seconds) into a time range; nil = whole asset.
    static func range(for asset: AVAsset, params: [String: String]) async throws -> CMTimeRange? {
        func seconds(_ key: String) throws -> Double {
            guard let raw = params[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return 0 }
            guard let v = Double(raw), v >= 0 else { throw MerError.failed("\(key.capitalized) must be a number of seconds") }
            return v
        }
        let start = try seconds("start")
        let end = try seconds("end")
        let total = try await asset.load(.duration).seconds
        let realEnd = (end <= 0 || end > total) ? total : end
        guard start >= 0, realEnd > start else { throw MerError.failed("Invalid time range") }
        if start == 0 && realEnd >= total { return nil }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           end: CMTime(seconds: realEnd, preferredTimescale: 600))
    }

    static func export(asset: AVAsset, preset: String, fileType: AVFileType, to url: URL,
                       range: CMTimeRange?, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MerError.failed("Preset \(preset) is not available for this file")
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw MerError.failed("This file cannot be exported as \(fileType.rawValue)")
        }
        session.outputURL = url
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let range { session.timeRange = range }
        let box = SessionBox(session)

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poller.cancel() }

        try await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { c.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        try Task.checkCancellation()
        if box.session.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw MerError.failed(box.session.error?.localizedDescription ?? "Export failed")
        }
        progress(1)
    }
}
