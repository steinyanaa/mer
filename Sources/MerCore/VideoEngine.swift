import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoEngine {
    static let nativeInputs: Set<String> = ["mp4", "mov", "m4v"]

    static func actions() -> [MerAction] {
        var list: [MerAction] = []
        let accepts = Accept.ext(nativeInputs)

        func exportAction(id: String, title: String, subtitle: String? = nil, ext: String, type: AVFileType,
                          preset: String, suffix: String = "", kind: ActionKind = .convert,
                          symbol: String = "film", sameExt: Bool = true) -> MerAction {
            MerAction(
                id: id, kind: kind, title: title, subtitle: subtitle, category: .video, symbol: symbol,
                engine: "AVFoundation",
                accepts: { url in accepts(url) && (!sameExt || url.fullExt != ext || kind == .tool) },
                work: { inputs, ctx in
                    let out = OutputNamer.url(for: inputs[0], ext: ext, suffix: suffix, policy: ctx.policy)
                    try await AVHelper.export(asset: AVURLAsset(url: inputs[0]), preset: preset, fileType: type,
                                              to: out, range: nil, progress: ctx.progress)
                    return [out]
                })
        }

        list.append(exportAction(id: "convert.video.mp4", title: "MP4", ext: "mp4", type: .mp4,
                                 preset: AVAssetExportPresetHighestQuality))
        list.append(exportAction(id: "convert.video.mov", title: "MOV", ext: "mov", type: .mov,
                                 preset: AVAssetExportPresetHighestQuality))
        list.append(exportAction(id: "convert.video.hevc", title: "MP4 (HEVC)", ext: "mp4", type: .mp4,
                                 preset: AVAssetExportPresetHEVCHighestQuality, suffix: " (HEVC)", sameExt: false))

        list.append(MerAction(
            id: "convert.video.m4a", kind: .convert, title: "M4A (AAC)", category: .audio,
            symbol: "waveform", engine: "AVFoundation", accepts: accepts,
            work: { inputs, ctx in
                let asset = AVURLAsset(url: inputs[0])
                guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
                    throw MerError.failed("This video has no audio track")
                }
                let out = OutputNamer.url(for: inputs[0], ext: "m4a", policy: ctx.policy)
                try await AVHelper.export(asset: asset, preset: AVAssetExportPresetAppleM4A,
                                          fileType: .m4a, to: out, range: nil, progress: ctx.progress)
                return [out]
            }))

        list.append(MerAction(
            id: "convert.video.gif", kind: .convert, title: "GIF", category: .video,
            symbol: "photo.stack", engine: "AVFoundation",
            params: [Param(key: "width", label: "Width (px)", kind: .number, defaultValue: "480"),
                     Param(key: "fps", label: "Frames per second", kind: .number, defaultValue: "12")],
            accepts: accepts,
            work: { inputs, ctx in
                let out = OutputNamer.url(for: inputs[0], ext: "gif", policy: ctx.policy)
                try await makeGIF(from: inputs[0], to: out,
                                  width: Int(ctx.param("width", default: "480")) ?? 480,
                                  fps: Int(ctx.param("fps", default: "12")) ?? 12, progress: ctx.progress)
                return [out]
            }))

        // MARK: tools
        for (key, title, preset, sym) in [
            ("720p", "Compress to 720p", AVAssetExportPreset1280x720, "arrow.down.circle"),
            ("480p", "Compress to 480p", AVAssetExportPreset640x480, "arrow.down.circle"),
            ("1080p", "Resize to 1080p", AVAssetExportPreset1920x1080, "arrow.up.left.and.arrow.down.right"),
        ] {
            list.append(MerAction(
                id: "tool.video.\(key)", kind: .tool, title: title, category: .video, symbol: sym,
                engine: "AVFoundation", accepts: accepts,
                work: { inputs, ctx in
                    let type: AVFileType = inputs[0].fullExt == "mov" ? .mov : .mp4
                    let out = OutputNamer.url(for: inputs[0], ext: inputs[0].fullExt == "mov" ? "mov" : "mp4",
                                              suffix: " (\(key))", policy: ctx.policy)
                    try await AVHelper.export(asset: AVURLAsset(url: inputs[0]), preset: preset, fileType: type,
                                              to: out, range: nil, progress: ctx.progress)
                    return [out]
                }))
        }

        list.append(MerAction(
            id: "tool.video.trim", kind: .tool, title: "Trim…", subtitle: "Cut by start and end time (seconds)",
            category: .video, symbol: "scissors", engine: "AVFoundation",
            params: [Param(key: "start", label: "Start (s)", kind: .number, defaultValue: "0"),
                     Param(key: "end", label: "End (s, 0 = until the end)", kind: .number, defaultValue: "0")],
            accepts: accepts,
            work: { inputs, ctx in
                let asset = AVURLAsset(url: inputs[0])
                let isMov = inputs[0].fullExt == "mov"
                let out = OutputNamer.url(for: inputs[0], ext: isMov ? "mov" : "mp4", suffix: " (trimmed)", policy: ctx.policy)
                try await AVHelper.export(asset: asset, preset: AVAssetExportPresetPassthrough,
                                          fileType: isMov ? .mov : .mp4, to: out,
                                          range: try await AVHelper.range(for: asset, params: ctx.params),
                                          progress: ctx.progress)
                return [out]
            }))

        list.append(MerAction(
            id: "tool.video.mute", kind: .tool, title: "Remove Audio", category: .video, symbol: "speaker.slash",
            engine: "AVFoundation", accepts: accepts,
            work: { inputs, ctx in
                let asset = AVURLAsset(url: inputs[0])
                let comp = AVMutableComposition()
                let duration = try await asset.load(.duration)
                guard let src = try await asset.loadTracks(withMediaType: .video).first,
                      let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw MerError.failed("No video track") }
                try dst.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: src, at: .zero)
                dst.preferredTransform = try await src.load(.preferredTransform)
                let isMov = inputs[0].fullExt == "mov"
                let out = OutputNamer.url(for: inputs[0], ext: isMov ? "mov" : "mp4", suffix: " (muted)", policy: ctx.policy)
                try await AVHelper.export(asset: comp, preset: AVAssetExportPresetPassthrough,
                                          fileType: isMov ? .mov : .mp4, to: out, range: nil, progress: ctx.progress)
                return [out]
            }))

        list.append(MerAction(
            id: "tool.video.merge", kind: .tool, title: "Merge Videos", category: .video, symbol: "arrow.triangle.merge",
            engine: "AVFoundation", batch: true, minFiles: 2, accepts: accepts,
            work: { inputs, ctx in
                let comp = AVMutableComposition()
                var cursor = CMTime.zero
                for url in inputs {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    let range = CMTimeRange(start: .zero, duration: duration)
                    for type in [AVMediaType.video, .audio] {
                        guard let src = try await asset.loadTracks(withMediaType: type).first else { continue }
                        let existing = comp.tracks(withMediaType: type).first
                        let dst = existing ?? comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                        if type == .video, existing == nil { dst?.preferredTransform = try await src.load(.preferredTransform) }
                        try dst?.insertTimeRange(range, of: src, at: cursor)
                    }
                    cursor = cursor + duration
                }
                let out = OutputNamer.url(for: inputs[0], ext: "mp4", suffix: " (merged)", policy: ctx.policy)
                try await AVHelper.export(asset: comp, preset: AVAssetExportPresetHighestQuality, fileType: .mp4,
                                          to: out, range: nil, progress: ctx.progress)
                return [out]
            }))

        list.append(MerAction(
            id: "tool.video.frame", kind: .tool, title: "Save Frame as JPG…", subtitle: "Grab a still at a given second",
            category: .video, symbol: "camera.viewfinder", engine: "AVFoundation",
            params: [Param(key: "at", label: "Time (s)", kind: .number, defaultValue: "0")],
            accepts: accepts,
            work: { inputs, ctx in
                let asset = AVURLAsset(url: inputs[0])
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter = .zero
                let t = CMTime(seconds: Double(ctx.param("at", default: "0")) ?? 0, preferredTimescale: 600)
                let image = try await gen.image(at: t).image
                let out = OutputNamer.url(for: inputs[0], ext: "jpg", suffix: " (frame)", policy: ctx.policy)
                guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw MerError.failed("Cannot write JPG") }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw MerError.failed("Cannot write JPG") }
                return [out]
            }))
        return list
    }

    static func makeGIF(from url: URL, to out: URL, width: Int, fps: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw MerError.failed("Empty video") }
        let fps = max(1, min(fps, 30))
        let capped = min(duration, 30)   // keep GIFs sane
        let frameCount = max(1, Int(capped * Double(fps)))

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: width, height: width * 4)   // width-bound, aspect preserved
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw MerError.failed("Cannot create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary

        for i in 0..<frameCount {
            try Task.checkCancellation()
            let t = CMTime(seconds: Double(i) / Double(fps), preferredTimescale: 600)
            let image = try await gen.image(at: t).image
            CGImageDestinationAddImage(dest, image, frameProps)
            progress(Double(i + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(dest) else { throw MerError.failed("GIF encoding failed") }
    }
}
