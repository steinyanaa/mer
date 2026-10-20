import Foundation

/// Recipes that become available automatically once the matching engine is installed.
enum BuiltinRecipes {
    static let videoIn = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "3gp", "gif"]
    static let audioIn = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "ogg", "oga", "opus", "wma", "ac3", "amr"]

    static var all: [Recipe] { ffmpeg + pandoc + libreoffice + magick + qpdf }

    /// Encoders this ffmpeg build actually has (Homebrew builds differ, e.g. no libvorbis).
    private static func encoders() -> Set<String> {
        guard let bin = Tooling.find("ffmpeg") else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var names = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].count == 6 { names.insert(String(parts[1])) }
        }
        return names
    }

    // MARK: FFmpeg

    private static func ff(_ id: String, _ title: String, kind: ActionKind = .convert, cat: Category,
                           inputs: [String], out: String, args: [String], subtitle: String? = nil,
                           suffix: String? = nil, params: [Recipe.RecipeParam]? = nil, symbol: String? = nil) -> Recipe {
        Recipe(id: id, title: title, subtitle: subtitle, kind: kind, category: cat, symbol: symbol, inputs: inputs,
               output: out, requires: "ffmpeg",
               command: ["{tool}", "-hide_banner", "-loglevel", "error", "-y", "-i", "{input}"] + args + ["{output}"],
               params: params, collect: false, batch: false, suffix: suffix, accepts: nil)
    }

    static var ffmpeg: [Recipe] {
        var r: [Recipe] = []
        let even = "scale=trunc(iw/2)*2:trunc(ih/2)*2"           // H.264/H.265/VP9 need even dimensions
        let h264 = ["-vf", even, "-pix_fmt", "yuv420p", "-c:v", "libx264"]
        r.append(ff("ffmpeg.video.mkv", "MKV", cat: .video, inputs: videoIn, out: "mkv", args: h264 + ["-c:a", "aac"]))
        r.append(ff("ffmpeg.video.webm", "WebM", cat: .video, inputs: videoIn, out: "webm",
                    args: ["-vf", even, "-pix_fmt", "yuv420p", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]))
        r.append(ff("ffmpeg.video.avi", "AVI", cat: .video, inputs: videoIn, out: "avi",
                    args: ["-pix_fmt", "yuv420p", "-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame"]))
        r.append(ff("ffmpeg.video.wmv", "WMV", cat: .video, inputs: videoIn, out: "wmv",
                    args: ["-pix_fmt", "yuv420p", "-c:v", "wmv2", "-c:a", "wmav2"]))
        r.append(ff("ffmpeg.video.mp4", "MP4", cat: .video, inputs: videoIn, out: "mp4",
                    args: h264 + ["-crf", "23", "-preset", "medium", "-c:a", "aac", "-movflags", "+faststart"]))
        r.append(ff("ffmpeg.video.mov", "MOV", cat: .video, inputs: videoIn, out: "mov",
                    args: h264 + ["-c:a", "aac"]))
        r.append(ff("ffmpeg.video.gif", "GIF", cat: .video, inputs: videoIn, out: "gif",
                    args: ["-vf", "fps=12,scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", "-loop", "0"]))

        let enc = encoders()
        let audioTargets: [(String, String, [String])] = [
            ("mp3", "MP3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]),
            ("ogg", "OGG", enc.contains("libvorbis") ? ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
                                                       : ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", "160k"]),
            ("opus", "Opus", ["-vn", "-c:a", "libopus", "-b:a", "128k"]),
            ("wma", "WMA", ["-vn", "-c:a", "wmav2"]),
            ("flac", "FLAC", ["-vn", "-c:a", "flac"]),
            ("wav", "WAV", ["-vn", "-c:a", "pcm_s16le"]),
            ("m4a", "M4A (AAC)", ["-vn", "-c:a", "aac", "-b:a", "256k"]),
            ("aiff", "AIFF", ["-vn", "-c:a", "pcm_s16be"]),
        ]
        for (ext, title, args) in audioTargets {
            r.append(ff("ffmpeg.audio.\(ext)", title, cat: .audio, inputs: audioIn + videoIn.filter { $0 != "gif" }, out: ext, args: args,
                        symbol: "waveform"))
        }

        // tools that keep the original container
        func sameFormat(_ id: String, _ title: String, _ args: [String], cat: Category, ins: [String],
                        sub: String? = nil, suffix: String, params: [Recipe.RecipeParam]? = nil, symbol: String) -> [Recipe] {
            ins.map { ext in
                var rec = ff("\(id).\(ext)", title, kind: .tool, cat: cat, inputs: [ext], out: ext, args: args,
                             subtitle: sub, suffix: suffix, params: params, symbol: symbol)
                rec.id = "\(id).\(ext)"
                return rec
            }
        }
        // One generic recipe per tool: output extension must equal input, so we register per extension.
        r += sameFormat("ffmpeg.video.crf", "Compress (Smart)", ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-crf", "28", "-preset", "medium", "-c:a", "aac", "-b:a", "128k"],
                        cat: .video, ins: ["mp4", "mov", "m4v", "mkv"], sub: "H.264 CRF 28", suffix: " (compressed)", symbol: "arrow.down.circle")
        r += sameFormat("ffmpeg.video.trim", "Trim (Lossless)…", ["-ss", "{param:start}", "-to", "{param:end}", "-c", "copy"],
                        cat: .video, ins: ["mp4", "mov", "m4v", "mkv", "webm", "avi"], sub: "Keeps quality, format unchanged", suffix: " (trimmed)",
                        params: [.init(key: "start", label: "Start (hh:mm:ss or seconds)", defaultValue: "0", type: "text"),
                                 .init(key: "end", label: "End (hh:mm:ss or seconds)", defaultValue: "10", type: "text")], symbol: "scissors")
        r += sameFormat("ffmpeg.audio.normalize", "Normalise Loudness", ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"],
                        cat: .audio, ins: ["mp3", "m4a", "wav", "flac", "ogg", "opus"], suffix: " (normalised)", symbol: "speaker.wave.2")
        r += sameFormat("ffmpeg.audio.trim", "Trim (Lossless)…", ["-ss", "{param:start}", "-to", "{param:end}", "-c", "copy"],
                        cat: .audio, ins: ["mp3", "m4a", "wav", "flac", "ogg", "opus"], sub: "Keeps quality, format unchanged", suffix: " (trimmed)",
                        params: [.init(key: "start", label: "Start (hh:mm:ss or seconds)", defaultValue: "0", type: "text"),
                                 .init(key: "end", label: "End (hh:mm:ss or seconds)", defaultValue: "10", type: "text")], symbol: "scissors")
        return r
    }

}
