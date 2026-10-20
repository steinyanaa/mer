import Foundation
import Vision
import PDFKit
import CoreText
import ImageIO
import AppKit

/// Offline text recognition with Apple's Vision framework.
enum OCREngine {
    struct Line {
        let text: String
        /// Normalised bounding box, origin bottom-left (Vision's convention, same as PDF space).
        let box: CGRect
    }

    private static let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU"]

    static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            let langs = preferredLanguages.filter { supported.contains($0) }
            if !langs.isEmpty { request.recognitionLanguages = langs }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        let lines = observations.compactMap { obs -> Line? in
            guard let text = obs.topCandidates(1).first?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Line(text: text, box: obs.boundingBox)
        }
        // reading order: top to bottom, then left to right (lines within half a line height count as one row)
        return lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) * 0.5 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
    }

    static func plainText(_ lines: [Line]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    // MARK: Actions

    static func actions() -> [MerAction] {
        var list: [MerAction] = []
        let image = Accept.ext(ImageEngine.rasterExts)
        let pdf = PDFEngine.isPDF

        list.append(MerAction(
            id: "convert.image.ocr-txt", kind: .convert, title: "TXT (OCR)", subtitle: "Recognise text in the picture",
            category: .image, symbol: "text.viewfinder", engine: "Vision", accepts: image,
            work: { inputs, ctx in
                guard let src = CGImageSourceCreateWithURL(inputs[0] as CFURL, nil), let cg = ImageEngine.orientedImage(src) else {
                    throw MerError.failed("Cannot read \(inputs[0].lastPathComponent)")
                }
                let text = plainText(try recognize(cg))
                guard !text.isEmpty else { throw MerError.failed("No text found in this image") }
                let out = OutputNamer.url(for: inputs[0], ext: "txt", suffix: " (OCR)", policy: ctx.policy)
                try text.write(to: out, atomically: true, encoding: .utf8)
                return [out]
            }))

        list.append(MerAction(
            id: "tool.image.ocr-pdf", kind: .tool, title: "Searchable PDF (OCR)", subtitle: "Picture + invisible text layer",
            category: .image, symbol: "doc.text.viewfinder", engine: "Vision", batch: true, accepts: image,
            work: { inputs, ctx in
                let doc = PDFDocument()
                var textPages: [[Line]] = []
                for url in inputs {
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = ImageEngine.orientedImage(src) else {
                        throw MerError.failed("Cannot read \(url.lastPathComponent)")
                    }
                    let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                    guard let page else { throw MerError.failed("PDF page failed") }
                    doc.insert(page, at: doc.pageCount)
                    textPages.append(try recognize(cg))
                    ctx.progress(Double(textPages.count) / Double(inputs.count) * 0.9)
                }
                let tmp = try OutputNamer.makeTempDir()
                defer { try? FileManager.default.removeItem(at: tmp) }
                let plain = tmp.appendingPathComponent("plain.pdf")
                guard doc.write(to: plain) else { throw MerError.failed("Cannot write PDF") }
                let out = OutputNamer.url(for: inputs[0], ext: "pdf", suffix: inputs.count > 1 ? " (OCR combined)" : " (OCR)", policy: ctx.policy)
                try addTextLayer(to: plain, lines: textPages, out: out)
                return [out]
            }))

        list.append(MerAction(
            id: "tool.pdf.ocr", kind: .tool, title: "Make Searchable (OCR)", subtitle: "Adds a text layer to scanned PDFs",
            category: .pdf, symbol: "doc.text.viewfinder", engine: "Vision", accepts: pdf,
            work: { inputs, ctx in
                let pages = try ocrPages(of: inputs[0], progress: { ctx.progress($0 * 0.9) })
                let out = OutputNamer.url(for: inputs[0], ext: "pdf", suffix: " (OCR)", policy: ctx.policy)
                try addTextLayer(to: inputs[0], lines: pages, out: out)
                return [out]
            }))
        return list
    }

    // MARK: PDF helpers

    /// Recognises text on every page of a PDF (rendered at ~200 dpi).
    static func ocrPages(of url: URL, progress: @Sendable (Double) -> Void = { _ in }) throws -> [[Line]] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw MerError.failed("Cannot open PDF") }
        var result: [[Line]] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let image = render(page, dpi: 200) else { result.append([]); continue }
            result.append(try recognize(image))
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return result
    }

    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Rewrites `source` page by page, keeping the original drawing and adding invisible, selectable text on top.
    static func addTextLayer(to source: URL, lines pages: [[Line]], out: URL) throws {
        guard let doc = CGPDFDocument(source as CFURL) else { throw MerError.failed("Cannot open PDF") }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw MerError.failed("Cannot create PDF") }
        guard let first = doc.page(at: 1) else { throw MerError.failed("Empty PDF") }
        var firstBox = first.getBoxRect(.mediaBox)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { throw MerError.failed("Cannot create PDF") }

        for n in 1...doc.numberOfPages {
            guard let page = doc.page(at: n) else { continue }
            var box = page.getBoxRect(.mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.saveGState()
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            ctx.restoreGState()

            ctx.setTextDrawingMode(.invisible)
            for line in (n - 1 < pages.count ? pages[n - 1] : []) {
                let rect = CGRect(x: line.box.minX * box.width, y: line.box.minY * box.height,
                                  width: line.box.width * box.width, height: line.box.height * box.height)
                let font = CTFontCreateWithName("Helvetica" as CFString, max(rect.height * 0.8, 4), nil)
                let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: natural > 0 ? rect.width / CGFloat(natural) : 1, y: 1)
                ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
                CTLineDraw(ctLine, ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: out)
    }
}
