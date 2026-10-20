#!/usr/bin/env python3
"""Mer regression suite: builds the CLI, generates every fixture from scratch, runs ~100 checks against the
`mer` binary and verifies the real OUTPUT (magic bytes, image pixels, PDF text, XML structure, durations ...).

    ./Scripts/regression.sh [--scratch DIR] [--keep] [-k substr] [--list] [-j N] [--mer PATH]

Python 3 stdlib only.  Swift helpers (PDFKit / AVFoundation / ImageIO probes and generators) are compiled once with
swiftc and cached in <scratch>/helpers.  External engines (ffmpeg, pandoc, qpdf, ...) are optional: their checks
report SKIP when the engine is not installed.
"""
import argparse
import concurrent.futures as cf
import csv as pycsv
import hashlib
import io
import json
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import unicodedata
import tempfile
import threading
import time
import traceback
import zipfile
import zlib
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --------------------------------------------------------------------------------------------------------------
# Swift helper (generators + probes).  One binary, many sub-commands.
# --------------------------------------------------------------------------------------------------------------
HELPER_SWIFT = r'''
import Foundation
import AppKit
import AVFoundation
import PDFKit
import ImageIO
import CoreText
import CoreGraphics
import UniformTypeIdentifiers

setbuf(stdout, nil)
func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }
func emit(_ o: Any) {
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
}
func rgbaContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot decode \(path)") }
    return img
}
func writePNG(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    if !CGImageDestinationFinalize(d) { die("png write failed") }
}
func fourCC(_ v: FourCharCode) -> String {
    let b = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
    return String(bytes: b, encoding: .macOSRoman) ?? "????"
}
func wait(_ f: (@escaping () -> Void) -> Void) {
    let sem = DispatchSemaphore(value: 0)
    f { sem.signal() }
    sem.wait()
}

let a = CommandLine.arguments
guard a.count >= 3 else { die("usage: helper <cmd> <args...>") }

switch a[1] {

// textpng out.png "line one|line two" [fontSize]
case "textpng":
    let lines = a[3].components(separatedBy: "|")
    let size = a.count > 4 ? CGFloat(Double(a[4])!) : 48
    let w = 1100, h = Int(size * 1.9) * lines.count + 90
    let c = rgbaContext(w, h)
    c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    c.setFillColor(CGColor(gray: 0, alpha: 1))
    let font = NSFont(name: "Helvetica", size: size)!
    var y = CGFloat(h) - 45 - size
    for l in lines {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: [.font: font]))
        c.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(line, c)
        y -= size * 1.9
    }
    writePNG(c.makeImage()!, a[2])

// mkmp4 out.(mp4|mov)   60 frames 320x240 H.264 BGRA gradient, 30 fps
case "mkmp4":
    let out = URL(fileURLWithPath: a[2]); try? FileManager.default.removeItem(at: out)
    let w = 320, h = 240, n = 60
    let writer = try AVAssetWriter(outputURL: out, fileType: out.pathExtension == "mov" ? .mov : .mp4)
    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10, AVVideoAverageBitRateKey: 800_000]]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    guard writer.startWriting() else { die("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    for i in 0..<n {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let buf = pb else { die("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h { for x in 0..<w {
            let p = base + y * stride + x * 4
            p[0] = UInt8(x * 255 / w); p[1] = UInt8(y * 255 / h); p[2] = UInt8((i * 4) & 255); p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    wait { done in writer.finishWriting { done() } }
    if writer.status != .completed { die("writer failed: \(String(describing: writer.error))") }

// mux video audio out.mp4
case "mux":
    let v = AVURLAsset(url: URL(fileURLWithPath: a[2])), au = AVURLAsset(url: URL(fileURLWithPath: a[3]))
    let out = URL(fileURLWithPath: a[4]); try? FileManager.default.removeItem(at: out)
    let comp = AVMutableComposition()
    guard let vt = v.tracks(withMediaType: .video).first, let at = au.tracks(withMediaType: .audio).first else { die("tracks missing") }
    let vd = v.duration
    let ad = CMTimeMinimum(au.duration, vd)
    try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
    try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: ad), of: at, at: .zero)
    let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
    ex.outputURL = out; ex.outputFileType = .mp4
    wait { done in ex.exportAsynchronously { done() } }
    if ex.status != .completed { die("mux failed: \(String(describing: ex.error))") }

// mkpdf out.pdf pages prefix   -> text PDF, page i contains "PAGE<i> TOKEN<prefix><i>" plus body lines
case "mkpdf":
    let n = Int(a[3])!, prefix = a.count > 4 ? a[4] : "A"
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let c = CGContext(URL(fileURLWithPath: a[2]) as CFURL, mediaBox: &box, nil) else { die("pdf ctx") }
    let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
    for i in 1...n {
        c.beginPDFPage(nil)
        c.setFillColor(CGColor(gray: 0, alpha: 1))
        for (j, text) in ["PAGE\(i) TOKEN\(prefix)\(i)", "Mer regression fixture page \(i) of \(n)", "The quick brown fox jumps over the lazy dog"].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            c.textPosition = CGPoint(x: 60, y: 700 - CGFloat(j) * 40)
            CTLineDraw(line, c)
        }
        c.endPDFPage()
    }
    c.closePDF()

// imgpdf image out.pdf   -> one page holding the picture (no text layer)
case "imgpdf":
    guard let img = NSImage(contentsOfFile: a[2]), let page = PDFPage(image: img) else { die("imgpdf: cannot load") }
    let doc = PDFDocument(); doc.insert(page, at: 0)
    if !doc.write(to: URL(fileURLWithPath: a[3])) { die("imgpdf: write failed") }

// pdftext file.pdf  -> {"pages":n,"text":[...],"rotation":[...],"locked":bool,"sizes":[[w,h]...]}
case "pdftext":
    guard let doc = PDFDocument(url: URL(fileURLWithPath: a[2])) else { die("cannot open pdf") }
    if doc.isLocked { emit(["pages": 0, "text": [String](), "rotation": [Int](), "locked": true, "sizes": [[Int]]()]); break }
    var texts: [String] = [], rots: [Int] = [], sizes: [[Int]] = []
    for i in 0..<doc.pageCount {
        let p = doc.page(at: i)!
        texts.append(p.string ?? ""); rots.append(p.rotation)
        let b = p.bounds(for: .mediaBox); sizes.append([Int(b.width.rounded()), Int(b.height.rounded())])
    }
    emit(["pages": doc.pageCount, "text": texts, "rotation": rots, "locked": false, "sizes": sizes])

// info file -> images: width/height/frames/sizes/alpha ; media: duration/video/audio tracks
case "info":
    let url = URL(fileURLWithPath: a[2])
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0, CGImageSourceGetType(src) != nil {
        var sizes: [[Int]] = []
        for i in 0..<CGImageSourceGetCount(src) {
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
            sizes.append([(p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0])
        }
        let p0 = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        emit(["kind": "image", "type": CGImageSourceGetType(src) as String? ?? "", "frames": CGImageSourceGetCount(src),
              "width": sizes[0][0], "height": sizes[0][1], "sizes": sizes, "hasAlpha": (p0[kCGImagePropertyHasAlpha] as? Bool) ?? false])
    } else {
        let asset = AVURLAsset(url: url)
        var video: [[String: Any]] = [], audio: [[String: Any]] = []
        for t in asset.tracks(withMediaType: .video) {
            let codec = (t.formatDescriptions as? [CMFormatDescription])?.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
            video.append(["width": Int(t.naturalSize.width.rounded()), "height": Int(t.naturalSize.height.rounded()), "codec": codec, "fps": Double(t.nominalFrameRate)])
        }
        for t in asset.tracks(withMediaType: .audio) {
            let codec = (t.formatDescriptions as? [CMFormatDescription])?.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
            audio.append(["codec": codec])
        }
        emit(["kind": "media", "duration": asset.duration.seconds, "video": video, "audio": audio, "playable": asset.isPlayable])
    }

// px image x y  -> [r,g,b,a] of the decoded first frame (premultiplied sRGB), origin top-left
case "px":
    let img = loadImage(a[2]); let w = img.width, h = img.height
    let c = rgbaContext(w, h)
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let x = Int(a[3])!, y = Int(a[4])!
    guard x < w, y < h else { die("pixel out of range \(w)x\(h)") }
    let d = c.data!.assumingMemoryBound(to: UInt8.self)
    let p = d + y * c.bytesPerRow + x * 4
    emit([Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3])])

// tagjpg in.png out.jpg  -> JPEG carrying EXIF / TIFF / GPS metadata
case "tagjpg":
    let img = loadImage(a[2])
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "MerTestCam", kCGImagePropertyTIFFModel: "RegressionOne"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05", kCGImagePropertyExifUserComment: "secret"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 45.25, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImageDestinationLossyCompressionQuality: 0.95,
    ]
    CGImageDestinationAddImage(d, img, props as CFDictionary)
    if !CGImageDestinationFinalize(d) { die("tagjpg failed") }

// meta image -> {"gps":bool,"make":str,"exif":bool}
case "meta":
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { die("cannot read image") }
    let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    emit(["gps": p[kCGImagePropertyGPSDictionary] != nil, "make": (tiff[kCGImagePropertyTIFFMake] as? String) ?? "",
          "exifDate": (exif[kCGImagePropertyExifDateTimeOriginal] as? String) ?? "",
          "exifComment": (exif[kCGImagePropertyExifUserComment] as? String) ?? ""])

default: die("unknown helper command \(a[1])")
}
'''

# --------------------------------------------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------------------------------------------


class Fail(AssertionError):
    pass


class Skip(Exception):
    pass


def expect(cond, msg):
    if not cond:
        raise Fail(msg)


def sh(cmd, cwd=None, timeout=600, env=None):
    p = subprocess.run([str(c) for c in cmd], cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    return p.returncode, p.stdout, p.stderr


def shorten(s, n=300):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def png_bytes(w, h, pixel, alpha=True):
    """pixel(x, y) -> (r, g, b, a) when alpha else (r, g, b)"""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(bytes(pixel(x, y)))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


def noise_png_bytes(w, h, seed):
    rnd = random.Random(seed)
    raw = bytearray()
    for _ in range(h):
        raw.append(0)
        raw.extend(rnd.randbytes(w * 3))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 1)) + chunk(b"IEND", b""))


RED, BLUE = (230, 30, 30), (30, 30, 230)


def photo_pixel(w, h, hole=12):
    def f(x, y):
        if x >= w - hole and y >= h - hole:
            return (0, 0, 0, 0)          # transparent hole, bottom-right
        return (*(RED if x < w // 2 else BLUE), 255)
    return f


# --------------------------------------------------------------------------------------------------------------
# Fixtures (generated on demand, each once, no network, no pre-existing files)
# --------------------------------------------------------------------------------------------------------------
FIXTURES = {}


def fixture(name):
    def deco(fn):
        FIXTURES[name] = fn
        return fn
    return deco


NOTES_MD = """# Mer Test Document

A paragraph with **bold words**, *italic words* and a [Mer link](https://example.com/mer).

## Shopping List

- Apples
- Bananas
- Cherries

### Steps

1. First step
2. Second step
3. Third step

```
code line one
```

Final paragraph ends here.
"""

SRT = """1
00:00:01,000 --> 00:00:02,500
Hello, world!

2
00:00:03,000 --> 00:00:04,250
Second line
with two rows

3
01:02:03,456 --> 01:02:05,000
Café — naïve
"""

VTT = """WEBVTT

00:01.000 --> 00:02.500 align:start position:0%
Short timestamps

cue-two
00:00:03.000 --> 00:00:04.250
<b>Bold</b> text here
"""

CSV_TEXT = 'name,qty,price,note\nWidget,3,4.5,"has, comma"\nGadget,10,0.25,"say ""hi"""\nCafé,0,7,plain\n'

SVG = ('<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">'
       '<rect width="60" height="80" fill="#e61e1e"/><rect x="60" width="60" height="80" fill="#1e1ee6"/></svg>')

HTML_DOC = ('<html><head><meta charset="utf-8"><title>Page</title></head><body><h1>Big Title</h1>'
            '<p>Hello <a href="https://example.com/h">linked words</a> and more.</p>'
            '<ul><li>one</li><li>two</li></ul></body></html>')

OCR_LINES = "Invoice Number 2048|The quick brown fox|jumps over the lazy dog"
SPEECH_TEXT = ("This is a regression test of the Mer converter. One, two, three, four, five, six, seven, eight, "
               "nine, ten. The quick brown fox jumps over the lazy dog.")


def W(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


@fixture("photo.png")
def _(S, p): W(p, png_bytes(96, 64, photo_pixel(96, 64)))


@fixture("square.png")
def _(S, p): W(p, png_bytes(128, 128, photo_pixel(128, 128, 16)))


@fixture("noise.png")
def _(S, p): W(p, noise_png_bytes(640, 480, 1))


@fixture("noise_big.png")
def _(S, p): W(p, noise_png_bytes(1200, 900, 2))


@fixture("blank.png")
def _(S, p): W(p, png_bytes(300, 200, lambda x, y: (255, 255, 255, 255), alpha=False))


@fixture("noise.jpg")
def _(S, p):
    rc, o, e = sh(["/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "100", S.fixture("noise.png"), "--out", p])
    expect(rc == 0, "sips failed: " + e)


@fixture("tagged.jpg")
def _(S, p): S.helper("tagjpg", S.fixture("photo.png"), p)


@fixture("icon.svg")
def _(S, p): W(p, SVG)


@fixture("ocr.png")
def _(S, p): S.helper("textpng", p, OCR_LINES)


@fixture("scan.pdf")
def _(S, p): S.helper("imgpdf", S.fixture("ocr.png"), p)


@fixture("text3.pdf")
def _(S, p): S.helper("mkpdf", p, "3", "A")


@fixture("text2.pdf")
def _(S, p): S.helper("mkpdf", p, "2", "B")


@fixture("text1.pdf")
def _(S, p): S.helper("mkpdf", p, "1", "C")


@fixture("big.pdf")
def _(S, p): S.helper("imgpdf", S.fixture("noise_big.png"), p)


@fixture("speech.aiff")
def _(S, p):
    rc, o, e = sh(["/usr/bin/say", "-o", p, SPEECH_TEXT])
    if rc != 0 or not Path(p).exists() or Path(p).stat().st_size < 1000:
        # no speech voice available: a 5 s two-tone sine as big-endian 16-bit AIFF
        sr, n = 22050, 22050 * 5
        pcm = b"".join(struct.pack(">h", int(9000 * __import__("math").sin(2 * 3.14159265 * (440 if i < n // 2 else 660) * i / sr))) for i in range(n))
        ext80 = b"\x40\x0d" + (sr << 48).to_bytes(8, "big")[:8]          # 80-bit extended for 22050
        comm = b"COMM" + struct.pack(">IhIh", 18, 1, n, 16) + ext80
        ssnd = b"SSND" + struct.pack(">III", 8 + len(pcm), 0, 0) + pcm
        body = b"AIFF" + comm + ssnd
        W(p, b"FORM" + struct.pack(">I", len(body)) + body)


@fixture("speech2.aiff")
def _(S, p):
    rc, o, e = sh(["/usr/bin/say", "-o", p, "A second clip. Alpha bravo charlie delta echo foxtrot."])
    if rc != 0:
        shutil.copy(S.fixture("speech.aiff"), p)


def _afconvert(S, p, *args):
    rc, o, e = sh(["/usr/bin/afconvert", *args, S.fixture("speech.aiff"), p])
    expect(rc == 0, "afconvert failed: " + e)


@fixture("speech.wav")
def _(S, p): _afconvert(S, p, "-f", "WAVE", "-d", "LEI16")


@fixture("speech.m4a")
def _(S, p): _afconvert(S, p, "-f", "m4af", "-d", "aac")


@fixture("speech.flac")
def _(S, p): _afconvert(S, p, "-f", "flac", "-d", "flac")


@fixture("video.mp4")
def _(S, p): S.helper("mkmp4", p)


@fixture("video2.mp4")
def _(S, p): shutil.copy(S.fixture("video.mp4"), p)


@fixture("video.mov")
def _(S, p): S.helper("mkmp4", p)


@fixture("video_av.mp4")
def _(S, p): S.helper("mux", S.fixture("video.mp4"), S.fixture("speech.aiff"), p)


@fixture("notes.md")
def _(S, p): W(p, NOTES_MD)


@fixture("notes.docx")
def _(S, p): W(p, make_docx())


@fixture("page.html")
def _(S, p): W(p, HTML_DOC)


@fixture("long.txt")
def _(S, p): W(p, "".join(f"Line {i} of the long text file, with enough words to be a realistic line.\n" for i in range(1, 181)))


@fixture("data.csv")
def _(S, p): W(p, CSV_TEXT)


@fixture("data.tsv")
def _(S, p): W(p, "a\tb\tc\n1\ttwo words\t3\n4\t5\t6\n")


@fixture("data.xlsx")
def _(S, p): W(p, make_xlsx(XLSX_ROWS))


@fixture("data.json")
def _(S, p): W(p, json.dumps([{"id": 1, "name": "Ann", "tags": "x"}, {"id": 2, "name": "Bob", "extra": True}], indent=1))


@fixture("object.json")
def _(S, p): W(p, '{"not": "an array"}')


@fixture("subs.srt")
def _(S, p): W(p, SRT)


@fixture("subs.vtt")
def _(S, p): W(p, VTT)


@fixture("project")
def _(S, p):
    W(Path(p) / "a.txt", "alpha file\n")
    W(Path(p) / "sub" / "b.txt", "bravo file\n")
    W(Path(p) / "sub" / "deep" / "c.bin", random.Random(5).randbytes(5000))
    W(Path(p) / "é ünï.txt", "unicode name\n")


@fixture("project.zip")
def _(S, p):
    with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("project/a.txt", "alpha file\n")
        z.writestr("project/sub/b.txt", "bravo file\n")


@fixture("project.tar.gz")
def _(S, p):
    src = S.fixture("project")
    with tarfile.open(p, "w:gz") as t:
        t.add(src, arcname="project")


@fixture("corrupt.zip")
def _(S, p): W(p, b"PK\x03\x04" + random.Random(9).randbytes(300))


@fixture("unknown.xyz")
def _(S, p): W(p, "nothing converts this\n")


@fixture("shapes.psd")
def _(S, p):
    magick = shutil.which("magick") or shutil.which("convert")
    if not magick:
        raise Skip("ImageMagick not installed")
    rc, o, e = sh([magick, "-size", "40x30", "xc:red", p])
    expect(rc == 0, "magick could not make a PSD: " + e)


XLSX_ROWS = [["id", "name", "score"], ["1", "Ann", "9.5"], ["2", "Bob", "7"], ["3", "Zoë", "10"]]


def _col(i):
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


def make_xlsx(rows):
    """Hand-written XLSX (shared strings + numeric cells), the way Excel writes it."""
    shared, sheet_rows = [], []
    for r, row in enumerate(rows, 1):
        cells = []
        for c, v in enumerate(row):
            ref = f"{_col(c)}{r}"
            if re.fullmatch(r"-?\d+(\.\d+)?", v):
                cells.append(f'<c r="{ref}"><v>{v}</v></c>')
            else:
                if v not in shared:
                    shared.append(v)
                cells.append(f'<c r="{ref}" t="s"><v>{shared.index(v)}</v></c>')
        sheet_rows.append(f'<row r="{r}">{"".join(cells)}</row>')
    head = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", head + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>')
        z.writestr("_rels/.rels", head + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr("xl/workbook.xml", head + f'<workbook {ns} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>')
        z.writestr("xl/_rels/workbook.xml.rels", head + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>')
        z.writestr("xl/worksheets/sheet1.xml", head + f'<worksheet {ns}><sheetData>{"".join(sheet_rows)}</sheetData></worksheet>')
        si = "".join(f"<si><t>{v}</t></si>" for v in shared)
        z.writestr("xl/sharedStrings.xml", head + f'<sst {ns} count="{len(shared)}" uniqueCount="{len(shared)}">{si}</sst>')
    return buf.getvalue()


def make_docx():
    """A realistic .docx: heading styles, bold/italic runs, a hyperlink, and numbering.xml bullet / decimal lists."""
    W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    head = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'

    def p(text, style=None, num=None, runs=None):
        ppr = ""
        if style:
            ppr += f'<w:pStyle w:val="{style}"/>'
        if num:
            ppr += f'<w:numPr><w:ilvl w:val="0"/><w:numId w:val="{num}"/></w:numPr>'
        body = runs if runs is not None else f"<w:r><w:t>{text}</w:t></w:r>"
        return f'<w:p>{"<w:pPr>" + ppr + "</w:pPr>" if ppr else ""}{body}</w:p>'

    body = "".join([
        p("Quarterly Report", "Heading1"),
        p("", runs='<w:r><w:t xml:space="preserve">Plain text, </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold part</w:t></w:r>'
                   '<w:r><w:t xml:space="preserve"> and a </w:t></w:r><w:hyperlink r:id="rId9"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr><w:t>Mer site</w:t></w:r></w:hyperlink><w:r><w:t>.</w:t></w:r>'),
        p("Highlights", "Heading2"),
        p("First bullet", num=1), p("Second bullet", num=1),
        p("Ordered steps", "Heading2"),
        p("Step one", num=2), p("Step two", num=2),
        p("The end."),
    ])
    doc = head + f'<w:document xmlns:w="{W_NS}" xmlns:r="{R_NS}"><w:body>{body}<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body></w:document>'
    styles = head + (f'<w:styles xmlns:w="{W_NS}"><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>'
                     '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
                     '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>'
                     '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
                     '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style></w:styles>')
    numbering = head + (f'<w:numbering xmlns:w="{W_NS}">'
                        '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#8226;"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>'
                        '<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>'
                        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>')
    rels = head + ('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
                   '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
                   '<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/mer" TargetMode="External"/></Relationships>')
    ct = head + ('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
                 '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
                 '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
                 '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>')
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", head + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr("word/document.xml", doc)
        z.writestr("word/styles.xml", styles)
        z.writestr("word/numbering.xml", numbering)
        z.writestr("word/_rels/document.xml.rels", rels)
    return buf.getvalue()


# --------------------------------------------------------------------------------------------------------------
# Suite plumbing
# --------------------------------------------------------------------------------------------------------------
class R:
    def __init__(self, rc, out, err, secs, cmd):
        self.rc, self.out, self.err, self.secs, self.cmd = rc, out, err, secs, cmd
        self.outs = [Path(l) for l in out.splitlines() if l.startswith("/")]

    def __str__(self):
        return f"`{' '.join(self.cmd)}` rc={self.rc} stdout={shorten(self.out, 160)!r} stderr={shorten(self.err, 200)!r}"


class Suite:
    def __init__(self, base, mer, jobs):
        self.base = Path(base)
        self.helpers = self.base / "helpers"
        self.run_dir = self.base / f"run-{os.getpid()}"
        self.fx_dir = self.run_dir / "fixtures"
        self.fx_dir.mkdir(parents=True, exist_ok=True)
        self.mer_bin = str(mer)
        self.jobs = jobs
        self._locks = {}
        self._glock = threading.Lock()
        self._helper_bin = None
        self._engines = None
        self._info_cache = {}

    # -- fixtures --------------------------------------------------------------------------------------------
    def _lock(self, key):
        with self._glock:
            return self._locks.setdefault(key, threading.RLock())

    def fixture(self, name):
        path = self.fx_dir / name
        with self._lock("fx:" + name):
            if not path.exists():
                try:
                    FIXTURES[name](self, str(path))
                except (Skip, Fail):
                    path.unlink(missing_ok=True)
                    raise
                except Exception as e:
                    path.unlink(missing_ok=True)
                    raise Fail(f"cannot generate fixture {name}: {e}")
                expect(path.exists(), f"fixture {name} was not created")
        return path

    # -- swift helper ------------------------------------------------------------------------------------------
    def helper_bin(self):
        with self._lock("helper-build"):
            if self._helper_bin:
                return self._helper_bin
            digest = hashlib.sha1(HELPER_SWIFT.encode()).hexdigest()[:12]
            d = self.helpers / digest
            binary = d / "merhelper"
            if not binary.exists():
                d.mkdir(parents=True, exist_ok=True)
                (d / "main.swift").write_text(HELPER_SWIFT)
                rc, o, e = sh(["swiftc", "-O", "-suppress-warnings", "-o", binary, d / "main.swift"], cwd=d, timeout=900)
                if rc != 0:
                    raise Fail("swiftc could not compile the test helper:\n" + e[-1500:])
            self._helper_bin = binary
            return binary

    def helper(self, *args, json_out=False):
        rc, o, e = sh([self.helper_bin(), *args], timeout=300)
        if rc != 0:
            raise Fail(f"helper {args[0]} failed: {shorten(e)}")
        return json.loads(o) if json_out else o

    def info(self, path):
        key = str(path)
        if key not in self._info_cache:
            self._info_cache[key] = self.helper("info", path, json_out=True)
        return self._info_cache[key]

    # -- engines ---------------------------------------------------------------------------------------------
    def engines(self):
        with self._lock("engines"):
            if self._engines is None:
                r = self.run_mer(["engines"])
                found = {}
                for line in r.out.splitlines():
                    m = re.match(r"^(\S+)\s+(✓|✗)", line)
                    if m:
                        found[m.group(1).lower()] = m.group(2) == "✓"
                self._engines = found
        return self._engines

    def run_mer(self, args, cwd=None, timeout=300):
        t0 = time.time()
        try:
            p = subprocess.run([self.mer_bin, *map(str, args)], cwd=cwd, capture_output=True, text=True, timeout=timeout)
            return R(p.returncode, p.stdout, p.stderr, time.time() - t0, ["mer", *map(lambda a: Path(a).name if str(a).startswith("/") else str(a), args)])
        except subprocess.TimeoutExpired:
            return R(124, "", f"TIMEOUT after {timeout}s", time.time() - t0, ["mer", *map(str, args)])


class T:
    """Per-check context: its own work dir, fixture copies, and CLI helpers."""

    def __init__(self, suite, name, idx):
        self.S = suite
        self.name = name
        self.dir = suite.run_dir / "work" / f"{idx:03d}-{re.sub(r'[^A-Za-z0-9._-]+', '_', name)}"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.actions = {}

    def fx(self, name, as_name=None):
        src = self.S.fixture(name)
        dst = self.dir / (as_name or name)
        if src.is_dir():
            shutil.copytree(src, dst)
        else:
            shutil.copy(src, dst)
        return dst

    def mer(self, *args, timeout=300):
        return self.S.run_mer(args, cwd=self.dir, timeout=timeout)

    def ok(self, *args, timeout=300):
        r = self.mer(*args, timeout=timeout)
        expect(r.rc == 0, f"expected success: {r}")
        expect(r.outs, f"no output path printed: {r}")
        for o in r.outs:
            expect(o.exists(), f"reported output does not exist: {o}")
            if o.is_file():
                expect(o.stat().st_size > 0, f"output is empty: {o.name}")
            expect(self.dir in o.parents or o.parent == self.dir, f"output not next to the input / in work dir: {o}")
        return r.outs

    def fails(self, *args, has=(), timeout=300):
        r = self.mer(*args, timeout=timeout)
        expect(r.rc == 1, f"expected a clean failure (exit 1): {r}")
        low = r.err.lower()
        expect(low.strip(), f"failed without any message: {r}")
        for bad in ("fatal error", "traceback", "swift runtime", "segmentation", "uncaught exception", "nsinvalid"):
            expect(bad not in low, f"crash-like message: {r}")
        if has:
            expect(any(h.lower() in low for h in has), f"message should mention one of {list(has)}: {r}")
        return r

    def actions_for(self, path):
        if str(path) not in self.actions:
            r = self.mer("list", path, "--json")
            expect(r.rc == 0, f"mer list failed: {r}")
            self.actions[str(path)] = json.loads(r.out)
        return self.actions[str(path)]

    def need_action(self, path, id_suffix):
        if not any(a["id"].endswith(id_suffix) for a in self.actions_for(path)):
            raise Skip(f"action *{id_suffix} not offered for {Path(path).name} (engine/format unavailable here)")

    def need_engine(self, name):
        if not self.S.engines().get(name.lower(), False):
            raise Skip(f"SKIPPED (engine not installed): {name}")

    # probes
    def px(self, path, x, y):
        return self.S.helper("px", path, str(x), str(y), json_out=True)

    def info(self, path):
        return self.S.helper("info", path, json_out=True)

    def pdf(self, path):
        return self.S.helper("pdftext", path, json_out=True)


CHECKS = []   # (name, fn, xfail)


def check(name, xfail=None):
    def deco(fn):
        CHECKS.append((name, fn, xfail))
        return fn
    return deco


# --------------------------------------------------------------------------------------------------------------
# Verifiers
# --------------------------------------------------------------------------------------------------------------
def head_bytes(path, n=64):
    with open(path, "rb") as f:
        return f.read(n)


def v_magic(prefix, off=0):
    def v(t, outs):
        b = head_bytes(outs[0], off + len(prefix))
        expect(b[off:off + len(prefix)] == prefix, f"{outs[0].name}: expected magic {prefix!r} at {off}, got {b[off:off + len(prefix)]!r}")
    return v


def v_ftyp(*brands):
    def v(t, outs):
        b = head_bytes(outs[0], 64)
        expect(b[4:8] == b"ftyp", f"no ftyp box: {b[:12]!r}")
        ok = any(br.encode() in b[8:64] for br in brands)
        expect(ok, f"ftyp brand not in {brands}: {b[8:40]!r}")
    return v


def v_img(w=None, h=None, minw=None, maxw=None):
    def v(t, outs):
        i = t.info(outs[0])
        expect(i["kind"] == "image", f"{outs[0].name} is not a decodable image")
        if w is not None:
            expect(i["width"] == w, f"width {i['width']} != {w}")
        if h is not None:
            expect(i["height"] == h, f"height {i['height']} != {h}")
        if minw is not None:
            expect(i["width"] >= minw, f"width {i['width']} < {minw}")
        if maxw is not None:
            expect(i["width"] <= maxw, f"width {i['width']} > {maxw}")
    return v


def v_px(x, y, rgb, tol=45, i=0):
    def v(t, outs):
        got = t.px(outs[i], x, y)
        expect(all(abs(g - e) <= tol for g, e in zip(got[:3], rgb)) and got[3] > 200,
               f"pixel({x},{y})={got}, expected ~{rgb} opaque")
    return v


def v_alpha(x, y, lo, hi):
    def v(t, outs):
        got = t.px(outs[0], x, y)
        expect(lo <= got[3] <= hi, f"alpha at ({x},{y}) = {got[3]}, expected {lo}..{hi}")
    return v


def v_pdf(pages=None, has=(), hasnt=(), minpages=None):
    def v(t, outs):
        d = t.pdf(outs[0])
        expect(not d["locked"], "PDF is locked")
        if pages is not None:
            expect(d["pages"] == pages, f"pages {d['pages']} != {pages}")
        if minpages is not None:
            expect(d["pages"] >= minpages, f"pages {d['pages']} < {minpages}")
        text = "\n".join(d["text"])
        norm = " ".join(text.lower().split())
        for h in has:
            expect(h.lower() in norm, f"PDF text lacks {h!r}; text starts: {shorten(text, 150)!r}")
        for h in hasnt:
            expect(h.lower() not in norm, f"PDF text unexpectedly contains {h!r}")
    return v


def v_media(dur=None, tol=0.4, video=None, audio=None, size=None, vcodec=None, acodec=None):
    def v(t, outs):
        i = t.info(outs[0])
        expect(i["kind"] == "media" and i["playable"], f"{outs[0].name} is not a playable media file")
        if dur is not None:
            d = dur(t) if callable(dur) else dur
            expect(abs(i["duration"] - d) <= tol, f"duration {i['duration']:.2f}s, expected {d:.2f}s ± {tol}")
        if video is not None:
            expect(len(i["video"]) == video, f"{len(i['video'])} video tracks, expected {video}")
        if audio is not None:
            expect(len(i["audio"]) == audio, f"{len(i['audio'])} audio tracks, expected {audio}")
        if size:
            expect((i["video"][0]["width"], i["video"][0]["height"]) == size, f"video size {i['video'][0]['width']}x{i['video'][0]['height']} != {size}")
        if vcodec:
            expect(i["video"][0]["codec"].lower() in [c.lower() for c in ([vcodec] if isinstance(vcodec, str) else vcodec)], f"video codec {i['video'][0]['codec']}")
        if acodec:
            expect(i["audio"][0]["codec"].lower() in [c.lower() for c in ([acodec] if isinstance(acodec, str) else acodec)], f"audio codec {i['audio'][0]['codec']}")
    return v


def v_ffprobe(dur=None, tol=0.4, video=None, audio=None):
    """For containers AVFoundation cannot open (mkv, webm ...): needs ffprobe next to ffmpeg."""
    def v(t, outs):
        probe = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
        if not Path(probe).exists():
            raise Skip("ffprobe not available")
        rc, o, e = sh([probe, "-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", outs[0]])
        expect(rc == 0, f"ffprobe cannot read {outs[0].name}: {shorten(e)}")
        j = json.loads(o)
        kinds = [s["codec_type"] for s in j.get("streams", [])]
        if dur is not None:
            expect(abs(float(j["format"]["duration"]) - dur) <= tol, f"duration {j['format']['duration']}, expected {dur}")
        if video is not None:
            expect(kinds.count("video") == video, f"streams {kinds}")
        if audio is not None:
            expect(kinds.count("audio") == audio, f"streams {kinds}")
    return v


def speech_dur(t):
    return t.S.info(t.S.fixture("speech.aiff"))["duration"]


def v_text(*needles, exact_missing=()):
    def v(t, outs):
        s = outs[0].read_text(encoding="utf-8", errors="replace")
        for n in needles:
            expect(n in s, f"{outs[0].name} lacks {n!r}; starts: {shorten(s, 160)!r}")
        for n in exact_missing:
            expect(n not in s, f"{outs[0].name} unexpectedly contains {n!r}")
    return v


def zip_of(path):
    expect(zipfile.is_zipfile(path), f"{Path(path).name} is not a zip container")
    z = zipfile.ZipFile(path)
    bad = z.testzip()
    expect(bad is None, f"corrupt zip member {bad}")
    return z


def zip_names(z):
    """Member names as a reader would see them: UTF-8 flag honoured, otherwise raw bytes tried as UTF-8; NFC-normalised."""
    out = []
    for i in z.infolist():
        n = i.filename
        if not i.flag_bits & 0x800:
            try:
                n = n.encode("cp437").decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                pass
        out.append(unicodedata.normalize("NFC", n))
    return out


def xml_of(z, name):
    expect(name in z.namelist(), f"missing part {name}; have {z.namelist()[:12]}")
    try:
        return ET.fromstring(z.read(name))
    except ET.ParseError as e:
        raise Fail(f"{name} is not well-formed XML: {e}")


def local(tag):
    return tag.rsplit("}", 1)[-1]


def itertext_of(el):
    return "".join(el.itertext())


def para_texts(root):
    """Paragraph (text, style, has-bold, has-italic) from a WordprocessingML document."""
    W_ = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    out = []
    for p in root.iter(W_ + "p"):
        style = None
        sty = p.find(f"{W_}pPr/{W_}pStyle")
        if sty is not None:
            style = sty.get(W_ + "val")
        out.append(("".join(t.text or "" for t in p.iter(W_ + "t")), style, p))
    return out


# --------------------------------------------------------------------------------------------------------------
# XLSX reader for verification (independent from the product's)
# --------------------------------------------------------------------------------------------------------------
def read_xlsx(path):
    z = zip_of(path)
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        sst = xml_of(z, "xl/sharedStrings.xml")
        for si in sst:
            if local(si.tag) == "si":
                shared.append("".join(t.text or "" for t in si.iter() if local(t.tag) == "t"))
    names = sorted(n for n in z.namelist() if n.startswith("xl/worksheets/sheet") and n.endswith(".xml"))
    expect(names, "no worksheet part in xlsx")
    sheet = xml_of(z, names[0])
    rows = []
    for row in sheet.iter():
        if local(row.tag) != "row":
            continue
        cells = {}
        for c in row:
            if local(c.tag) != "c":
                continue
            ref = c.get("r", "")
            col = 0
            for ch in re.match(r"[A-Z]+", ref).group(0):
                col = col * 26 + ord(ch) - 64
            typ = c.get("t", "")
            v = next((x for x in c if local(x.tag) == "v"), None)
            if typ == "s":
                val = shared[int(v.text)]
            elif typ == "inlineStr":
                val = "".join(t.text or "" for t in c.iter() if local(t.tag) == "t")
            else:
                val = v.text if v is not None and v.text is not None else ""
            cells[col - 1] = val
        n = (max(cells) + 1) if cells else 0
        rows.append([cells.get(i, "") for i in range(n)])
    return rows


def same_table(got, want):
    def norm(v):
        try:
            f = float(v)
            return repr(int(f)) if f == int(f) else repr(f)
        except ValueError:
            return v
    g = [[norm(c) for c in r] for r in got]
    w = [[norm(c) for c in r] for r in want]
    expect(g == w, f"table differs:\n   got  {g}\n   want {w}")


# --------------------------------------------------------------------------------------------------------------
# CHECKS — table-driven conversions first
# --------------------------------------------------------------------------------------------------------------
def conv(name, fx, to, *verifs, args=(), xfail=None, needs=None):
    """convert <fx> --to <to> [args]  then run every verifier on the outputs."""
    def run(t):
        if needs:
            t.need_engine(needs)
        f = t.fx(fx)
        if to in ("avif", "webp", "jp2", "heic", "bmp", "tiff", "gif", "jpg", "png", "ico", "icns", "pdf") and fx.endswith((".png", ".jpg")):
            t.need_action(f, "." + to)
        outs = t.ok("convert", f, "--to", to, *args)
        for v in verifs:
            v(t, outs)
    CHECKS.append((name, run, xfail))


def tool(name, fx, action_id, *verifs, params=(), extra_fx=(), xfail=None, needs=None, extra_args=()):
    """run <action-id> <fx> [extra fixtures] [--param k=v] then run every verifier."""
    def run(t):
        if needs:
            t.need_engine(needs)
        files = [t.fx(fx)] + [t.fx(x, as_name=f"{i + 2}-{x}") for i, x in enumerate(extra_fx)]
        pa = []
        for p in params:
            pa += ["--param", p]
        outs = t.ok("run", action_id, *files, *pa, *extra_args)
        for v in verifs:
            v(t, outs)
    CHECKS.append((name, run, xfail))


# ---- images ----------------------------------------------------------------------------------------------------
conv("image.png>jpg", "photo.png", "jpg", v_magic(b"\xff\xd8\xff"), v_img(96, 64), v_px(10, 10, RED), v_px(70, 10, BLUE),
     v_px(90, 58, (255, 255, 255), tol=40))
conv("image.png>heic", "photo.png", "heic", v_ftyp("heic", "heix", "mif1", "msf1"), v_img(96, 64))
conv("image.png>pdf", "photo.png", "pdf", v_magic(b"%PDF-"), v_pdf(pages=1))
conv("image.png>ico", "square.png", "ico", v_magic(b"\x00\x00\x01\x00"), v_img(minw=16, maxw=256), v_px(2, 2, RED, tol=60, i=0))
conv("image.png>icns", "square.png", "icns", v_magic(b"icns"), v_img(minw=16))
conv("image.png>tiff", "photo.png", "tiff", lambda t, o: expect(head_bytes(o[0], 4) in (b"II*\x00", b"MM\x00*"), "not a TIFF"), v_img(96, 64), v_alpha(90, 58, 0, 5))
conv("image.png>bmp", "photo.png", "bmp", v_magic(b"BM"), v_img(96, 64), v_px(10, 10, RED))
conv("image.png>gif", "photo.png", "gif", v_magic(b"GIF8"), v_img(96, 64))
conv("image.png>webp", "photo.png", "webp", v_magic(b"RIFF"), v_magic(b"WEBP", 8), v_img(96, 64))
conv("image.png>jp2", "photo.png", "jp2", v_img(96, 64))
conv("image.png>avif", "photo.png", "avif", v_ftyp("avif"), v_img(96, 64))
conv("image.jpg>png", "tagged.jpg", "png", v_magic(b"\x89PNG\r\n\x1a\n"), v_img(96, 64), v_px(10, 10, RED), v_px(70, 10, BLUE))
conv("image.svg>png", "icon.svg", "png", v_magic(b"\x89PNG"), v_img(minw=100), v_px(5, 5, RED),
     lambda t, o: expect(abs(t.info(o[0])["width"] / t.info(o[0])["height"] - 1.5) < 0.02, "SVG aspect ratio 3:2 not preserved"))


@check("image.png>jpg collision gets ' 2' suffix")
def _(t):
    f = t.fx("photo.png")
    a = t.ok("convert", f, "--to", "jpg")[0]
    b = t.ok("convert", f, "--to", "jpg")[0]
    expect(a.name == "photo.jpg" and b.name == "photo 2.jpg", f"names: {a.name}, {b.name}")


@check("image.convert --out <existing dir>")
def _(t):
    f = t.fx("photo.png")
    out = t.dir / "elsewhere"
    out.mkdir()
    r = t.mer("convert", f, "--to", "jpg", "--out", out)
    expect(r.rc == 0 and r.outs and r.outs[0].parent == out and r.outs[0].exists(), f"output not in --out dir: {r}")
    expect(not (t.dir / "photo.jpg").exists(), "stray copy next to the input")


@check("image.convert --out <missing dir> creates it (or says so clearly)")
def _(t):
    f = t.fx("photo.png")
    out = t.dir / "not-yet"
    r = t.mer("convert", f, "--to", "jpg", "--out", out)
    if r.rc == 0:
        expect(r.outs and r.outs[0].parent == out and r.outs[0].exists(), f"{r}")
    else:
        expect(any(w in r.err.lower() for w in ("folder", "directory", "exist")), f"misleading error for a missing --out folder: {r}")


tool("image.resize 50%", "photo.png", "tool.image.resize50", v_img(48, 32), v_px(5, 5, RED), v_px(40, 5, BLUE))
tool("image.resize longest=48", "photo.png", "tool.image.resize", v_img(48, 32), params=("size=48",))
tool("image.rotate 90 right", "photo.png", "tool.image.rotate-cw", v_img(64, 96), v_px(10, 10, RED), v_px(30, 85, BLUE),
     v_alpha(5, 90, 0, 5))
tool("image.rotate 90 left", "photo.png", "tool.image.rotate-ccw", v_img(64, 96), v_px(30, 85, RED), v_px(10, 10, BLUE))
tool("image.rotate 180", "photo.png", "tool.image.rotate-180", v_img(96, 64), v_px(90, 58, RED), v_alpha(5, 5, 0, 5))
tool("image.flip horizontal", "photo.png", "tool.image.flip-h", v_img(96, 64), v_px(5, 5, BLUE), v_px(90, 5, RED), v_alpha(5, 58, 0, 5))
tool("image.flip vertical", "photo.png", "tool.image.flip-v", v_img(96, 64), v_px(5, 5, RED), v_alpha(90, 5, 0, 5))
tool("image.crop square", "photo.png", "tool.image.crop-square", v_img(64, 64), v_px(2, 2, RED), v_px(61, 2, BLUE))
tool("image.crop 16:9", "photo.png", "tool.image.crop-16x9", v_img(96, 54))


@check("image.remove metadata (EXIF/GPS gone, pixels kept)")
def _(t):
    f = t.fx("tagged.jpg")
    before = t.S.helper("meta", f, json_out=True)
    expect(before["gps"] and before["make"] == "MerTestCam", f"fixture lacks metadata: {before}")
    out = t.ok("run", "tool.image.strip", f)[0]
    after = t.S.helper("meta", out, json_out=True)
    expect(not after["gps"], f"GPS survived: {after}")
    expect(after["make"] == "" and after["exifComment"] == "" and after["exifDate"] == "", f"EXIF/TIFF survived: {after}")
    v_img(96, 64)(t, [out])
    v_px(10, 10, RED)(t, [out])


@check("image.compress jpg (smaller, same size)")
def _(t):
    f = t.fx("noise.jpg")
    out = t.ok("run", "tool.image.compress", f, "--param", "quality=30")[0]
    expect(out.stat().st_size < f.stat().st_size * 0.8, f"not smaller: {f.stat().st_size} -> {out.stat().st_size}")
    v_img(640, 480)(t, [out])
    v_magic(b"\xff\xd8")(t, [out])


@check("image.combine 2 images into one PDF")
def _(t):
    a, b = t.fx("photo.png"), t.fx("square.png")
    out = t.ok("run", "tool.image.combine-pdf", a, b)[0]
    v_magic(b"%PDF")(t, [out])
    v_pdf(pages=2)(t, [out])


@check("image.OCR image -> txt")
def _(t):
    out = t.ok("run", "convert.image.ocr-txt", t.fx("ocr.png"))[0]
    s = " ".join(out.read_text(encoding="utf-8").lower().split())
    for w in ("invoice", "2048", "quick brown fox", "lazy dog"):
        expect(w in s, f"OCR text lacks {w!r}: {shorten(s)!r}")


@check("image.Searchable PDF (OCR) from image")
def _(t):
    out = t.ok("run", "tool.image.ocr-pdf", t.fx("ocr.png"))[0]
    v_pdf(pages=1, has=("quick brown fox", "invoice"))(t, [out])


# ---- audio -----------------------------------------------------------------------------------------------------
conv("audio.aiff>m4a", "speech.aiff", "m4a", v_ftyp("M4A "), v_media(speech_dur, 0.35, audio=1, video=0, acodec="aac "))
conv("audio.aiff>flac", "speech.aiff", "flac", v_magic(b"fLaC"), v_media(speech_dur, 0.2, audio=1))
conv("audio.aiff>wav", "speech.aiff", "wav", v_magic(b"RIFF"), v_magic(b"WAVE", 8), v_media(speech_dur, 0.1))
conv("audio.wav>aiff", "speech.wav", "aiff", v_magic(b"FORM"), v_magic(b"AIFF", 8), v_media(speech_dur, 0.1))
conv("audio.m4a>wav", "speech.m4a", "wav", v_magic(b"RIFF"), v_media(speech_dur, 0.4))
conv("audio.flac>m4a", "speech.flac", "m4a", v_ftyp("M4A "), v_media(speech_dur, 0.4))
tool("audio.trim 0.5s..1.5s", "speech.aiff", "tool.audio.trim", v_ftyp("M4A "), v_media(1.0, 0.2, audio=1), params=("start=0.5", "end=1.5"))
tool("audio.trim from 1s to end", "speech.aiff", "tool.audio.trim", v_media(lambda t: speech_dur(t) - 1.0, 0.25), params=("start=1", "end=0"))
tool("audio.merge two tracks", "speech.aiff", "tool.audio.merge", v_ftyp("M4A "),
     v_media(lambda t: speech_dur(t) + t.S.info(t.S.fixture("speech2.aiff"))["duration"], 0.5, audio=1), extra_fx=("speech2.aiff",))
conv("audio.extract m4a from video-with-audio", "video_av.mp4", "m4a", v_ftyp("M4A "), v_media(2.0, 0.5, audio=1, video=0))

# ---- video -----------------------------------------------------------------------------------------------------
conv("video.mp4>mov", "video.mp4", "mov", v_ftyp("qt  "), v_media(2.0, 0.3, video=1, size=(320, 240)))
tool("video.mov>mp4 (by id)", "video.mov", "convert.video.mp4", v_ftyp("mp42", "isom", "mp41"), v_media(2.0, 0.3, video=1, size=(320, 240), vcodec="avc1"))


@check("cli.convert --to mp4 is not hijacked by 'MP4 (HEVC)' once HEVC was used")
def _(t):
    f = t.fx("video.mov")
    for _ in range(4):                       # usage ranking decides which of the two titles `--to mp4` hits
        t.ok("convert", f, "--to", "hevc")
    out = t.ok("convert", f, "--to", "mp4")[0]
    v_media(vcodec="avc1")(t, [out])
conv("video.mp4>HEVC mp4", "video.mp4", "hevc", v_ftyp("mp42", "isom", "mp41"), v_media(2.0, 0.3, video=1, vcodec=("hvc1", "hev1")))
conv("video.mp4>gif (width=160 fps=10)", "video.mp4", "gif", v_magic(b"GIF8"), v_img(160, 120),
     lambda t, o: expect(t.info(o[0])["frames"] >= 15, f"only {t.info(o[0])['frames']} GIF frames"),
     args=("--param", "width=160", "--param", "fps=10"))
tool("video.compress to 480p", "video.mp4", "tool.video.480p", v_media(2.0, 0.4, video=1), v_ftyp("mp42", "isom", "mp41"))
tool("video.compress to 720p", "video.mp4", "tool.video.720p", v_media(2.0, 0.4, video=1))
tool("video.trim 0.5s..1.5s", "video.mp4", "tool.video.trim", v_media(1.0, 0.6, video=1), params=("start=0.5", "end=1.5"))
tool("video.remove audio", "video_av.mp4", "tool.video.mute", v_media(2.0, 0.4, video=1, audio=0))
tool("video.merge two videos", "video.mp4", "tool.video.merge", v_media(4.0, 0.5, video=1), extra_fx=("video2.mp4",))
tool("video.save frame as JPG at 1s", "video.mp4", "tool.video.frame", v_magic(b"\xff\xd8"), v_img(320, 240), params=("at=1",))

# ---- documents -------------------------------------------------------------------------------------------------


def v_md_docx(t, outs):
    z = zip_of(outs[0])
    for part in ("[Content_Types].xml", "_rels/.rels", "word/document.xml"):
        xml_of(z, part)
    doc = xml_of(z, "word/document.xml")
    paras = para_texts(doc)
    texts = [(txt, st) for txt, st, _ in paras]
    expect(("Mer Test Document", "Heading1") in texts, f"Heading1 'Mer Test Document' missing: {texts[:6]}")
    expect(("Shopping List", "Heading2") in texts, f"Heading2 missing: {texts[:8]}")
    expect(any(st == "Heading3" and tx == "Steps" for tx, st in texts), "Heading3 'Steps' missing")
    numpr = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}numPr"
    for item in ("Apples", "Bananas", "Cherries"):
        row = [(tx, p) for tx, _, p in paras if item in tx]
        expect(row, f"list item {item} missing")
        tx, p = row[0]
        expect(tx.strip().startswith(("•", "◦", "·", "-")) or p.find(".//" + numpr) is not None, f"{item!r} lost its bullet marker: {tx!r}")
    # numbered items are real Word list paragraphs (w:numPr) pointing at a decimal numbering definition
    num_xml = xml_of(z, "word/numbering.xml")
    wns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    decimal = any(n.get("{%s}val" % wns["w"]) == "decimal" for n in num_xml.findall(".//w:numFmt", wns))
    step = [p for tx, _, p in paras if "First step" in tx]
    expect(step and (step[0].find(".//" + numpr) is not None or step[0].find(".//w:numPr", wns) is not None) and decimal,
           f"numbered item 'First step' is not a real numbered list paragraph: {[tx for tx, _ in texts if 'step' in tx]}")
    # hyperlink: w:hyperlink -> relationship with the external target
    ns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main", "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
    links = doc.findall(".//w:hyperlink", ns)
    expect(links, "no w:hyperlink element (link dropped)")
    rels = xml_of(z, "word/_rels/document.xml.rels")
    targets = {r.get("Id"): r.get("Target") for r in rels}
    rid = links[0].get("{%s}id" % ns["r"])
    expect(targets.get(rid) == "https://example.com/mer", f"hyperlink target {targets.get(rid)!r}")
    expect("Mer link" in itertext_of(links[0]), "hyperlink text lost")
    bold = [r for r in doc.iter("{%s}r" % ns["w"]) if r.find("w:rPr/w:b", ns) is not None and "bold words" in itertext_of(r)]
    ital = [r for r in doc.iter("{%s}r" % ns["w"]) if r.find("w:rPr/w:i", ns) is not None and "italic words" in itertext_of(r)]
    expect(bold, "bold run lost")
    expect(ital, "italic run lost")


conv("doc.md>docx (headings, lists, link, bold/italic)", "notes.md", "docx", v_md_docx)
conv("doc.md>pdf", "notes.md", "pdf", v_magic(b"%PDF"),
     v_pdf(minpages=1, has=("Mer Test Document", "Shopping List", "Apples", "Mer link", "Final paragraph"), hasnt=("**", "](http", "## ")))
conv("doc.md>rtf", "notes.md", "rtf", v_magic(b"{\\rtf"), v_text("Mer Test Document", "Apples"))
conv("doc.md>txt", "notes.md", "txt", v_text("# Mer Test Document", "Apples"))
conv("doc.md>doc (OLE)", "notes.md", "doc", v_magic(bytes.fromhex("D0CF11E0A1B11AE1")))


@check("doc.md>html (structure)")
def _(t):
    out = t.ok("convert", t.fx("notes.md"), "--to", "html")[0]

    class P(HTMLParser):
        def __init__(s):
            super().__init__()
            s.tags, s.links, s.text, s.stack = [], [], {}, []

        def handle_starttag(s, tag, attrs):
            s.tags.append(tag)
            s.stack.append(tag)
            if tag == "a":
                s.links.append(dict(attrs).get("href"))

        def handle_endtag(s, tag):
            if s.stack and s.stack[-1] == tag:
                s.stack.pop()

        def handle_data(s, d):
            if s.stack:
                s.text.setdefault(s.stack[-1], []).append(d)
    p = P()
    p.feed(out.read_text())
    expect(p.tags.count("li") == 6, f"expected 6 <li>, got {p.tags.count('li')}")
    expect(all(x in p.tags for x in ("h1", "h2", "h3", "ul", "ol", "strong", "em", "pre")), f"missing tags; saw {sorted(set(p.tags))}")
    expect("https://example.com/mer" in p.links, f"link lost: {p.links}")
    expect("Mer Test Document" in "".join(p.text.get("h1", [])), "h1 text wrong")


@check("doc.md>epub (valid container, XHTML, nav, content)")
def _(t):
    out = t.ok("convert", t.fx("notes.md"), "--to", "epub")[0]
    z = zip_of(out)
    first = z.infolist()[0]
    expect(first.filename == "mimetype" and first.compress_type == zipfile.ZIP_STORED, f"first entry must be stored 'mimetype', got {first.filename}/{first.compress_type}")
    expect(z.read("mimetype") == b"application/epub+zip", "wrong mimetype content")
    cont = xml_of(z, "META-INF/container.xml")
    rootfile = next(e for e in cont.iter() if local(e.tag) == "rootfile").get("full-path")
    opf = xml_of(z, rootfile)
    base = rootfile.rsplit("/", 1)[0] + "/" if "/" in rootfile else ""
    items = {e.get("id"): e for e in opf.iter() if local(e.tag) == "item"}
    expect(items, "empty manifest")
    expect(any(local(e.tag) == "title" and (e.text or "").strip() for e in opf.iter()), "dc:title missing")
    expect(any("nav" in (e.get("properties") or "") for e in items.values()), "no nav document in manifest")
    spine = [e.get("idref") for e in opf.iter() if local(e.tag) == "itemref"]
    expect(spine and all(s in items for s in spine), "spine references unknown items")
    body_text, hrefs, lis = "", [], 0
    for iid in spine:
        x = xml_of(z, base + items[iid].get("href"))
        body_text += itertext_of(x)
        hrefs += [e.get("href") for e in x.iter() if local(e.tag) == "a"]
        lis += sum(1 for e in x.iter() if local(e.tag) == "li")
    for needle in ("Mer Test Document", "Shopping List", "Bananas", "Second step"):
        expect(needle in body_text, f"EPUB text lacks {needle!r}")
    expect("https://example.com/mer" in hrefs, "hyperlink missing in EPUB")
    expect(lis == 6, f"{lis} list items in EPUB, expected 6")


@check("doc.md>odt (OpenDocument zip)")
def _(t):
    out = t.ok("convert", t.fx("notes.md"), "--to", "odt")[0]
    z = zip_of(out)
    expect(z.read("mimetype") == b"application/vnd.oasis.opendocument.text", "bad ODT mimetype")
    content = xml_of(z, "content.xml")
    expect("Mer Test Document" in itertext_of(content) and "Bananas" in itertext_of(content), "ODT text missing")


@check("doc.md>rtfd (package folder)")
def _(t):
    out = t.ok("convert", t.fx("notes.md"), "--to", "rtfd")[0]
    expect(out.is_dir() and (out / "TXT.rtf").exists(), f"RTFD is not a package with TXT.rtf: {out}")


@check("doc.docx>md keeps text, hyperlink, bold, bullets")
def _(t):
    s = t.ok("convert", t.fx("notes.docx"), "--to", "md")[0].read_text()
    for needle in ("Quarterly Report", "Highlights", "[Mer site](https://example.com/mer)", "**bold part**", "The end."):
        expect(needle in s, f"markdown lacks {needle!r}; got:\n{s}")
    expect(re.search(r"^[-*] First bullet$", s, re.M) and re.search(r"^[-*] Second bullet$", s, re.M), f"bullets not rendered as '- item':\n{s}")


@check("doc.docx>md turns Heading1/Heading2 styles into # / ##")
def _(t):
    s = t.ok("convert", t.fx("notes.docx"), "--to", "md")[0].read_text()
    expect(re.search(r"^# Quarterly Report$", s, re.M) and re.search(r"^## Highlights$", s, re.M) and re.search(r"^## Ordered steps$", s, re.M),
           f"style-based headings lost (textutil ignores style sizes); got:\n{s}")


@check("doc.docx>md keeps a decimal list numbered")
def _(t):
    s = t.ok("convert", t.fx("notes.docx"), "--to", "md")[0].read_text()
    expect(re.search(r"^1\. Step one$", s, re.M) and re.search(r"^2\. Step two$", s, re.M), f"decimal list not rendered as '1. 2.':\n{s}")


@check("doc.md>docx>md round trip keeps h1/h2, lists, link, bold")
def _(t):
    d = t.ok("convert", t.fx("notes.md"), "--to", "docx")[0]
    s = t.ok("convert", d, "--to", "md")[0].read_text()
    for pat in (r"^# Mer Test Document$", r"^## Shopping List$", r"^[-*] Apples$", r"^1\. First step$", r"^3\. Third step$"):
        expect(re.search(pat, s, re.M), f"round trip lost {pat!r}; got:\n{s}")
    expect("[Mer link](https://example.com/mer)" in s and "**bold words**" in s, f"inline formatting lost:\n{s}")


@check("doc.md>docx>md round trip keeps a level-3 heading")
def _(t):
    d = t.ok("convert", t.fx("notes.md"), "--to", "docx")[0]
    s = t.ok("convert", d, "--to", "md")[0].read_text()
    expect(re.search(r"^### Steps$", s, re.M), f"'### Steps' came back as {[l for l in s.splitlines() if 'Steps' in l]}")


conv("doc.docx>pdf", "notes.docx", "pdf", v_magic(b"%PDF"), v_pdf(minpages=1, has=("Quarterly Report", "Highlights", "First bullet", "Step two")))
conv("doc.docx>txt", "notes.docx", "txt", v_text("Quarterly Report", "bold part", "Step two"))
conv("doc.docx>epub", "notes.docx", "epub", lambda t, o: expect(b"Quarterly Report" in b"".join(zip_of(o[0]).read(n) for n in zip_of(o[0]).namelist() if n.endswith("xhtml")), "EPUB text missing"))
conv("doc.html>md (heading, link, list)", "page.html", "md", v_text("# Big Title", "[linked words](https://example.com/h)"),
     lambda t, o: expect(re.search(r"^[-*] one$", o[0].read_text(), re.M), "list item not a bullet"))
conv("doc.txt>docx", "long.txt", "docx", lambda t, o: expect("Line 180 of the long text file" in itertext_of(xml_of(zip_of(o[0]), "word/document.xml")), "last line missing"))


@check("doc.txt>pdf paginates (multi-page, last line present)")
def _(t):
    out = t.ok("convert", t.fx("long.txt"), "--to", "pdf")[0]
    v_pdf(minpages=3, has=("Line 1 of the long", "Line 180 of the long"))(t, [out])


# pandoc (optional)
conv("pandoc.md>rst", "notes.md", "rst", v_text("Mer Test Document", "Apples", "https://example.com/mer", "====="), needs="pandoc")
conv("pandoc.md>tex", "notes.md", "tex", v_text("\\section{Mer Test Document}", "\\href{https://example.com/mer}"), needs="pandoc")

# ---- spreadsheets / data ---------------------------------------------------------------------------------------
csv_rows = list(pycsv.reader(io.StringIO(CSV_TEXT)))
conv("data.csv>xlsx (shared strings, unicode, quotes)", "data.csv", "xlsx", lambda t, o: same_table(read_xlsx(o[0]), csv_rows), v_magic(b"PK"))
conv("data.csv>json", "data.csv", "json", lambda t, o: expect(
    json.loads(o[0].read_text()) == [dict(zip(csv_rows[0], r)) for r in csv_rows[1:]], f"json differs: {shorten(o[0].read_text())}"))
conv("data.csv>tsv", "data.csv", "tsv", lambda t, o: expect(
    list(pycsv.reader(io.StringIO(o[0].read_text()), delimiter="\t")) == csv_rows, f"tsv differs: {shorten(o[0].read_text())}"))
conv("data.tsv>csv", "data.tsv", "csv", lambda t, o: expect(
    list(pycsv.reader(io.StringIO(o[0].read_text()))) == [["a", "b", "c"], ["1", "two words", "3"], ["4", "5", "6"]], "csv differs"))
conv("data.xlsx>json (Excel-style file)", "data.xlsx", "json", lambda t, o: expect(
    json.loads(o[0].read_text()) == [{"id": "1", "name": "Ann", "score": "9.5"}, {"id": "2", "name": "Bob", "score": "7"}, {"id": "3", "name": "Zoë", "score": "10"}],
    f"json differs: {shorten(o[0].read_text())}"))
conv("data.xlsx>csv", "data.xlsx", "csv", lambda t, o: same_table(list(pycsv.reader(io.StringIO(o[0].read_text()))), XLSX_ROWS))
conv("data.json>csv (union of keys)", "data.json", "csv", lambda t, o: (
    lambda rows: expect(rows[0] == ["extra", "id", "name", "tags"] or sorted(rows[0]) == ["extra", "id", "name", "tags"], f"header {rows[0]}")
    or expect(len(rows) == 3 and "Ann" in rows[1] and "Bob" in rows[2], f"rows {rows}"))(list(pycsv.reader(io.StringIO(o[0].read_text())))))


@check("data.csv>xlsx>csv round trip")
def _(t):
    x = t.ok("convert", t.fx("data.csv"), "--to", "xlsx")[0]
    c = t.ok("convert", x, "--to", "csv")[0]
    same_table(list(pycsv.reader(io.StringIO(c.read_text()))), csv_rows)


@check("data.xlsx>ods via LibreOffice (optional)")
def _(t):
    t.need_engine("libreoffice")
    out = t.ok("convert", t.fx("data.xlsx"), "--to", "ods")[0]
    expect(zip_of(out).read("mimetype") == b"application/vnd.oasis.opendocument.spreadsheet", "bad ODS")


# ---- subtitles -------------------------------------------------------------------------------------------------
TS_VTT = re.compile(r"^\d\d:\d\d:\d\d\.\d{3} --> \d\d:\d\d:\d\d\.\d{3}$", re.M)
TS_SRT = re.compile(r"^\d\d:\d\d:\d\d,\d{3} --> \d\d:\d\d:\d\d,\d{3}$", re.M)


def v_srt2vtt(t, o):
    s = o[0].read_text(encoding="utf-8")
    expect(s.startswith("WEBVTT"), f"no WEBVTT header: {s[:30]!r}")
    expect(len(TS_VTT.findall(s)) == 3, f"expected 3 VTT timestamps with '.', got: {TS_VTT.findall(s)}")
    expect("," not in "".join(TS_VTT.findall(s)), "comma left in timestamps")
    expect("Hello, world!" in s, "comma in cue text must survive")
    expect("Café — naïve" in s and "with two rows" in s, "cue text lost")
    expect("00:00:01.000 --> 00:00:02.500" in s and "01:02:03.456 --> 01:02:05.000" in s, "timestamp values changed")


def v_vtt2srt(t, o):
    s = o[0].read_text(encoding="utf-8")
    ts = TS_SRT.findall(s)
    expect(len(ts) == 2, f"expected 2 SRT timestamps, got {ts} in {s!r}")
    expect("00:00:01,000 --> 00:00:02,500" in s, f"short mm:ss.mmm timestamp not padded / cue settings not removed: {s!r}")
    expect(re.match(r"^1\n", s) and re.search(r"^2\n00:00:03,000", s, re.M), f"cues not numbered: {s!r}")
    expect("align:" not in s and "<b>" not in s.replace("<b>Bold</b>", ""), "cue settings leaked")
    expect("Bold" in s and "WEBVTT" not in s, "cue text/ header wrong")


conv("subtitle.srt>vtt", "subs.srt", "vtt", v_srt2vtt)
conv("subtitle.vtt>srt", "subs.vtt", "srt", v_vtt2srt)
conv("subtitle.srt>txt (timestamps/indices stripped)", "subs.srt", "txt", v_text("Hello, world!", "Second line", "Café — naïve"),
     lambda t, o: expect(not re.search(r"-->|^\d+$", o[0].read_text(), re.M), "timestamps or indices left in plain text"))

# ---- archives --------------------------------------------------------------------------------------------------


@check("archive.folder>zip (structure + contents)")
def _(t):
    d = t.fx("project")
    out = t.ok("run", "tool.archive.pack-zip", d)[0]
    z = zip_of(out)
    names = set(zip_names(z))
    for n in ("project/a.txt", "project/sub/b.txt", "project/sub/deep/c.bin"):
        expect(n in names, f"{n} missing from zip: {sorted(names)}")
    expect(any(n.startswith("project/") and "é ünï.txt" in n for n in names), "unicode file name lost")
    expect(z.read("project/sub/deep/c.bin") == (d / "sub/deep/c.bin").read_bytes(), "binary content differs")
    expect(z.read("project/a.txt") == b"alpha file\n", "text content differs")
    expect(not any(n.startswith("__MACOSX") or n.endswith(".DS_Store") for n in names), "macOS junk in zip")


@check("archive.folder>zip flags non-ASCII names as UTF-8 (Windows / other tools read them)")
def _(t):
    out = t.ok("run", "tool.archive.pack-zip", t.fx("project"))[0]
    z = zip_of(out)
    bad = [i.filename for i in z.infolist() if any(ord(c) > 127 for c in i.filename) and not i.flag_bits & 0x800]
    expect(not bad, f"non-ASCII member names stored without the UTF-8 flag (garbled on Windows/Python): {bad}")


@check("archive.folder>zip>extract round trip (unicode name, binary content)")
def _(t):
    d = t.fx("project")
    z = t.ok("run", "tool.archive.pack-zip", d)[0]
    shutil.rmtree(d)
    out = t.ok("run", "tool.archive.extract", z)[0]
    names = {unicodedata.normalize("NFC", p.name) for p in out.rglob("*")}
    expect("é ünï.txt" in names and "c.bin" in names, f"names after extract: {sorted(names)}")
    expect((out / "project/sub/deep/c.bin").read_bytes() == random.Random(5).randbytes(5000), "binary content differs")


@check("archive.zip>extract (folder with contents)")
def _(t):
    out = t.ok("run", "tool.archive.extract", t.fx("project.zip"))[0]
    expect(out.is_dir(), "extract must produce a folder")
    expect((out / "project/a.txt").read_text() == "alpha file\n" and (out / "project/sub/b.txt").exists(), f"contents wrong: {sorted(str(p.relative_to(out)) for p in out.rglob('*'))}")


@check("archive.folder>tar.gz")
def _(t):
    out = t.ok("run", "tool.archive.pack-tar.gz", t.fx("project"))[0]
    with tarfile.open(out) as tf:
        names = tf.getnames()
        expect("project/sub/b.txt" in names and "project/a.txt" in names, f"tar names {names}")
    v_magic(b"\x1f\x8b")(t, [out])


@check("archive.folder>tar")
def _(t):
    out = t.ok("run", "tool.archive.pack-tar", t.fx("project"))[0]
    with tarfile.open(out) as tf:
        expect("project/a.txt" in tf.getnames(), f"tar names {tf.getnames()}")


@check("archive.file>zip")
def _(t):
    out = t.ok("run", "tool.archive.pack-zip", t.fx("long.txt"))[0]
    z = zip_of(out)
    expect(z.namelist() == ["long.txt"], f"names {z.namelist()}")


@check("archive.tar.gz>extract")
def _(t):
    out = t.ok("run", "tool.archive.extract", t.fx("project.tar.gz"))[0]
    expect((out / "project/sub/deep/c.bin").exists() and (out / "project/a.txt").read_text() == "alpha file\n", "tar.gz content wrong")


@check("archive.zip>tar.gz convert")
def _(t):
    out = t.ok("convert", t.fx("project.zip"), "--to", "tar.gz")[0]
    expect(out.name.endswith(".tar.gz"), f"name {out.name}")
    with tarfile.open(out) as tf:
        expect(any(n.endswith("project/a.txt") for n in tf.getnames()), f"tar names {tf.getnames()}")


@check("archive.Zip Together (2 files from the same folder)")
def _(t):
    out = t.ok("run", "tool.archive.pack-together", t.fx("long.txt"), t.fx("data.csv"))[0]
    expect(out.name == "Archive.zip", f"name {out.name}")
    expect(sorted(zip_of(out).namelist()) == ["data.csv", "long.txt"], f"names {zip_of(out).namelist()}")


# ---- PDF -------------------------------------------------------------------------------------------------------


@check("pdf.pdf>png (multi-page -> folder of PNGs)")
def _(t):
    out = t.ok("convert", t.fx("text3.pdf"), "--to", "png")[0]
    expect(out.is_dir(), "multi-page output must be a folder")
    pngs = sorted(out.glob("*.png"))
    expect(len(pngs) == 3, f"{len(pngs)} PNGs: {[p.name for p in out.iterdir()]}")
    for p in pngs:
        v_magic(b"\x89PNG")(t, [p])
        v_img(minw=400)(t, [p])
    v_px(5, 5, (255, 255, 255), tol=5)(t, [pngs[0]])


@check("pdf.pdf>jpg (single page -> one file)")
def _(t):
    out = t.ok("convert", t.fx("text1.pdf"), "--to", "jpg")[0]
    v_magic(b"\xff\xd8")(t, [out])
    v_img(minw=400)(t, [out])


@check("pdf.pdf>txt")
def _(t):
    out = t.ok("convert", t.fx("text3.pdf"), "--to", "txt")[0]
    s = out.read_text()
    for tok in ("TOKENA1", "TOKENA2", "TOKENA3", "quick brown fox"):
        expect(tok in s, f"text lacks {tok}")


@check("pdf.pdf>docx (text of every page)")
def _(t):
    out = t.ok("convert", t.fx("text3.pdf"), "--to", "docx")[0]
    txt = itertext_of(xml_of(zip_of(out), "word/document.xml"))
    for tok in ("TOKENA1", "TOKENA3", "quick brown fox"):
        expect(tok in txt, f"docx lacks {tok}")


@check("pdf.Merge PDFs (3 + 2 pages, order kept)")
def _(t):
    out = t.ok("run", "tool.pdf.merge", t.fx("text3.pdf"), t.fx("text2.pdf", as_name="2-text2.pdf"))[0]
    d = t.pdf(out)
    expect(d["pages"] == 5, f"pages {d['pages']}")
    expect("TOKENA1" in d["text"][0] and "TOKENA3" in d["text"][2] and "TOKENB1" in d["text"][3] and "TOKENB2" in d["text"][4], "page order wrong")


@check("pdf.Split into pages")
def _(t):
    r = t.mer("run", "tool.pdf.split", t.fx("text3.pdf"))
    expect(r.rc == 0, f"{r}")
    files = [p for o in r.outs for p in ([o] if o.is_file() else sorted(o.glob("*.pdf")))]
    expect(len(files) == 3, f"{len(files)} outputs: {r.out}")
    for i, f in enumerate(sorted(files), 1):
        d = t.pdf(f)
        expect(d["pages"] == 1 and f"TOKENA{i}" in d["text"][0], f"{f.name}: pages={d['pages']} text={shorten(d['text'])}")


@check("pdf.Extract Pages 2-3")
def _(t):
    out = t.ok("run", "tool.pdf.extract", t.fx("text3.pdf"), "--param", "pages=2-3")[0]
    d = t.pdf(out)
    expect(d["pages"] == 2 and "TOKENA2" in d["text"][0] and "TOKENA3" in d["text"][1], f"{d['pages']} pages: {shorten(d['text'])}")


@check("pdf.Rotate 90 right (page rotation set)")
def _(t):
    out = t.ok("run", "tool.pdf.rotate", t.fx("text2.pdf"))[0]
    d = t.pdf(out)
    expect(d["pages"] == 2 and d["rotation"] == [90, 90], f"rotation {d['rotation']}")
    expect("TOKENB1" in d["text"][0], "text lost")


@check("pdf.Compress PDF (big image shrinks, still 1 page)")
def _(t):
    f = t.fx("big.pdf")
    out = t.ok("run", "tool.pdf.compress", f)[0]
    expect(out.stat().st_size < f.stat().st_size * 0.9, f"not smaller: {f.stat().st_size} -> {out.stat().st_size}")
    v_pdf(pages=1)(t, [out])


@check("pdf.Make Searchable (OCR adds a text layer)")
def _(t):
    f = t.fx("scan.pdf")
    expect("quick brown fox" not in " ".join(t.pdf(f)["text"]).lower(), "fixture should have no text layer")
    out = t.ok("run", "tool.pdf.ocr", f)[0]
    v_pdf(pages=1, has=("quick brown fox", "lazy dog", "invoice"))(t, [out])


@check("pdf.qpdf encrypt -> decrypt (optional)")
def _(t):
    t.need_engine("qpdf")
    enc = t.ok("run", "qpdf.encrypt", t.fx("text1.pdf"), "--param", "password=s3cret")[0]
    expect(b"/Encrypt" in enc.read_bytes(), "encrypted PDF has no /Encrypt")
    expect(t.pdf(enc)["locked"], "PDFKit opens the protected PDF without a password")
    dec = t.ok("run", "qpdf.decrypt", enc, "--param", "password=s3cret")[0]
    v_pdf(pages=1, has=("TOKENC1",))(t, [dec])


# ---- external engines (optional) -------------------------------------------------------------------------------
conv("ffmpeg.aiff>mp3", "speech.aiff", "mp3", lambda t, o: expect(head_bytes(o[0], 3) == b"ID3" or head_bytes(o[0], 2)[0] == 0xFF, "not MP3"),
     v_media(speech_dur, 0.4, audio=1), needs="ffmpeg")
conv("ffmpeg.mp4>mkv", "video.mp4", "mkv", v_magic(bytes.fromhex("1A45DFA3")), v_ffprobe(2.0, 0.3, video=1), needs="ffmpeg")
conv("ffmpeg.mp4>webm", "video.mp4", "webm", v_magic(bytes.fromhex("1A45DFA3")), lambda t, o: expect(b"webm" in head_bytes(o[0], 64), "no webm doctype"), needs="ffmpeg")
conv("imagemagick.psd>png", "shapes.psd", "png", v_magic(b"\x89PNG"), v_img(40, 30), v_px(5, 5, (255, 0, 0), tol=40), needs="imagemagick")


# ---- negative / robustness -------------------------------------------------------------------------------------
@check("neg.video without audio -> m4a says 'no audio track'")
def _(t):
    t.fails("convert", t.fx("video.mp4"), "--to", "m4a", has=("no audio track",))


@check("neg.md -> md has no applicable action")
def _(t):
    t.fails("convert", t.fx("notes.md"), "--to", "md", has=("no matching action",))


@check("neg.png -> docx has no applicable action")
def _(t):
    t.fails("convert", t.fx("photo.png"), "--to", "docx", has=("no matching action",))


@check("neg.unknown file type has no action")
def _(t):
    t.fails("convert", t.fx("unknown.xyz"), "--to", "pdf", has=("no matching action",))


@check("neg.OCR on a blank image -> 'No text found'")
def _(t):
    t.fails("run", "convert.image.ocr-txt", t.fx("blank.png"), has=("no text",))


@check("neg.json that is not an array of objects")
def _(t):
    t.fails("convert", t.fx("object.json"), "--to", "csv", has=("array of objects",))


@check("neg.corrupt zip -> readable error, no leftover folder")
def _(t):
    f = t.fx("corrupt.zip")
    t.fails("run", "tool.archive.extract", f)
    expect(not (t.dir / "corrupt").exists(), "half-extracted folder left behind")


@check("neg.audio trim with end < start (bad param)")
def _(t):
    t.fails("run", "tool.audio.trim", t.fx("speech.aiff"), "--param", "start=3", "--param", "end=1", has=("invalid time range",))


@check("neg.audio trim past the end of the clip")
def _(t):
    r = t.mer("run", "tool.audio.trim", t.fx("speech.aiff"), "--param", "start=500", "--param", "end=600")
    expect(r.rc == 1 and r.err.strip(), f"expected a clean failure: {r}")


@check("neg.image resize with a non-numeric / non-positive size is rejected")
def _(t):
    f = t.fx("photo.png")
    for bad in ("abc", "0", "-5"):
        r = t.mer("run", "tool.image.resize", f, "--param", f"size={bad}")
        expect(r.rc == 1 and r.err.strip(), f"size={bad} should fail cleanly but: {r}")


@check("neg.audio trim with a non-numeric start is rejected")
def _(t):
    r = t.mer("run", "tool.audio.trim", t.fx("speech.aiff"), "--param", "start=abc")
    expect(r.rc == 1 and r.err.strip(), f"start=abc should fail cleanly but: {r}")


@check("neg.pdf extract pages out of range")
def _(t):
    t.fails("run", "tool.pdf.extract", t.fx("text3.pdf"), "--param", "pages=99", has=("no valid pages",))


@check("neg.single-page PDF cannot be split")
def _(t):
    t.fails("run", "tool.pdf.split", t.fx("text1.pdf"), has=("single page",))


@check("neg.PDF compress that cannot shrink: clean error or smaller file, never bigger")
def _(t):
    f = t.fx("text1.pdf")
    r = t.mer("run", "tool.pdf.compress", f)
    if r.rc == 0:
        expect(r.outs and r.outs[0].exists(), f"success without output: {r}")
        expect(r.outs[0].stat().st_size < f.stat().st_size, f"'compressed' PDF is not smaller ({f.stat().st_size} -> {r.outs[0].stat().st_size}) but no error was reported")
    else:
        expect(r.rc == 1 and any(w in r.err.lower() for w in ("optimis", "optimiz", "smaller")), f"unclear message: {r}")


@check("neg.merge PDFs with a single file is not offered")
def _(t):
    t.fails("run", "tool.pdf.merge", t.fx("text3.pdf"), has=("no matching action",))


@check("neg.image Compress is not offered for PNG")
def _(t):
    t.fails("run", "tool.image.compress", t.fx("photo.png"), has=("no matching action",))


@check("neg.missing input file")
def _(t):
    t.fails("convert", t.dir / "nope.png", "--to", "jpg", has=("no such file",))


@check("neg.convert without --to")
def _(t):
    t.fails("convert", t.fx("photo.png"), has=("--to",))


@check("neg.unknown action name")
def _(t):
    t.fails("run", "definitely-not-an-action", t.fx("photo.png"), has=("no matching action",))


@check("neg.run without action / convert without files")
def _(t):
    t.fails("run", has=("action",))
    t.fails("convert", "--to", "jpg", has=("no files",))


# ---- CLI surface -----------------------------------------------------------------------------------------------
@check("cli.list --json (all actions, unique ids, required keys)")
def _(t):
    r = t.mer("list", "--json")
    expect(r.rc == 0, f"{r}")
    rows = json.loads(r.out)
    expect(len(rows) >= 100, f"only {len(rows)} actions registered")
    ids = [x["id"] for x in rows]
    expect(len(ids) == len(set(ids)), f"duplicate ids: {sorted({i for i in ids if ids.count(i) > 1})[:5]}")
    for x in rows:
        expect(all(k in x for k in ("id", "title", "kind", "category", "engine")) and x["title"], f"bad row {x}")
        expect(x["kind"] in ("convert", "tool"), f"bad kind {x}")
    for must in ("convert.image.jpg", "convert.document.docx", "convert.sheet.xlsx", "tool.pdf.merge", "tool.pdf.ocr", "tool.archive.extract", "tool.video.480p"):
        expect(must in ids, f"native action {must} not registered")


@check("cli.list <file> shows applicable conversions and tools")
def _(t):
    r = t.mer("list", t.fx("photo.png"))
    expect(r.rc == 0 and "CONVERSIONS" in r.out and "TOOLS" in r.out, f"{r}")
    for w in ("JPG", "HEIC", "Resize 50%", "Rotate 90° Right"):
        expect(w in r.out, f"'{w}' not offered for a PNG:\n{r.out}")
    expect("Merge PDFs" not in r.out, "PDF tools offered for a PNG")


@check("cli.list <pdf> offers pdf actions only")
def _(t):
    r = t.mer("list", t.fx("text3.pdf"), "--json")
    ids = {a["id"] for a in json.loads(r.out)}
    for must in ("tool.pdf.split", "tool.pdf.rotate", "tool.pdf.compress", "tool.pdf.ocr", "convert.pdf.txt"):
        expect(must in ids, f"{must} missing for a PDF")
    expect("convert.image.jpg" not in ids and "tool.image.resize" not in ids, "image actions offered for a PDF")


@check("cli.engines lists every optional engine")
def _(t):
    r = t.mer("engines")
    expect(r.rc == 0, f"{r}")
    for e in ("FFmpeg", "Pandoc", "LibreOffice", "ImageMagick", "Ghostscript", "qpdf"):
        expect(re.search(rf"^{e}\s+(✓|✗)", r.out, re.M), f"engine {e} not reported:\n{r.out}")


@check("cli.help prints usage")
def _(t):
    r = t.mer("--help")
    expect(r.rc == 0 and "USAGE" in r.out and "convert" in r.out, f"{r}")


@check("cli.batch convert of 2 files prints 2 outputs")
def _(t):
    a, b = t.fx("photo.png"), t.fx("square.png")
    outs = t.ok("convert", a, b, "--to", "jpg")
    expect(sorted(o.name for o in outs) == ["photo.jpg", "square.jpg"], f"{[o.name for o in outs]}")


# --------------------------------------------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------------------------------------------
def build_mer(scratch_path):
    t0 = time.time()
    print(f"building mer (scratch {scratch_path}) ...", flush=True)
    last = ""
    for attempt in (1, 2):
        p = subprocess.run(["swift", "build", "--product", "mer", "--scratch-path", scratch_path], cwd=ROOT, capture_output=True, text=True)
        if p.returncode == 0:
            break
        last = (p.stdout + p.stderr)
        if attempt == 1:
            time.sleep(15)        # other developers may be mid-edit; retry once
    else:
        errs = [l for l in last.splitlines() if "error:" in l][:8]
        print("BUILD FAILED:\n" + "\n".join(errs or last.splitlines()[-15:]))
        sys.exit(2)
    rc, o, e = sh(["swift", "build", "--product", "mer", "--scratch-path", scratch_path, "--show-bin-path"], cwd=ROOT)
    binary = Path(o.strip()) / "mer"
    if not binary.exists():
        print("cannot locate built mer binary at", binary)
        sys.exit(2)
    print(f"built in {time.time() - t0:.0f}s: {binary}", flush=True)
    return binary


def main():
    ap = argparse.ArgumentParser(description="Mer regression suite")
    ap.add_argument("--scratch", help="base dir for fixtures/cache (default /tmp/mer-regression)")
    ap.add_argument("--keep", action="store_true", help="keep the run directory (fixtures + outputs)")
    ap.add_argument("--mer", help="use this mer binary instead of building")
    ap.add_argument("-k", dest="filter", action="append", default=[], help="only checks whose name contains this (case-insensitive, repeatable)")
    ap.add_argument("--list", action="store_true", help="list check names and exit")
    ap.add_argument("-j", dest="jobs", type=int, default=4, help="parallel checks (default 4)")
    ap.add_argument("--build-path", default="/tmp/mer-build-regression")
    ap.add_argument("-v", action="store_true", help="show details for passes too")
    args = ap.parse_args()

    names = [c[0] for c in CHECKS]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        print("duplicate check names:", dupes)
        return 2
    selected = [(i, c) for i, c in enumerate(CHECKS) if not args.filter or any(f.lower() in c[0].lower() for f in args.filter)]
    if args.list:
        for i, (n, _, xf) in [(i, c) for i, c in selected]:
            print(n + ("   [xfail: %s]" % xf if xf else ""))
        print(f"\n{len(selected)} checks")
        return 0
    if not selected:
        print("no checks match", args.filter)
        return 2

    mer = Path(args.mer).resolve() if args.mer else build_mer(args.build_path)
    base = Path(args.scratch or "/tmp/mer-regression")
    base.mkdir(parents=True, exist_ok=True)
    suite = Suite(base, mer, args.jobs)

    # `mer` ranks actions by usage; reset its (CLI-only) usage counters for a deterministic run and restore afterwards.
    backup = suite.base / "usage-backup.plist"
    rc, _, _ = sh(["defaults", "export", "mer", str(backup)])
    sh(["defaults", "delete", "mer", "mer.usage"])

    results = {}
    t_start = time.time()
    use_color = sys.stdout.isatty()

    def paint(s, code):
        return f"\033[{code}m{s}\033[0m" if use_color else s

    def run_one(idx_check):
        idx, (name, fn, xfail) = idx_check
        t0 = time.time()
        status, msg = "PASS", ""
        try:
            fn(T(suite, name, idx))
            if xfail:
                status, msg = "XPASS", f"expected failure now passes ({xfail})"
        except Skip as s:
            status, msg = "SKIP", str(s)
        except Fail as f:
            status, msg = ("XFAIL", f"{f}  [known: {xfail}]") if xfail else ("FAIL", str(f))
        except Exception as e:
            tb = traceback.format_exc().strip().splitlines()
            status, msg = ("XFAIL", f"{e!r} [known: {xfail}]") if xfail else ("FAIL", f"harness/unexpected error: {e!r} @ {tb[-3].strip() if len(tb) > 2 else ''}")
        return idx, name, status, time.time() - t0, msg

    try:
        # compile the Swift helper up front (once) so check timings are meaningful
        needs_helper = any(True for _ in selected)
        if needs_helper:
            t0 = time.time()
            try:
                suite.helper_bin()
            except Fail as f:
                print("cannot build the Swift test helper:", f)
                return 2
            print(f"test helper ready ({time.time() - t0:.0f}s)", flush=True)

        order = {i: n for n, (i, _) in enumerate(selected)}
        print(f"running {len(selected)} checks with -j{args.jobs} ...\n", flush=True)
        with cf.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
            for idx, name, status, secs, msg in ex.map(run_one, selected):
                results[idx] = (name, status, secs, msg)
                col = {"PASS": "32", "FAIL": "1;31", "SKIP": "33", "XFAIL": "35", "XPASS": "1;33"}[status]
                print(f"{paint(f'{status:5}', col)} {secs:6.2f}s  {name}", flush=True)
                if msg and (status != "PASS" or args.v):
                    print(f"        ↳ {shorten(msg, 600)}", flush=True)
    finally:
        if backup.exists():
            sh(["defaults", "import", "mer", str(backup)])
        else:
            sh(["defaults", "delete", "mer", "mer.usage"])
        if not args.keep:
            shutil.rmtree(suite.run_dir, ignore_errors=True)

    counts = {k: sum(1 for r in results.values() if r[1] == k) for k in ("PASS", "FAIL", "SKIP", "XFAIL", "XPASS")}
    total = len(results)
    print()
    fails = [(n, m) for n, s, _, m in results.values() if s == "FAIL"]
    if fails:
        print("FAILED CHECKS:")
        for n, m in fails:
            print(f"  - {n}\n      {shorten(m, 900)}")
        print()
    summary = f"{total} checks: {counts['PASS']} passed, {counts['FAIL']} failed, {counts['SKIP']} skipped"
    if counts["XFAIL"] or counts["XPASS"]:
        summary += f", {counts['XFAIL']} known-failing, {counts['XPASS']} unexpectedly passing"
    summary += f"  ({time.time() - t_start:.0f}s)"
    print(paint(summary, "1;31" if counts["FAIL"] else "1;32"))
    if args.keep:
        print("kept:", suite.run_dir)
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
