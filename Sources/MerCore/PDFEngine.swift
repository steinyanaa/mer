import Foundation
import PDFKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Quartz

enum PDFEngine {
    static let isPDF: @Sendable (URL) -> Bool = { !$0.isDirectory && $0.fullExt == "pdf" }

    static func actions() -> [MerAction] {
        var list: [MerAction] = []

        for (ext, title, type) in [("png", "PNG", UTType.png), ("jpg", "JPG", UTType.jpeg)] {
            list.append(MerAction(
                id: "convert.pdf.\(ext)", kind: .convert, title: title, subtitle: "One image per page",
                category: .pdf, symbol: "photo", engine: "PDFKit", accepts: isPDF,
                work: { inputs, ctx in try rasterize(inputs[0], ext: ext, type: type, dpi: 150, policy: ctx.policy, progress: ctx.progress) }))
        }
        list.append(MerAction(
            id: "convert.pdf.txt", kind: .convert, title: "TXT", category: .pdf, symbol: "text.alignleft",
            engine: "PDFKit", accepts: isPDF,
            work: { inputs, ctx in
                guard let doc = PDFDocument(url: inputs[0]) else { throw MerError.failed("Cannot open PDF") }
                var text = doc.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // scanned PDF: no text layer, so recognise it with Vision
                    let pages = try OCREngine.ocrPages(of: inputs[0], progress: ctx.progress)
                    text = pages.map { OCREngine.plainText($0) }.joined(separator: "\n\n")
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MerError.failed("No text found in this PDF") }
                }
                let out = OutputNamer.url(for: inputs[0], ext: "txt", policy: ctx.policy)
                try text.write(to: out, atomically: true, encoding: .utf8)
                return [out]
            }))
        list.append(MerAction(
            id: "convert.pdf.docx", kind: .convert, title: "DOCX", subtitle: "Text only — layout is not preserved",
            category: .pdf, symbol: "doc.text", engine: "PDFKit+textutil", accepts: isPDF,
            work: { inputs, ctx in
                guard let doc = PDFDocument(url: inputs[0]) else { throw MerError.failed("Cannot open PDF") }
                var text = doc.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = try OCREngine.ocrPages(of: inputs[0], progress: ctx.progress).map { OCREngine.plainText($0) }.joined(separator: "\n\n")
                    if text.isEmpty { throw MerError.failed("No text found in this PDF") }
                }
                let tmp = try OutputNamer.makeTempDir()
                defer { try? FileManager.default.removeItem(at: tmp) }
                let txt = tmp.appendingPathComponent("t.txt")
                try text.write(to: txt, atomically: true, encoding: .utf8)
                let out = OutputNamer.url(for: inputs[0], ext: "docx", policy: ctx.policy)
                try await DocumentEngine.textutil(txt, format: "docx", to: out)
                return [out]
            }))

        // MARK: tools
        list.append(MerAction(
            id: "tool.pdf.merge", kind: .tool, title: "Merge PDFs", category: .pdf, symbol: "arrow.triangle.merge",
            engine: "PDFKit", batch: true, minFiles: 2, accepts: isPDF,
            work: { inputs, ctx in
                let merged = PDFDocument()
                for url in inputs {
                    guard let d = PDFDocument(url: url) else { throw MerError.failed("Cannot open \(url.lastPathComponent)") }
                    for i in 0..<d.pageCount { if let p = d.page(at: i) { merged.insert(p, at: merged.pageCount) } }
                }
                let out = OutputNamer.url(for: inputs[0], ext: "pdf", suffix: " (merged)", policy: ctx.policy)
                guard merged.write(to: out) else { throw MerError.failed("Cannot write PDF") }
                return [out]
            }))
        list.append(MerAction(
            id: "tool.pdf.split", kind: .tool, title: "Split into Pages", category: .pdf, symbol: "square.split.2x1",
            engine: "PDFKit", accepts: isPDF,
            work: { inputs, ctx in
                guard let doc = PDFDocument(url: inputs[0]), doc.pageCount > 1 else { throw MerError.failed("PDF has a single page") }
                let dir = OutputNamer.folder(for: inputs[0], suffix: " pages", policy: ctx.policy)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var outs: [URL] = []
                for i in 0..<doc.pageCount {
                    let one = PDFDocument()
                    if let p = doc.page(at: i) { one.insert(p, at: 0) }
                    let out = dir.appendingPathComponent("\(inputs[0].baseName) - \(i + 1).pdf")
                    one.write(to: out); outs.append(out)
                    ctx.progress(Double(i + 1) / Double(doc.pageCount))
                }
                return [dir]
            }))
        list.append(MerAction(
            id: "tool.pdf.extract", kind: .tool, title: "Extract Pages…", subtitle: "e.g. 1-3, 5, 8-10",
            category: .pdf, symbol: "doc.badge.plus", engine: "PDFKit",
            params: [Param(key: "pages", label: "Pages", kind: .text, defaultValue: "1")],
            accepts: isPDF,
            work: { inputs, ctx in
                guard let doc = PDFDocument(url: inputs[0]) else { throw MerError.failed("Cannot open PDF") }
                let indices = parsePages(ctx.param("pages", default: "1"), max: doc.pageCount)
                guard !indices.isEmpty else { throw MerError.failed("No valid pages in range") }
                let out = PDFDocument()
                for i in indices { if let p = doc.page(at: i - 1) { out.insert(p, at: out.pageCount) } }
                let url = OutputNamer.url(for: inputs[0], ext: "pdf", suffix: " (extract)", policy: ctx.policy)
                guard out.write(to: url) else { throw MerError.failed("Cannot write PDF") }
                return [url]
            }))
        list.append(MerAction(
            id: "tool.pdf.rotate", kind: .tool, title: "Rotate 90° Right", category: .pdf, symbol: "rotate.right",
            engine: "PDFKit", accepts: isPDF,
            work: { inputs, ctx in
                guard let doc = PDFDocument(url: inputs[0]) else { throw MerError.failed("Cannot open PDF") }
                for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
                let out = OutputNamer.url(for: inputs[0], ext: "pdf", suffix: " (rotated)", policy: ctx.policy)
                guard doc.write(to: out) else { throw MerError.failed("Cannot write PDF") }
                return [out]
            }))
        list.append(MerAction(
            id: "tool.pdf.compress", kind: .tool, title: "Compress PDF", subtitle: "Downsamples embedded images",
            category: .pdf, symbol: "arrow.down.circle", engine: "Quartz", accepts: isPDF,
            work: { inputs, ctx in
                let out = OutputNamer.url(for: inputs[0], ext: "pdf", suffix: " (compressed)", policy: ctx.policy)
                try await compress(inputs[0], to: out)
                return [out]
            }))
        return list
    }

    static func parsePages(_ spec: String, max: Int) -> [Int] {
        var result: [Int] = []
        for part in spec.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1 { result.append(bounds[0]) }
            else if bounds.count == 2, bounds[0] <= bounds[1] { result += Array(bounds[0]...bounds[1]) }
        }
        return result.filter { $0 >= 1 && $0 <= max }
    }

    // MARK: - Rasterize

    static func rasterize(_ url: URL, ext: String, type: UTType, dpi: Double, policy: OutputPolicy,
                          progress: @escaping @Sendable (Double) -> Void) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw MerError.failed("Cannot open PDF") }
        let count = doc.pageCount
        guard count > 0 else { throw MerError.failed("PDF has no pages") }
        let scale = dpi / 72
        var folder: URL?
        if count > 1 {
            folder = OutputNamer.folder(for: url, policy: policy)
            try FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true)
        }
        var outs: [URL] = []
        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            guard let image = ctx.makeImage() else { continue }

            let out: URL
            if let folder { out = folder.appendingPathComponent("\(url.baseName) - \(i + 1).\(ext)") }
            else { out = OutputNamer.url(for: url, ext: ext, policy: policy) }
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            CGImageDestinationFinalize(dest)
            outs.append(out)
            progress(Double(i + 1) / Double(count))
        }
        return folder.map { [$0] } ?? outs
    }

    // MARK: - Compress

    /// Uses Ghostscript when present, otherwise macOS's own "Reduce File Size" Quartz filter.
    static func compress(_ input: URL, to out: URL) async throws {
        if let gs = Tooling.find("gs") {
            do {
                try await Shell.run(gs, ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5", "-dPDFSETTINGS=/ebook",
                                         "-dSAFER", "-dNOPAUSE", "-dQUIET", "-dBATCH", "-sOutputFile=\(out.path)", input.path])
            } catch {
                try? FileManager.default.removeItem(at: out)   // don't leave a partial file behind
                throw error
            }
            // Never make files bigger (same rule as the Quartz path below).
            let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            if size(out) >= size(input) {
                try? FileManager.default.removeItem(at: out)
                throw MerError.failed("Already optimised — compression would not make it smaller")
            }
            return
        }
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let doc = CGPDFDocument(input as CFURL), let filter = QuartzFilter(url: filterURL) else {
            throw MerError.failed("Cannot open PDF or Quartz filter")
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw MerError.failed("Cannot create PDF") }
        var box = CGRect.zero
        guard let page1 = doc.page(at: 1) else { throw MerError.failed("Empty PDF") }
        box = page1.getBoxRect(.mediaBox)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw MerError.failed("Cannot create PDF") }
        filter.apply(to: ctx)
        for n in 1...doc.numberOfPages {
            guard let page = doc.page(at: n) else { continue }
            var pageBox = page.getBoxRect(.mediaBox)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.drawPDFPage(page)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        // Never make files bigger.
        let original = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        if data.length >= original { throw MerError.failed("Already optimised — compression would not make it smaller") }
        try (data as Data).write(to: out)
    }
}
