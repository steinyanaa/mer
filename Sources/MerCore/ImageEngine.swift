import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import PDFKit
import AppKit

enum ImageEngine {
    static let inputExts: Set<String> = [
        "jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp", "avif",
        "ico", "icns", "jp2", "tga", "dng", "cr2", "nef", "arw", "svg",
    ]
    static let rasterExts = inputExts.subtracting(["svg"])

    struct Target {
        let ext: String
        let title: String
        let type: UTType
        let lossy: Bool
        let opaqueOnly: Bool
        let defaultQuality: Double
    }

    /// Output formats this Mac's ImageIO can actually write.
    static let targets: [Target] = {
        let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let all: [Target] = [
            Target(ext: "jpg", title: "JPG", type: .jpeg, lossy: true, opaqueOnly: true, defaultQuality: 0.9),
            Target(ext: "png", title: "PNG", type: .png, lossy: false, opaqueOnly: false, defaultQuality: 1),
            Target(ext: "webp", title: "WebP", type: .webP, lossy: true, opaqueOnly: false, defaultQuality: 0.85),
            Target(ext: "heic", title: "HEIC", type: .heic, lossy: true, opaqueOnly: false, defaultQuality: 0.85),
            Target(ext: "tiff", title: "TIFF", type: .tiff, lossy: false, opaqueOnly: false, defaultQuality: 1),
            Target(ext: "avif", title: "AVIF", type: UTType("public.avif") ?? .png, lossy: true, opaqueOnly: false, defaultQuality: 0.8),
            Target(ext: "bmp", title: "BMP", type: .bmp, lossy: false, opaqueOnly: true, defaultQuality: 1),
            Target(ext: "gif", title: "GIF", type: .gif, lossy: false, opaqueOnly: false, defaultQuality: 1),
            Target(ext: "jp2", title: "JPEG 2000", type: UTType("public.jpeg-2000") ?? .jpeg, lossy: true, opaqueOnly: false, defaultQuality: 0.9),
            Target(ext: "ico", title: "ICO", type: UTType("com.microsoft.ico") ?? .png, lossy: false, opaqueOnly: false, defaultQuality: 1),
            Target(ext: "icns", title: "ICNS", type: UTType("com.apple.icns") ?? .png, lossy: false, opaqueOnly: false, defaultQuality: 1),
        ]
        return all.filter { supported.contains($0.type.identifier) }
    }()

    static func actions() -> [MerAction] {
        var list: [MerAction] = []

        for t in targets {
            list.append(MerAction(
                id: "convert.image.\(t.ext)", kind: .convert, title: t.title,
                category: .image, symbol: "photo", engine: "ImageIO",
                accepts: { url in
                    !url.isDirectory && url.fullExt != t.ext && !(t.ext == "jpg" && url.fullExt == "jpeg")
                        && inputExts.contains(url.fullExt)
                        && !(url.fullExt == "ico" && t.ext == "ico") && !(url.fullExt == "icns" && t.ext == "icns")
                },
                work: { inputs, ctx in
                    let out = OutputNamer.url(for: inputs[0], ext: t.ext, policy: ctx.policy)
                    try convert(inputs[0], to: out, target: t)
                    return [out]
                }))
        }

        list.append(MerAction(
            id: "convert.image.pdf", kind: .convert, title: "PDF", category: .image,
            symbol: "doc.richtext", engine: "PDFKit",
            accepts: Accept.ext(rasterExts),
            work: { inputs, ctx in
                let out = OutputNamer.url(for: inputs[0], ext: "pdf", policy: ctx.policy)
                try imagesToPDF(inputs, out: out)
                return [out]
            }))

        // MARK: tools
        let editable: @Sendable (URL) -> Bool = { rasterExts.contains($0.fullExt) && !$0.isDirectory }

        list.append(tool("resize50", "Resize 50%", "arrow.down.right.and.arrow.up.left", editable, scale: 0.5) { $0 })
        list.append(MerAction(
            id: "tool.image.resize", kind: .tool, title: "Resize…", subtitle: "Longest side in pixels",
            category: .image, symbol: "arrow.up.left.and.arrow.down.right", engine: "ImageIO",
            params: [Param(key: "size", label: "Longest side (px)", kind: .number, defaultValue: "1920")],
            accepts: editable,
            work: { inputs, ctx in
                guard let px = Int(ctx.param("size", default: "1920")), px > 0 else {
                    throw MerError.failed("Size must be a positive number of pixels")
                }
                return [try edit(inputs[0], suffix: " (\(px)px)", policy: ctx.policy, maxPixel: px) { $0 }]
            }))
        list.append(MerAction(
            id: "tool.image.compress", kind: .tool, title: "Compress", subtitle: "Smaller file, same dimensions",
            category: .image, symbol: "arrow.down.circle", engine: "ImageIO",
            params: [Param(key: "quality", label: "Quality (1–100)", kind: .number, defaultValue: "60")],
            accepts: { ["jpg", "jpeg", "heic", "heif", "webp", "avif"].contains($0.fullExt) },
            work: { inputs, ctx in
                guard let quality = Double(ctx.param("quality", default: "60")), quality > 0, quality <= 100 else {
                    throw MerError.failed("Quality must be a number from 1 to 100")
                }
                let q = quality / 100
                return [try edit(inputs[0], suffix: " (compressed)", policy: ctx.policy, quality: min(max(q, 0.05), 1), strip: true) { $0 }]
            }))
        list.append(tool("rotate-cw", "Rotate 90° Right", "rotate.right", editable) { rotate($0, quarterTurns: 1) })
        list.append(tool("rotate-ccw", "Rotate 90° Left", "rotate.left", editable) { rotate($0, quarterTurns: 3) })
        list.append(tool("rotate-180", "Rotate 180°", "arrow.triangle.2.circlepath", editable) { rotate($0, quarterTurns: 2) })
        list.append(tool("flip-h", "Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", editable) { flip($0, horizontal: true) })
        list.append(tool("flip-v", "Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down", editable) { flip($0, horizontal: false) })
        for (key, title, w, h) in [("square", "Crop Square (1:1)", 1.0, 1.0), ("16x9", "Crop 16:9", 16.0, 9.0),
                                   ("4x3", "Crop 4:3", 4.0, 3.0), ("3x2", "Crop 3:2", 3.0, 2.0)] {
            list.append(tool("crop-\(key)", title, "crop", editable) { centerCrop($0, aspect: w / h) })
        }
        list.append(MerAction(
            id: "tool.image.strip", kind: .tool, title: "Remove Metadata", subtitle: "EXIF, GPS and camera info",
            category: .image, symbol: "eye.slash", engine: "ImageIO",
            accepts: editable,
            work: { inputs, ctx in
                [try edit(inputs[0], suffix: " (clean)", policy: ctx.policy, strip: true) { $0 }]
            }))
        list.append(MerAction(
            id: "tool.image.combine-pdf", kind: .tool, title: "Combine into One PDF",
            category: .image, symbol: "doc.on.doc", engine: "PDFKit", batch: true, minFiles: 2,
            accepts: Accept.ext(rasterExts),
            work: { inputs, ctx in
                let out = OutputNamer.url(for: inputs[0], ext: "pdf", suffix: " (combined)", policy: ctx.policy)
                try imagesToPDF(inputs, out: out)
                return [out]
            }))
        return list
    }

    private static func tool(_ key: String, _ title: String, _ symbol: String,
                             _ accepts: @escaping @Sendable (URL) -> Bool,
                             scale: Double? = nil,
                             _ op: @escaping @Sendable (CGImage) -> CGImage) -> MerAction {
        MerAction(
            id: "tool.image.\(key)", kind: .tool, title: title, category: .image,
            symbol: symbol, engine: "ImageIO", accepts: accepts,
            work: { inputs, ctx in
                [try edit(inputs[0], suffix: " (\(title.lowercased()))", policy: ctx.policy, scale: scale, op: op)]
            })
    }

    // MARK: - Conversion

    static func convert(_ input: URL, to out: URL, target: Target) throws {
        if input.fullExt == "svg" || target.ext == "ico" || target.ext == "icns" {
            try convertViaBitmap(input, to: out, target: target)
            return
        }
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw MerError.failed("Cannot read \(input.lastPathComponent)")
        }
        let count = CGImageSourceGetCount(src)
        let frames = (target.type == .gif || target.type == .tiff) ? max(count, 1) : 1
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, target.type.identifier as CFString, frames, nil) else {
            throw MerError.failed("Cannot write \(target.title)")
        }
        var options: [CFString: Any] = [:]
        if target.lossy { options[kCGImageDestinationLossyCompressionQuality] = target.defaultQuality }

        let needsFlatten: Bool = {
            guard target.opaqueOnly, let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
            return hasAlpha(img)
        }()

        if needsFlatten {
            guard let img = orientedImage(src), let flat = flatten(img) else { throw MerError.failed("Image decode failed") }
            CGImageDestinationAddImage(dest, flat, options as CFDictionary)
        } else {
            for i in 0..<frames {
                CGImageDestinationAddImageFromSource(dest, src, i, options as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw MerError.failed("Failed to write \(out.lastPathComponent)")
        }
    }

    /// SVG sources and icon containers: render to a bitmap first, then write every needed size.
    static func convertViaBitmap(_ input: URL, to out: URL, target: Target) throws {
        let source: CGImage
        if input.fullExt == "svg" {
            guard let cg = renderSVG(input, longestSide: target.ext == "ico" || target.ext == "icns" ? 1024 : 2048) else {
                throw MerError.failed("Cannot render SVG")
            }
            source = cg
        } else {
            guard let src = CGImageSourceCreateWithURL(input as CFURL, nil), let cg = orientedImage(src) else {
                throw MerError.failed("Cannot read \(input.lastPathComponent)")
            }
            source = cg
        }

        let sizes: [Int]
        switch target.ext {
        case "ico": sizes = [256, 128, 64, 48, 32, 16]
        case "icns": sizes = [512, 256, 128, 32, 16]
        default: sizes = []
        }

        if sizes.isEmpty {
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, target.type.identifier as CFString, 1, nil) else {
                throw MerError.failed("Cannot write \(target.title)")
            }
            var img = source
            if target.opaqueOnly, hasAlpha(img), let flat = flatten(img) { img = flat }
            var options: [CFString: Any] = [:]
            if target.lossy { options[kCGImageDestinationLossyCompressionQuality] = target.defaultQuality }
            CGImageDestinationAddImage(dest, img, options as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw MerError.failed("Failed to write \(out.lastPathComponent)") }
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, target.type.identifier as CFString, sizes.count, nil) else {
            throw MerError.failed("Cannot write \(target.title)")
        }
        for size in sizes {
            // square canvas, image centred and scaled to fit, transparent padding
            guard let ctx = makeContext(width: size, height: size) else { continue }
            let scale = min(Double(size) / Double(source.width), Double(size) / Double(source.height))
            let w = Double(source.width) * scale, h = Double(source.height) * scale
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: (Double(size) - w) / 2, y: (Double(size) - h) / 2, width: w, height: h))
            if let frame = ctx.makeImage() { CGImageDestinationAddImage(dest, frame, nil) }
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw MerError.failed("Failed to write \(out.lastPathComponent)")
        }
    }

    /// AppKit's SVG renderer, drawn at a useful size (SVGs are often tiny by default).
    static func renderSVG(_ url: URL, longestSide: Int) -> CGImage? {
        func render() -> CGImage? {
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = CGFloat(longestSide) / max(image.size.width, image.size.height)
            let w = Int((image.size.width * scale).rounded()), h = Int((image.size.height * scale).rounded())
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        // NSImage's SVG path is main-thread territory
        return Thread.isMainThread ? render() : DispatchQueue.main.sync { render() }
    }

    static func imagesToPDF(_ inputs: [URL], out: URL) throws {
        let doc = PDFDocument()
        for url in inputs {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = orientedImage(src) else {
                throw MerError.failed("Cannot read \(url.lastPathComponent)")
            }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            guard let page = PDFPage(image: image) else { throw MerError.failed("PDF page failed") }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.write(to: out) else { throw MerError.failed("Cannot write PDF") }
    }

    // MARK: - Editing

    @discardableResult
    static func edit(_ input: URL, suffix: String, policy: OutputPolicy,
                     maxPixel: Int? = nil, scale: Double? = nil, quality: Double? = nil, strip: Bool = false,
                     op: (CGImage) -> CGImage) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw MerError.failed("Cannot read \(input.lastPathComponent)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        var limit = maxPixel
        if let scale { limit = Int(Double(max(w, h)) * scale) }
        if let l = limit, l >= max(w, h) { limit = nil }   // never upscale

        guard let base = orientedImage(src, maxPixel: limit) else { throw MerError.failed("Image decode failed") }
        let result = op(base)

        // Keep the original format when we can write it, otherwise PNG.
        var target = targets.first { $0.ext == input.fullExt || ($0.ext == "jpg" && input.fullExt == "jpeg")
            || ($0.ext == "tiff" && input.fullExt == "tif") }
        if target == nil { target = targets.first { $0.ext == "png" } }
        guard let t = target else { throw MerError.failed("No writable format") }
        let outExt = (input.fullExt == "jpeg") ? "jpeg" : (input.fullExt == "tif" ? "tif" : t.ext)
        let out = OutputNamer.url(for: input, ext: outExt, suffix: suffix, policy: policy)

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, t.type.identifier as CFString, 1, nil) else {
            throw MerError.failed("Cannot write \(t.title)")
        }
        var options: [CFString: Any] = [:]
        if t.lossy { options[kCGImageDestinationLossyCompressionQuality] = quality ?? t.defaultQuality }
        var final = result
        if t.opaqueOnly, hasAlpha(final), let flat = flatten(final) { final = flat }
        CGImageDestinationAddImage(dest, final, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MerError.failed("Failed to write \(out.lastPathComponent)") }
        _ = strip
        return out
    }

    // MARK: - Pixel helpers

    static func orientedImage(_ src: CGImageSource, maxPixel: Int? = nil) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let full = max(w, h)
        guard full > 0 else { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? full, full),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func flatten(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    static func rotate(_ img: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return img }
        let w = img.width, h = img.height
        let swap = turns % 2 == 1
        guard let ctx = makeContext(width: swap ? h : w, height: swap ? w : h) else { return img }
        ctx.translateBy(x: CGFloat(swap ? h : w) / 2, y: CGFloat(swap ? w : h) / 2)
        // CoreGraphics rotates counter-clockwise for positive angles; quarterTurns counts clockwise.
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? img
    }

    static func flip(_ img: CGImage, horizontal: Bool) -> CGImage {
        guard let ctx = makeContext(width: img.width, height: img.height) else { return img }
        if horizontal {
            ctx.translateBy(x: CGFloat(img.width), y: 0); ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(img.height)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func centerCrop(_ img: CGImage, aspect: Double) -> CGImage {
        let w = Double(img.width), h = Double(img.height)
        var cw = w, ch = w / aspect
        if ch > h { ch = h; cw = h * aspect }
        let rect = CGRect(x: ((w - cw) / 2).rounded(), y: ((h - ch) / 2).rounded(),
                          width: cw.rounded(), height: ch.rounded())
        return img.cropping(to: rect) ?? img
    }
}
