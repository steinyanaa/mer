import Foundation

/// ImageMagick recipes. Kept in their own file so each engine can be maintained independently.
extension BuiltinRecipes {
    // MARK: ImageMagick

    private static let magickProbeLock = NSLock()
    private nonisolated(unsafe) static var magickProbe: (path: String, jxl: Bool)?

    /// Whether this ImageMagick build can decode JPEG XL. Homebrew's plain `imagemagick` has no JXL (nor
    /// librsvg) delegate, so we only offer what actually works. Probed once per magick binary.
    private static var magickSupportsJXL: Bool {
        guard let tool = Tooling.find("magick") else { return false }
        magickProbeLock.lock(); defer { magickProbeLock.unlock() }
        if let probe = magickProbe, probe.path == tool { return probe.jxl }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-list", "format"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var jxl = false
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            // Lines look like "      JXL  JXL       rw-   JPEG XL ..." (mode column starts with r when readable).
            jxl = String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                return f.count >= 3 && f[0].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == "JXL" && f[2].hasPrefix("r")
            }
        }
        magickProbe = (tool, jxl)
        return jxl
    }

    /// ImageMagick 7 ships no font configuration on Homebrew, so SVG text fails with "unable to read font"
    /// unless a font is named explicitly.
    private static let magickFont = ["-font", "/System/Library/Fonts/Helvetica.ttc"]

    static var magick: [Recipe] {
        // Vector sources are rasterised at 192 dpi (2x their nominal size); raster sources are read as-is.
        // PDF page size: vector sources keep their physical size (192 dpi raster -> 72 pt); raster ones map 1 px = 1 pt.
        // `[0]` keeps one frame: PSD would otherwise also emit its layers, ICO every size, XCF every layer.
        struct Group { let inputs: [String]; let read: [String]; let pdfDPI: String }
        let groups = [
            Group(inputs: ["svg", "eps", "ai"],
                  read: ["-background", "none", "-density", "192"] + magickFont + ["{input}[0]"], pdfDPI: "192"),
            Group(inputs: ["ico", "psd"] + (magickSupportsJXL ? ["jxl"] : []),
                  read: ["-background", "none"] + magickFont + ["{input}[0]"], pdfDPI: "72"),
            // GIMP files are layered: merge them (honouring each layer's offset) instead of taking one.
            Group(inputs: ["xcf"],
                  read: ["-background", "none", "{input}", "-flatten", "+repage"], pdfDPI: "72"),
        ]

        let targets: [(ext: String, title: String, tail: [String])] = [
            ("png", "PNG", ["-depth", "8"]),
            // JPEG has no alpha: composite on white instead of the default black.
            ("jpg", "JPG", ["-background", "white", "-alpha", "remove", "-alpha", "off", "-depth", "8", "-quality", "92"]),
            ("webp", "WebP", ["-depth", "8", "-quality", "90"]),
            // PDF: placeholder, the page-size density is filled in per group below.
            ("pdf", "PDF", ["-background", "white", "-alpha", "remove", "-alpha", "off", "-units", "PixelsPerInch", "-density", "@DPI@"]),
        ]

        var out: [Recipe] = []
        // Vector-preserving routes first (the registry keeps the first action per title).
        out.append(Recipe(id: "gs.eps-ai-pdf", title: "PDF", subtitle: "via Ghostscript (vector)", kind: .convert, category: .image,
                          symbol: "photo", inputs: ["eps", "ai"], output: "pdf", requires: "gs",
                          command: ["{tool}", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-dEPSCrop",
                                    "-sDEVICE=pdfwrite", "-sOutputFile={output}", "{input}"],
                          params: nil, collect: false, batch: false, suffix: nil, accepts: nil))
        out.append(Recipe(id: "rsvg.svg-pdf", title: "PDF", subtitle: "via librsvg (vector)", kind: .convert, category: .image,
                          symbol: "photo", inputs: ["svg"], output: "pdf", requires: "rsvg-convert",
                          command: ["{tool}", "-f", "pdf", "-o", "{output}", "{input}"],
                          params: nil, collect: false, batch: false, suffix: nil, accepts: nil))

        for (gi, g) in groups.enumerated() {
            for t in targets {
                out.append(Recipe(id: gi == 0 ? "magick.\(t.ext)" : "magick.\(t.ext).\(gi == 1 ? "raster" : "xcf")",
                                  title: t.title, subtitle: "via ImageMagick", kind: .convert, category: .image,
                                  symbol: "photo", inputs: g.inputs, output: t.ext, requires: "magick",
                                  command: ["{tool}"] + g.read + t.tail.map { $0 == "@DPI@" ? g.pdfDPI : $0 } + ["{output}"],
                                  params: nil, collect: false, batch: false, suffix: nil, accepts: nil))
            }
        }

        // PNG/JPG/SVG/WebP -> multi-size ICO. Fit into a square first so non-square art is not distorted.
        out.append(Recipe(id: "magick.ico", title: "ICO", subtitle: "16–256 px icon", kind: .convert, category: .image,
                          symbol: "photo", inputs: ["png", "jpg", "jpeg", "svg", "webp"], output: "ico", requires: "magick",
                          command: ["{tool}", "-background", "none", "-density", "192"] + magickFont
                              + ["{input}[0]", "-resize", "256x256", "-gravity", "center", "-extent", "256x256",
                                 "-define", "icon:auto-resize=256,128,64,48,32,16", "{output}"],
                          params: nil, collect: false, batch: false, suffix: nil, accepts: nil))
        return out
    }
}
