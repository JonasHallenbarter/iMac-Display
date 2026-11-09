import Foundation
import CoreGraphics
import CoreText
import CoreVideo
import CoreMedia
import VideoToolbox
import ImageIO

/// Objective quality lab: `imac-display --selftest-quality [--bitrates 40,60,80,120,160] [--fps 60,30] [--out <dir>]`
///
/// Renders realistic 4096x2304 desktop content (CoreGraphics/CoreText) into NV12 (BT.709 video range, like
/// ScreenCaptureKit), feeds it in real time through the production `H264Encoder`, decodes the output with
/// VTDecompressionSession and compares against the source (Y-PSNR overall / per region, chroma PSNR on coloured
/// text, 8x8 SSIM). Writes PNG crops (original RGB | NV12 source | decoded | diff x8, 3x nearest-neighbour zoom).
///
/// Further options:
///   --scenarios static,scroll,typing,motion   --compare (legacy vs. current defaults)   --legacy
///   --tune key=value,...  (peak, peakwin, quality, speed, lowlat, delay, maxqp, minqp, aq, kfi, refine,
///                          refinedelay, refineint, refinepsnr, refinebr, mse, inflight, cavlc, maxrt, slice)
///   --static-seconds 3.2   --no-png
enum QualityLab {
    static func run(arguments: [String]) -> Int32 {
        var o = LabOptions()
        var i = 0
        func next() -> String { i += 1; return i < arguments.count ? arguments[i] : "" }
        func list(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        while i < arguments.count {
            switch arguments[i] {
            case "--bitrates": o.bitrates = list(next()).compactMap(Double.init)
            case "--fps": o.fpsList = list(next()).compactMap(Int.init)
            case "--out": o.outDir = next()
            case "--scenarios": o.scenarios = list(next()).compactMap(Scenario.init(rawValue:))
            case "--tune": o.tune = next()
            case "--legacy": o.mode = .legacy
            case "--compare": o.mode = .compare
            case "--static-seconds": o.staticSeconds = Double(next()) ?? o.staticSeconds
            case "--no-png": o.png = false
            default: break
            }
            i += 1
        }
        if o.bitrates.isEmpty || o.fpsList.isEmpty || o.scenarios.isEmpty {
            print("QualityLab: ungültige Parameter"); return 2
        }
        do {
            try FileManager.default.createDirectory(atPath: o.outDir, withIntermediateDirectories: true)
        } catch {
            print("QualityLab: kann \(o.outDir) nicht anlegen: \(error)"); return 2
        }
        let lab = Lab(options: o)
        return lab.run()
    }
}

// MARK: - options

private enum Scenario: String, CaseIterable {
    case `static`, scroll, typing, motion
}

private struct LabOptions {
    enum Mode { case current, legacy, compare }
    var bitrates: [Double] = [40, 60, 80, 120, 160]
    var fpsList: [Int] = [60, 30]
    var outDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("imac-display-quality")
    var scenarios: [Scenario] = Scenario.allCases
    var tune = ""
    var mode = Mode.current
    var staticSeconds = 3.2
    var png = true
}

private func applyTune(_ tune: String, to s: inout H264Encoder.Settings) {
    for kv in tune.split(separator: ",") {
        let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard p.count == 2 else { continue }
        let v = p[1], d = Double(v), n = Int(v)
        let isNil = v == "nil" || v == "none"
        switch p[0] {
        case "peak": s.peakFactor = d ?? s.peakFactor
        case "peakwin": s.peakWindow = d ?? s.peakWindow
        case "quality": s.quality = isNil ? nil : d
        case "speed": s.prioritizeSpeed = v == "1" || v == "true"
        case "lowlat": s.lowLatency = v == "1" || v == "true"
        case "delay": s.maxFrameDelayCount = isNil ? nil : n
        case "maxqp": s.maxQP = isNil ? nil : n
        case "minqp": s.minQP = isNil ? nil : n
        case "aq": s.spatialAQ = isNil ? nil : n
        case "kfi": s.keyframeIntervalSeconds = d ?? s.keyframeIntervalSeconds
        case "refine": s.refineCount = n ?? s.refineCount
        case "refinedelay": s.refineDelayMs = d ?? s.refineDelayMs
        case "refineint": s.refineIntervalMs = d ?? s.refineIntervalMs
        case "refinepsnr": s.refineTargetPSNR = d ?? s.refineTargetPSNR
        case "refinebr": s.refineBitrateFactor = d ?? s.refineBitrateFactor
        case "mse": s.calculateMSE = v == "1" || v == "true"
        case "inflight": s.maxInFlight = n ?? s.maxInFlight
        case "cq": s.constantQuality = isNil ? nil : d
        case "keyonchange": s.keyframesOnlyOnChange = v == "1" || v == "true"
        case "refinekey": s.refineStartsWithKeyframe = v == "1" || v == "true"
        case "cavlc": s.entropyCAVLC = v == "1" || v == "true"
        case "maxrt": s.maxRealTimeFrameRate = isNil ? nil : d
        case "slice": s.maxSliceBytes = isNil ? nil : n
        default: print("QualityLab: unbekannter --tune-Schlüssel \(p[0])")
        }
    }
}

// MARK: - geometry / planes

private struct IRect {
    var x, y, w, h: Int
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    func offset(_ dx: Int, _ dy: Int) -> IRect { IRect(x: x + dx, y: y + dy, w: w, h: h) }
    func clipped(to r: IRect) -> IRect {
        let x0 = max(x, r.x), y0 = max(y, r.y), x1 = min(x + w, r.x + r.w), y1 = min(y + h, r.y + r.h)
        return IRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }
    /// even-aligned (for NV12 chroma)
    var even: IRect {
        let x0 = x & ~1, y0 = y & ~1
        return IRect(x: x0, y: y0, w: (x + w - x0 + 1) & ~1, h: (y + h - y0 + 1) & ~1)
    }
}

/// Read-only view on an NV12 image.
private struct NV12View {
    let w: Int, h: Int
    let y: UnsafePointer<UInt8>, ys: Int
    let uv: UnsafePointer<UInt8>, uvs: Int
}

/// Owned NV12 image (stride = width).
private final class NV12 {
    let w: Int, h: Int
    let y: UnsafeMutablePointer<UInt8>
    let uv: UnsafeMutablePointer<UInt8>
    init(w: Int, h: Int) {
        self.w = w; self.h = h
        y = .allocate(capacity: w * h)
        uv = .allocate(capacity: w * h / 2)
    }
    deinit { y.deallocate(); uv.deallocate() }
    var view: NV12View { NV12View(w: w, h: h, y: y, ys: w, uv: uv, uvs: w) }
}

// MARK: - colour conversion (BT.709, video range — like ScreenCaptureKit with colorMatrix 709)

private enum BT709 {
    static let kr = 0.2126, kb = 0.0722
    static let kg = 1 - kr - kb

    /// BGRA (8-bit, gamma-encoded sRGB values) → NV12 video range, 2x2 box-filtered chroma.
    static func toNV12(bgra: UnsafePointer<UInt8>, stride bs: Int, w: Int, h: Int,
                       y: UnsafeMutablePointer<UInt8>, ys: Int, uv: UnsafeMutablePointer<UInt8>, uvs: Int) {
        DispatchQueue.concurrentPerform(iterations: h / 2) { r2 in
            for dy in 0..<2 {
                let row = bgra + (r2 * 2 + dy) * bs
                let yrow = y + (r2 * 2 + dy) * ys
                for x in 0..<w {
                    let p = row + x * 4
                    let l = kr * Double(p[2]) + kg * Double(p[1]) + kb * Double(p[0])
                    yrow[x] = UInt8(clamping: Int((16 + l * 219 / 255).rounded()))
                }
            }
            let r0 = bgra + r2 * 2 * bs, r1 = r0 + bs
            let uvrow = uv + r2 * uvs
            for cx in 0..<(w / 2) {
                var b = 0, g = 0, r = 0
                for p in [r0 + cx * 8, r0 + cx * 8 + 4, r1 + cx * 8, r1 + cx * 8 + 4] {
                    b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                }
                let R = Double(r) / 4, G = Double(g) / 4, B = Double(b) / 4
                let l = kr * R + kg * G + kb * B
                let cb = (B - l) / (2 * (1 - kb)), cr = (R - l) / (2 * (1 - kr))
                uvrow[cx * 2] = UInt8(clamping: Int((128 + cb * 224 / 255).rounded()))
                uvrow[cx * 2 + 1] = UInt8(clamping: Int((128 + cr * 224 / 255).rounded()))
            }
        }
    }

    /// NV12 video range → BGRA the way Chrome's GPU path does it (BT.709 limited range,
    /// chroma upsampled bilinearly assuming centre siting).
    static func toBGRA(_ v: NV12View, rect r: IRect) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: r.w * r.h * 4)
        let cw = v.w / 2, ch = v.h / 2
        for yy in 0..<r.h {
            let py = r.y + yy
            let fy = Double(py) / 2 - 0.25
            let y0 = Int(fy.rounded(.down)), wy = fy - Double(y0)
            let ya = min(max(y0, 0), ch - 1), yb = min(max(y0 + 1, 0), ch - 1)
            for xx in 0..<r.w {
                let px = r.x + xx
                let fx = Double(px) / 2 - 0.25
                let x0 = Int(fx.rounded(.down)), wx = fx - Double(x0)
                let xa = min(max(x0, 0), cw - 1), xb = min(max(x0 + 1, 0), cw - 1)
                func c(_ k: Int) -> Double {
                    let a = Double(v.uv[ya * v.uvs + xa * 2 + k]), b = Double(v.uv[ya * v.uvs + xb * 2 + k])
                    let cc = Double(v.uv[yb * v.uvs + xa * 2 + k]), d = Double(v.uv[yb * v.uvs + xb * 2 + k])
                    return (a * (1 - wx) + b * wx) * (1 - wy) + (cc * (1 - wx) + d * wx) * wy
                }
                let Y = (Double(v.y[py * v.ys + px]) - 16) / 219
                let cb = (c(0) - 128) / 224, cr = (c(1) - 128) / 224
                let R = Y + 2 * (1 - kr) * cr
                let B = Y + 2 * (1 - kb) * cb
                let G = (Y - kr * R - kb * B) / kg
                let o = (yy * r.w + xx) * 4
                out[o] = UInt8(clamping: Int((B * 255).rounded()))
                out[o + 1] = UInt8(clamping: Int((G * 255).rounded()))
                out[o + 2] = UInt8(clamping: Int((R * 255).rounded()))
            }
        }
        return out
    }
}

// MARK: - drawing

private final class Canvas {
    let w: Int, h: Int
    let data: UnsafeMutablePointer<UInt8>
    let ctx: CGContext
    var stride: Int { w * 4 }

    init(w: Int, h: Int, fill: CGColor? = nil) {
        self.w = w; self.h = h
        data = .allocate(capacity: w * h * 4)
        data.initialize(repeating: 255, count: w * h * 4)
        ctx = CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        if let fill { self.fill(CGRect(x: 0, y: 0, width: w, height: h), fill) }
    }
    deinit { data.deallocate() }

    func fill(_ r: CGRect, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(r) }
    func roundRect(_ r: CGRect, radius: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
    func circle(cx: CGFloat, cy: CGFloat, r: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    static func attr(_ s: String, _ font: CTFont, _ color: CGColor, underline: Bool = false) -> NSAttributedString {
        var a: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if underline { a[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = NSNumber(value: CTUnderlineStyle.single.rawValue) }
        return NSAttributedString(string: s, attributes: a)
    }

    @discardableResult
    func text(_ s: String, x: CGFloat, baseline: CGFloat, font: CTFont, color: CGColor, underline: Bool = false) -> CGFloat {
        let line = CTLineCreateWithAttributedString(Canvas.attr(s, font, color, underline: underline))
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func textWidth(_ s: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(Canvas.attr(s, font, CGColor(gray: 0, alpha: 1))), nil, nil, nil))
    }

    /// Greedy wrapped paragraph; returns the y below the last line.
    func paragraph(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat, font: CTFont, color: CGColor, lineHeight: CGFloat) -> CGFloat {
        let a = Canvas.attr(s, font, color)
        let ts = CTTypesetterCreateWithAttributedString(a)
        var start = 0
        var yy = y
        let asc = CTFontGetAscent(font)
        let lead = (lineHeight - asc - CTFontGetDescent(font)) / 2
        while start < a.length {
            let n = CTTypesetterSuggestLineBreak(ts, start, Double(width))
            if n <= 0 { break }
            let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: n))
            ctx.textPosition = CGPoint(x: x, y: (yy + lead + asc).rounded())
            CTLineDraw(line, ctx)
            yy += lineHeight
            start += n
        }
        return yy
    }

    func cgImage() -> CGImage { ctx.makeImage()! }
}

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

private enum Fonts {
    static func ui(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    }
    static func mono(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Menlo" as CFString, size, nil) }
}

/// Deterministic pseudo text (no copyrighted material).
private struct WordGen {
    var state: UInt64
    static let words = ["der", "die", "das", "und", "Bildschirm", "Auflösung", "Qualität", "Daten", "wird", "mit",
                        "einer", "für", "Projekt", "Bericht", "Messung", "Ergebnis", "schnell", "scharf", "Text",
                        "zwischen", "Kabel", "Netzwerk", "Encoder", "Frame", "Pixel", "Farbe", "Kontrast", "sehr",
                        "nicht", "auch", "Version", "Fenster", "Dokument", "Tabelle", "Analyse", "Zeitplan", "Kunde",
                        "Angebot", "Rechnung", "Termin", "Besprechung", "Entwurf", "the", "display", "quality",
                        "rendering", "subpixel", "font", "latency", "bitrate", "hardware", "decoder", "smooth",
                        "präzise", "Übersicht", "Änderungen", "größer", "kleiner", "Schriftart", "Abstand", "Zeile",
                        "Absatz", "Kapitel", "Seite", "Grafik", "Diagramm", "Werte", "Prozent", "Montag", "Freitag",
                        "2026", "4096×2304", "60 Hz", "H.264", "WebCodecs", "z. B.", "etwa", "bereits", "später"]
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
    mutating func sentence(_ n: Int) -> String {
        var out: [String] = []
        for i in 0..<n {
            var w = WordGen.words[Int(next() % UInt64(WordGen.words.count))]
            if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
            out.append(w)
        }
        return out.joined(separator: " ") + (next() % 3 == 0 ? "; " : ". ")
    }
    mutating func paragraph(words: Int) -> String {
        var s = "", left = words
        while left > 0 { let n = min(left, 6 + Int(next() % 9)); s += sentence(n); left -= n }
        return s
    }
}

// MARK: - content

/// All the synthetic screen content plus the per-scenario frame generators.
private final class Content {
    let W = 4096, H = 2304
    let desktop: Canvas          // composited desktop (doc at scroll offset 0, typing line empty)
    let doc: Canvas              // tall scrollable document
    let base = NV12(w: 4096, h: 2304)
    let docNV: NV12
    let docRect = IRect(x: 64, y: 160, w: 1968, h: 1384)     // window A content (scroll area)
    let codeRect = IRect(x: 2096, y: 160, w: 1936, h: 1184)  // window B content
    let photoRect = IRect(x: 2096, y: 1464, w: 1936, h: 704) // window C content
    let panelRect = IRect(x: 64, y: 1608, w: 1968, h: 560)   // window D content
    let scrollStep = 8
    let maxScrollFrames = 180

    // regions (screen coordinates)
    private(set) var regText = IRect(x: 0, y: 0, w: 0, h: 0)
    private(set) var regSmall = IRect(x: 0, y: 0, w: 0, h: 0)
    private(set) var regColor = IRect(x: 0, y: 0, w: 0, h: 0)
    private(set) var regLines = IRect(x: 0, y: 0, w: 0, h: 0)
    private(set) var regCode = IRect(x: 0, y: 0, w: 0, h: 0)

    // typing
    let typingText = "    let crisp = encoder.refine(frame, qp: 18) // scharf"
    private(set) var typingBand = IRect(x: 0, y: 0, w: 0, h: 0)
    private(set) var typingCuts: [Int] = []     // x (band coords) of the cursor after n chars
    private var bandFull: Canvas!
    private var bandBG: [UInt8] = [0x1E, 0x1E, 0x1E, 255]

    // motion
    let panDX = 24, panDY = 12
    private var sinT = [Int32](repeating: 0, count: 4096)

    init() {
        let docH = 1384 + 180 * 8 + 64
        desktop = Canvas(w: 4096, h: 2304)
        doc = Canvas(w: 1968, h: docH, fill: rgb(0xFFFFFF))
        docNV = NV12(w: 1968, h: docH)
        for i in 0..<4096 { sinT[i] = Int32((sin(Double(i) / 4096 * 2 * .pi) * 1024).rounded()) }
        drawDocument()
        drawDesktop()
        // blit doc (offset 0) into desktop
        for r in 0..<docRect.h {
            memcpy(desktop.data + (docRect.y + r) * desktop.stride + docRect.x * 4, doc.data + r * doc.stride, docRect.w * 4)
        }
        BT709.toNV12(bgra: desktop.data, stride: desktop.stride, w: W, h: H, y: base.y, ys: W, uv: base.uv, uvs: W)
        BT709.toNV12(bgra: doc.data, stride: doc.stride, w: doc.w, h: doc.h, y: docNV.y, ys: doc.w, uv: docNV.uv, uvs: doc.w)
    }

    // ---- drawing

    private func drawWindow(_ c: Canvas, frame f: IRect, title: String, content: CGColor) {
        let r = f.cg
        c.ctx.saveGState()
        c.ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 48, color: rgb(0x000000, 0.45))
        c.roundRect(r, radius: 20, content)
        c.ctx.restoreGState()
        c.ctx.saveGState()
        c.ctx.addPath(CGPath(roundedRect: r, cornerWidth: 20, cornerHeight: 20, transform: nil))
        c.ctx.clip()
        c.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 56), rgb(0xE9E7EA))
        c.fill(CGRect(x: r.minX, y: r.minY + 55, width: r.width, height: 1), rgb(0xC6C6C6))
        c.ctx.restoreGState()
        for (i, col) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            c.circle(cx: r.minX + 30 + CGFloat(i) * 40, cy: r.minY + 28, r: 12, rgb(UInt32(col)))
        }
        let font = Fonts.ui(26, bold: true)
        let tw = c.textWidth(title, font: font)
        c.text(title, x: (r.midX - tw / 2).rounded(), baseline: r.minY + 37, font: font, color: rgb(0x3A3A3A))
    }

    private func drawDesktop() {
        let c = desktop
        // wallpaper gradient
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(0x1D2B6B), rgb(0x5B3C8C), rgb(0xC0607A), rgb(0xF0A060)] as CFArray,
                              locations: [0, 0.4, 0.75, 1])!
        c.ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 4096, y: 2304), options: [])
        // menu bar
        c.fill(CGRect(x: 0, y: 0, width: 4096, height: 48), rgb(0xF4F4F6, 0.92))
        var x: CGFloat = 40
        for (i, item) in ["", "Finder", "Ablage", "Bearbeiten", "Darstellung", "Gehe zu", "Fenster", "Hilfe"].enumerated() where i > 0 {
            x += c.text(item, x: x, baseline: 33, font: Fonts.ui(26, bold: i == 1), color: rgb(0x111111)) + 44
        }
        let clock = "Fr. 6. Nov.  21:04"
        c.text(clock, x: 4096 - 40 - c.textWidth(clock, font: Fonts.ui(26)), baseline: 33, font: Fonts.ui(26), color: rgb(0x111111))

        // window A: document (content blitted later)
        drawWindow(c, frame: IRect(x: docRect.x, y: docRect.y - 56, w: docRect.w, h: docRect.h + 56),
                   title: "Projektbericht.pages", content: rgb(0xFFFFFF))
        // window B: code editor
        drawWindow(c, frame: IRect(x: codeRect.x, y: codeRect.y - 56, w: codeRect.w, h: codeRect.h + 56),
                   title: "H264Encoder.swift — imac-display", content: rgb(0x1E1E1E))
        drawCode(c)
        // window C: photo
        drawWindow(c, frame: IRect(x: photoRect.x, y: photoRect.y - 56, w: photoRect.w, h: photoRect.h + 56),
                   title: "Vorschau — Landschaft.heic", content: rgb(0x000000))
        drawPhoto(c)
        // window D: settings panel
        drawWindow(c, frame: IRect(x: panelRect.x, y: panelRect.y - 56, w: panelRect.w, h: panelRect.h + 56),
                   title: "Einstellungen", content: rgb(0xF2F2F4))
        drawPanel(c)
        // dock
        c.roundRect(CGRect(x: 1208, y: 2184, width: 1680, height: 112), radius: 32, rgb(0xFFFFFF, 0.35))
        for i in 0..<15 {
            let ix = CGFloat(1232 + i * 110)
            let hue = Double(i) / 15
            let col = CGColor(srgbRed: CGFloat(0.5 + 0.5 * sin(hue * 6.28)), green: CGFloat(0.5 + 0.5 * sin(hue * 6.28 + 2.1)),
                              blue: CGFloat(0.5 + 0.5 * sin(hue * 6.28 + 4.2)), alpha: 1)
            c.roundRect(CGRect(x: ix, y: 2192, width: 96, height: 96), radius: 22, col)
            c.text(String("AFMSKNPCTLXQRWZ"[String.Index(utf16Offset: i, in: "AFMSKNPCTLXQRWZ")]), x: ix + 30, baseline: 2256,
                   font: Fonts.ui(44, bold: true), color: rgb(0xFFFFFF))
        }
    }

    private func drawCode(_ c: Canvas) {
        let kw = rgb(0x569CD6), ty = rgb(0x4EC9B0), id = rgb(0xD4D4D4), st = rgb(0xCE9178), cm = rgb(0x6A9955)
        let nu = rgb(0xB5CEA8), fn = rgb(0xDCDCAA)
        let lines: [[(String, CGColor)]] = [
            [("import", kw), (" Foundation", id)],
            [("import", kw), (" VideoToolbox", id)],
            [],
            [("// Hardware-H.264-Encoder für das virtuelle Display (4096×2304)", cm)],
            [("final class", kw), (" H264Encoder", ty), (" {", id)],
            [("    struct", kw), (" Settings", ty), (" {", id)],
            [("        var", kw), (" fps", id), (": ", id), ("Int", ty), (" = ", id), ("60", nu)],
            [("        var", kw), (" bitrateMbit", id), (": ", id), ("Double", ty), (" = ", id), ("80", nu)],
            [("    }", id)],
            [("    let", kw), (" queue", id), (" = ", id), ("DispatchQueue", ty), ("(label: ", id), ("\"imac-display.encoder\"", st), (")", id)],
            [("    private var", kw), (" session", id), (": ", id), ("VTCompressionSession", ty), ("?", id)],
            [],
            [("    func", kw), (" encode", fn), ("(_ pixelBuffer: ", id), ("CVPixelBuffer", ty), (", pts: ", id), ("CMTime", ty), (") {", id)],
            [("        dispatchPrecondition", fn), ("(condition: .onQueue(queue))", id)],
            [("        guard let", kw), (" session", id), (" else", kw), (" { ", id), ("return", kw), (" }", id)],
            [("        let", kw), (" props", id), (" = [", id), ("kVTEncodeFrameOptionKey_ForceKeyFrame", ty), (": ", id), ("true", kw), ("]", id)],
            [("        // Keyframe spätestens alle 5 s, bei neuem Client sofort", cm)],
            [("        VTCompressionSessionEncodeFrame", fn), ("(session, imageBuffer: pixelBuffer,", id)],
            [("            presentationTimeStamp: pts, duration: .invalid,", id)],
            [("            frameProperties: props, infoFlagsOut: ", id), ("nil", kw), (") { status, flags, sbuf ", id), ("in", kw)],
            [("            if", kw), (" status != noErr { ", id), ("logLine", fn), ("(", id), ("\"Fehler \\(status)\"", st), ("); ", id), ("return", kw), (" }", id)],
            [("            self", kw), (".handleOutput(sbuf!)", id)],
            [("        }", id)],
            [("    }", id)],
            [],
            [("    private func", kw), (" configure", fn), ("(_ s: ", id), ("VTCompressionSession", ty), (") -> ", id), ("Bool", ty), (" {", id)],
            [("        let", kw), (" bps", id), (" = settings.bitrateMbit * ", id), ("1_000_000", nu)],
            [("        VTSessionSetProperty", fn), ("(s, key: kVTCompressionPropertyKey_RealTime, value: ", id), ("kCFBooleanTrue", kw), (")", id)],
            [("        return", kw), (" VTCompressionSessionPrepareToEncodeFrames(s) == noErr", id)],
            [("    }", id)],
            [], // typing line (index 30)
            [("}", id)],
        ]
        let font = Fonts.mono(24)
        let lh: CGFloat = 36
        for (i, l) in lines.enumerated() {
            let top = CGFloat(codeRect.y + 16) + CGFloat(i) * lh
            if top + lh > CGFloat(codeRect.y + codeRect.h) { break }
            let base = top + 26
            let num = "\(i + 1)"
            c.text(num, x: CGFloat(codeRect.x + 84) - c.textWidth(num, font: font), baseline: base, font: font, color: rgb(0x6E7681))
            var x = CGFloat(codeRect.x + 120)
            for (s, col) in l { x += c.text(s, x: x, baseline: base, font: font, color: col) }
        }
        regCode = IRect(x: codeRect.x + 16, y: codeRect.y + 16, w: 1600, h: 30 * 36).even

        // typing band = line 30
        let top = codeRect.y + 16 + 30 * 36
        typingBand = IRect(x: codeRect.x + 120, y: top, w: 1600, h: 36).even
        bandFull = Canvas(w: typingBand.w, h: typingBand.h, fill: rgb(0x1E1E1E))
        bandFull.text(typingText, x: 0, baseline: 26, font: font, color: id)
        let line = CTLineCreateWithAttributedString(Canvas.attr(typingText, font, id))
        typingCuts = (0...typingText.utf16.count).map { Int(CTLineGetOffsetForStringIndex(line, $0, nil).rounded()) }
    }

    private func drawPhoto(_ c: Canvas) {
        // value-noise fbm landscape
        func hash(_ x: Int, _ y: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263)
            h = (h ^ (h >> 13)) &* 1274126177
            return Double(h ^ (h >> 16)) / Double(UInt32.max)
        }
        func noise(_ x: Double, _ y: Double) -> Double {
            let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
            let fx = x - Double(xi), fy = y - Double(yi)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let a = hash(xi, yi), b = hash(xi + 1, yi), cc = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
            return (a * (1 - sx) + b * sx) * (1 - sy) + (cc * (1 - sx) + d * sx) * sy
        }
        func fbm(_ x: Double, _ y: Double) -> Double {
            var v = 0.0, amp = 0.5, f = 1.0
            for _ in 0..<6 { v += amp * noise(x * f, y * f); f *= 2; amp *= 0.5 }
            return v
        }
        let r = photoRect
        DispatchQueue.concurrentPerform(iterations: r.h) { yy in
            let row = c.data + (r.y + yy) * c.stride + r.x * 4
            for xx in 0..<r.w {
                let u = Double(xx) / 220, v = Double(yy) / 220
                let ridge = 0.45 + 0.25 * fbm(u * 0.6, 3.1)
                let t = Double(yy) / Double(r.h)
                var R: Double, G: Double, B: Double
                if t < ridge {
                    let s = t / ridge
                    R = 0.35 + 0.4 * s; G = 0.55 + 0.3 * s; B = 0.9 - 0.1 * s
                    let cl = max(0, fbm(u * 1.5 + 7, v * 3) - 0.55) * 2
                    R += cl; G += cl; B += cl * 0.9
                } else {
                    let n = fbm(u * 2, v * 2)
                    let g = fbm(u * 9, v * 9)
                    R = 0.18 + 0.35 * n + 0.15 * g; G = 0.3 + 0.35 * n + 0.12 * g; B = 0.12 + 0.2 * n
                }
                let p = row + xx * 4
                p[0] = UInt8(clamping: Int(min(1, B) * 255)); p[1] = UInt8(clamping: Int(min(1, G) * 255))
                p[2] = UInt8(clamping: Int(min(1, R) * 255)); p[3] = 255
            }
        }
    }

    private func drawPanel(_ c: Canvas) {
        let r = panelRect
        let x0 = CGFloat(r.x + 48)
        var y = CGFloat(r.y + 40)
        let label = Fonts.ui(26), small = Fonts.ui(18)
        for i in 0..<4 {
            c.text(["Bildrate", "Bitrate", "Farbraum", "Verbindung"][i], x: x0, baseline: y + 26, font: label, color: rgb(0x1D1D1F))
            c.text(["60 Hz (empfohlen)", "80 Mbit/s", "BT.709 – begrenzter Bereich", "Ethernet 1 Gbit/s – 10.77.0.2"][i],
                   x: x0 + 420, baseline: y + 26, font: label, color: rgb(0x1D1D1F))
            c.text("Diese Einstellung wirkt sich auf Schärfe, Latenz und Datenrate der Übertragung zum iMac aus.",
                   x: x0 + 420, baseline: y + 56, font: small, color: rgb(0x6E6E73))
            // checkbox
            let cb = CGRect(x: CGFloat(r.x + r.w - 140), y: y + 4, width: 28, height: 28)
            c.fill(cb, rgb(0x8E8E93)); c.fill(cb.insetBy(dx: 1, dy: 1), i % 2 == 0 ? rgb(0x0A84FF) : rgb(0xFFFFFF))
            y += 84
            c.fill(CGRect(x: x0, y: y - 12, width: CGFloat(r.w - 96), height: 1), rgb(0xD1D1D6))
        }
        c.roundRect(CGRect(x: x0, y: y + 10, width: 260, height: 56), radius: 12, rgb(0x0A84FF))
        c.text("Übernehmen", x: x0 + 56, baseline: y + 47, font: Fonts.ui(26, bold: true), color: rgb(0xFFFFFF))
        c.fill(CGRect(x: x0 + 300, y: y + 10, width: 900, height: 56), rgb(0xFFECEC))
        c.text("Achtung: rote Schrift auf hellem Grund – Chroma-Test", x: x0 + 320, baseline: y + 47, font: label, color: rgb(0xD70015))
    }

    private func drawDocument() {
        let c = doc
        var gen = WordGen(state: 42)
        let left: CGFloat = 72, width: CGFloat = 1824
        var y: CGFloat = 40
        var section = 0
        while y < CGFloat(c.h - 400) {
            let first = section == 0
            c.text("\(section + 1). Projektbericht – Messung der Bildqualität", x: left, baseline: y + 44,
                   font: Fonts.ui(44, bold: true), color: rgb(0x000000))
            y += 72
            let textTop = y
            y = c.paragraph(gen.paragraph(words: 80), x: left, y: y, width: width, font: Fonts.ui(26), color: rgb(0x1D1D1F), lineHeight: 38) + 18
            y = c.paragraph(gen.paragraph(words: 80), x: left, y: y, width: width, font: Fonts.ui(24), color: rgb(0x000000), lineHeight: 34) + 18
            y = c.paragraph(gen.paragraph(words: 85), x: left, y: y, width: width, font: Fonts.ui(22), color: rgb(0x333333), lineHeight: 32) + 18
            if first { regText = IRect(x: Int(left) - 8, y: Int(textTop), w: Int(width) + 16, h: Int(y - textTop)).offset(docRect.x, docRect.y).even }
            let smallTop = y
            y = c.paragraph(gen.paragraph(words: 140), x: left, y: y, width: width, font: Fonts.ui(18), color: rgb(0x222222), lineHeight: 24) + 18
            if first { regSmall = IRect(x: Int(left) - 8, y: Int(smallTop), w: Int(width) + 16, h: Int(y - smallTop)).offset(docRect.x, docRect.y).even }
            let colorTop = y
            let cols: [(UInt32, UInt32?, Bool)] = [(0xFF0000, nil, false), (0x0000FF, nil, true), (0x008A00, nil, false),
                                                  (0xFF8C00, nil, false), (0xC000C0, nil, false), (0xD70015, 0xFFF4C0, false),
                                                  (0x0040FF, 0xE8E8E8, false)]
            for (fg, bg, ul) in cols {
                if let bg { c.fill(CGRect(x: left - 8, y: y, width: width + 16, height: 34), rgb(bg)) }
                c.text(gen.sentence(14), x: left, baseline: y + 25, font: Fonts.ui(24), color: rgb(fg), underline: ul)
                y += 34
            }
            y += 18
            if first { regColor = IRect(x: Int(left) - 8, y: Int(colorTop), w: Int(width) + 16, h: Int(y - colorTop)).offset(docRect.x, docRect.y).even }
            // table with 1-px lines + hairline patch
            let tableTop = y
            let cw: CGFloat = 200, rh: CGFloat = 40
            for r in 0...5 { c.fill(CGRect(x: left, y: y + CGFloat(r) * rh, width: cw * 6, height: 1), r == 0 || r == 5 ? rgb(0x000000) : rgb(0xC0C0C0)) }
            for k in 0...6 { c.fill(CGRect(x: left + CGFloat(k) * cw, y: y, width: 1, height: rh * 5), k == 0 || k == 6 ? rgb(0x000000) : rgb(0xC0C0C0)) }
            for r in 0..<5 {
                for k in 0..<6 {
                    let v = r == 0 ? ["Messung", "Mbit/s", "PSNR", "SSIM", "fps", "ms"][k] : String(format: "%.2f", Double(gen.next() % 10000) / 100)
                    c.text(v, x: left + CGFloat(k) * cw + 12, baseline: y + CGFloat(r) * rh + 28, font: Fonts.ui(22, bold: r == 0), color: rgb(0x000000))
                }
            }
            // hairlines: vertical 1px stripes, horizontal stripes, checkerboard, single-pixel dots
            let hx = left + cw * 6 + 60
            for k in 0..<60 { c.fill(CGRect(x: hx + CGFloat(k * 2), y: y, width: 1, height: 90), rgb(0x000000)) }
            for k in 0..<45 { c.fill(CGRect(x: hx + 140, y: y + CGFloat(k * 2), width: 120, height: 1), rgb(0x000000)) }
            for yy in 0..<90 { for xx in 0..<90 where (xx + yy) % 2 == 0 { c.fill(CGRect(x: hx + 280 + CGFloat(xx), y: y + CGFloat(yy), width: 1, height: 1), rgb(0x000000)) } }
            for yy in stride(from: 0, to: 90, by: 6) { for xx in stride(from: 0, to: 120, by: 6) { c.fill(CGRect(x: hx + 400 + CGFloat(xx), y: y + CGFloat(yy), width: 1, height: 1), rgb(0xFF0000)) } }
            y += rh * 5 + 4
            if first { regLines = IRect(x: Int(left) - 8, y: Int(tableTop) - 4, w: Int(cw * 6 + 60 + 540), h: Int(y - tableTop) + 8).offset(docRect.x, docRect.y).even }
            y += 48
            section += 1
        }
        regText = regText.clipped(to: docRect)
        regSmall = regSmall.clipped(to: docRect)
        regColor = regColor.clipped(to: docRect)
        regLines = regLines.clipped(to: docRect)
    }

    // ---- frames

    func frameCount(_ s: Scenario, fps: Int) -> Int {
        switch s {
        case .static: return 1
        case .scroll: return min(maxScrollFrames, 3 * fps)
        case .typing: return typingText.count + 1
        case .motion: return 2 * fps
        }
    }

    /// Render frame `i` of a scenario into NV12 planes.
    func render(_ s: Scenario, _ i: Int, y: UnsafeMutablePointer<UInt8>, ys: Int, uv: UnsafeMutablePointer<UInt8>, uvs: Int) {
        switch s {
        case .static, .scroll, .typing:
            copyPlanes(from: base.view, y: y, ys: ys, uv: uv, uvs: uvs)
            if s == .scroll {
                let off = min(i * scrollStep, docNV.h - docRect.h) & ~1
                for r in 0..<docRect.h {
                    memcpy(y + (docRect.y + r) * ys + docRect.x, docNV.y + (off + r) * docNV.w, docRect.w)
                }
                for r in 0..<(docRect.h / 2) {
                    memcpy(uv + (docRect.y / 2 + r) * uvs + docRect.x, docNV.uv + (off / 2 + r) * docNV.w, docRect.w)
                }
            } else if s == .typing {
                let band = typingBandPixels(i)
                band.withUnsafeBufferPointer { b in
                    BT709.toNV12(bgra: b.baseAddress!, stride: typingBand.w * 4, w: typingBand.w, h: typingBand.h,
                                 y: y + typingBand.y * ys + typingBand.x, ys: ys,
                                 uv: uv + typingBand.y / 2 * uvs + typingBand.x, uvs: uvs)
                }
            }
        case .motion:
            let sx = (i * panDX) % W, sy = (i * panDY) % H
            for r in 0..<H {
                let src = base.y + ((r + sy) % H) * W
                let dst = y + r * ys
                memcpy(dst, src + sx, W - sx)
                if sx > 0 { memcpy(dst + (W - sx), src, sx) }
            }
            for r in 0..<(H / 2) {
                let src = base.uv + ((r + sy / 2) % (H / 2)) * W
                let dst = uv + r * uvs
                memcpy(dst, src + sx, W - sx)
                if sx > 0 { memcpy(dst + (W - sx), src, sx) }
            }
            plasma(i, y: y, ys: ys, uv: uv, uvs: uvs)
        }
    }

    private func copyPlanes(from v: NV12View, y: UnsafeMutablePointer<UInt8>, ys: Int, uv: UnsafeMutablePointer<UInt8>, uvs: Int) {
        if ys == v.ys && uvs == v.uvs {
            memcpy(y, v.y, v.ys * v.h); memcpy(uv, v.uv, v.uvs * v.h / 2); return
        }
        for r in 0..<v.h { memcpy(y + r * ys, v.y + r * v.ys, v.w) }
        for r in 0..<(v.h / 2) { memcpy(uv + r * uvs, v.uv + r * v.uvs, v.w) }
    }

    /// "Video" region with unpredictable grain (worst case for motion compensation).
    private func plasma(_ i: Int, y: UnsafeMutablePointer<UInt8>, ys: Int, uv: UnsafeMutablePointer<UInt8>, uvs: Int) {
        let r = photoRect
        let t = Int32(i)
        DispatchQueue.concurrentPerform(iterations: r.h / 2) { r2 in
            for dy in 0..<2 {
                let yy = Int32(r2 * 2 + dy)
                let row = y + (r.y + Int(yy)) * ys + r.x
                for xx in 0..<Int32(r.w) {
                    var h = UInt32(bitPattern: xx &* 374761393 &+ yy &* 668265263 &+ t &* 1013904223)
                    h = (h ^ (h >> 13)) &* 1274126177
                    let n = Int32((h >> 24) & 31) - 16
                    let v = 120 + (sinT[Int((xx &* 3 &+ t &* 37) & 4095)] * 50 >> 10)
                        + (sinT[Int((yy &* 5 &+ xx &* 2 &+ t &* 53) & 4095)] * 40 >> 10) + n
                    row[Int(xx)] = UInt8(clamping: v)
                }
            }
            let urow = uv + (r.y / 2 + r2) * uvs + r.x
            let yy = Int32(r2)
            for cx in 0..<Int32(r.w / 2) {
                urow[Int(cx) * 2] = UInt8(clamping: 128 + (sinT[Int((cx &* 4 &+ yy &* 3 &+ t &* 41) & 4095)] * 60 >> 10))
                urow[Int(cx) * 2 + 1] = UInt8(clamping: 128 + (sinT[Int((cx &* 2 &- yy &* 5 &+ t &* 29 &+ 1024) & 4095)] * 60 >> 10))
            }
        }
    }

    /// BGRA band of the typing line with `n` characters typed and a 2-px cursor.
    func typingBandPixels(_ n: Int) -> [UInt8] {
        let w = typingBand.w, h = typingBand.h
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let cut = min(typingCuts[min(n, typingCuts.count - 1)], w - 2)
        out.withUnsafeMutableBufferPointer { o in
            for r in 0..<h {
                let src = bandFull.data + r * bandFull.stride
                let dst = o.baseAddress! + r * w * 4
                memcpy(dst, src, cut * 4)
                for x in cut..<w { dst[x * 4] = bandBG[0]; dst[x * 4 + 1] = bandBG[1]; dst[x * 4 + 2] = bandBG[2]; dst[x * 4 + 3] = 255 }
                if r >= 4 && r < h - 4 {
                    for x in cut..<(cut + 2) { dst[x * 4] = 0xAD; dst[x * 4 + 1] = 0xAF; dst[x * 4 + 2] = 0xAE }
                }
            }
        }
        return out
    }

    /// Original RGB (before 4:2:0) of a crop for static/scroll/typing frames; nil for motion.
    func originalBGRA(_ s: Scenario, _ i: Int, rect r: IRect) -> [UInt8]? {
        if s == .motion { return nil }
        var out = [UInt8](repeating: 255, count: r.w * r.h * 4)
        let band = s == .typing ? typingBandPixels(i) : []
        let off = s == .scroll ? min(i * scrollStep, docNV.h - docRect.h) & ~1 : 0
        for yy in 0..<r.h {
            for xx in 0..<r.w {
                let X = r.x + xx, Y = r.y + yy
                var p = desktop.data + Y * desktop.stride + X * 4
                if s == .scroll, X >= docRect.x, X < docRect.x + docRect.w, Y >= docRect.y, Y < docRect.y + docRect.h {
                    p = doc.data + (Y - docRect.y + off) * doc.stride + (X - docRect.x) * 4
                }
                let o = (yy * r.w + xx) * 4
                if s == .typing, X >= typingBand.x, X < typingBand.x + typingBand.w, Y >= typingBand.y, Y < typingBand.y + typingBand.h {
                    let b = ((Y - typingBand.y) * typingBand.w + (X - typingBand.x)) * 4
                    out[o] = band[b]; out[o + 1] = band[b + 1]; out[o + 2] = band[b + 2]
                } else {
                    out[o] = p[0]; out[o + 1] = p[1]; out[o + 2] = p[2]
                }
            }
        }
        return out
    }
}

// MARK: - metrics

private enum Metrics {
    static func psnr(_ mse: Double) -> Double { mse <= 1e-9 ? 99 : 10 * log10(255 * 255 / mse) }

    /// Y MSE over a rect.
    static func mseY(_ a: NV12View, _ b: NV12View, _ r: IRect) -> Double {
        guard r.w > 0, r.h > 0 else { return 0 }
        let chunks = 32
        var sums = [Double](repeating: 0, count: chunks)
        sums.withUnsafeMutableBufferPointer { s in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                var acc = 0
                var row = r.h * c / chunks
                while row < r.h * (c + 1) / chunks {
                    let pa = a.y + (r.y + row) * a.ys + r.x, pb = b.y + (r.y + row) * b.ys + r.x
                    for x in 0..<r.w { let d = Int(pa[x]) - Int(pb[x]); acc += d * d }
                    row += 1
                }
                s[c] = Double(acc)
            }
        }
        return sums.reduce(0, +) / Double(r.w * r.h)
    }

    /// Cb+Cr MSE over a rect (luma coordinates, even).
    static func mseUV(_ a: NV12View, _ b: NV12View, _ r: IRect) -> Double {
        guard r.w > 1, r.h > 1 else { return 0 }
        var acc = 0
        for row in (r.y / 2)..<((r.y + r.h) / 2) {
            let pa = a.uv + row * a.uvs + r.x, pb = b.uv + row * b.uvs + r.x
            for x in 0..<r.w { let d = Int(pa[x]) - Int(pb[x]); acc += d * d }
        }
        return Double(acc) / Double(r.w * r.h / 2)
    }

    /// Mean SSIM on Y with 8x8 windows (stride 8).
    static func ssim(_ a: NV12View, _ b: NV12View, _ r: IRect) -> Double {
        let bw = r.w / 8, bh = r.h / 8
        guard bw > 0, bh > 0 else { return 1 }
        let c1: Double = 6.5025, c2: Double = 58.5225 // (0.01*255)^2, (0.03*255)^2
        var rows = [Double](repeating: 0, count: bh)
        rows.withUnsafeMutableBufferPointer { rs in
            DispatchQueue.concurrentPerform(iterations: bh) { by in
                var acc = 0.0
                for bx in 0..<bw {
                    var sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0
                    for yy in 0..<8 {
                        let pa = a.y + (r.y + by * 8 + yy) * a.ys + r.x + bx * 8
                        let pb = b.y + (r.y + by * 8 + yy) * b.ys + r.x + bx * 8
                        for xx in 0..<8 {
                            let x = Int(pa[xx]), y = Int(pb[xx])
                            sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
                        }
                    }
                    let ma = Double(sa) / 64, mb = Double(sb) / 64
                    let va = Double(saa) / 64 - ma * ma, vb = Double(sbb) / 64 - mb * mb
                    let cov = Double(sab) / 64 - ma * mb
                    acc += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                }
                rs[by] = acc
            }
        }
        return rows.reduce(0, +) / Double(bw * bh)
    }
}

// MARK: - decoder

private final class LabDecoder {
    private var session: VTDecompressionSession?
    private(set) var format: CMVideoFormatDescription?
    private var sps: [UInt8] = [], pps: [UInt8] = []
    private(set) var lastSPS: [UInt8] = []

    static func splitAnnexB(_ d: Data) -> [[UInt8]] {
        let b = [UInt8](d)
        var nals: [[UInt8]] = []
        var i = 0, start = -1
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, b[end - 1] == 0 { end -= 1 }
                    nals.append(Array(b[start..<end]))
                }
                i += 3; start = i
            } else { i += 1 }
        }
        if start >= 0, start < b.count { nals.append(Array(b[start...])) }
        return nals
    }

    func decode(_ annexB: Data) -> CVPixelBuffer? {
        var payload = Data()
        var newSPS: [UInt8]?, newPPS: [UInt8]?
        for n in LabDecoder.splitAnnexB(annexB) where !n.isEmpty {
            switch n[0] & 0x1f {
            case 7: newSPS = n
            case 8: newPPS = n
            default:
                var len = UInt32(n.count).bigEndian
                payload.append(Data(bytes: &len, count: 4))
                payload.append(contentsOf: n)
            }
        }
        if let s = newSPS, let p = newPPS, s != sps || p != pps || session == nil {
            sps = s; pps = p; lastSPS = s
            if let old = session { VTDecompressionSessionInvalidate(old); session = nil }
            var f: CMFormatDescription?
            let st = s.withUnsafeBufferPointer { sb in
                p.withUnsafeBufferPointer { pb in
                    let ptrs = [sb.baseAddress!, pb.baseAddress!]
                    let sizes = [sb.count, pb.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &f)
                }
            }
            guard st == noErr, let f else { print("Decoder: FormatDescription-Fehler \(st)"); return nil }
            format = f
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            var s2: VTDecompressionSession?
            let st2 = VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: nil,
                                                   imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                   decompressionSessionOut: &s2)
            guard st2 == noErr, let s2 else { print("Decoder: Session-Fehler \(st2)"); return nil }
            session = s2
        }
        guard let session, let format, !payload.isEmpty else { return nil }
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &bb) == noErr, let bb else { return nil }
        payload.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: payload.count) }
        var sb: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        var out: CVPixelBuffer?
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if status == noErr { out = img } else { print("Decoder: Frame-Fehler \(status)") }
        }
        if st != noErr { print("Decoder: DecodeFrame-Fehler \(st)") }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return out
    }

    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }
}

// MARK: - SPS parsing (for codec string / colour signalling checks)

private struct SPSInfo: CustomStringConvertible {
    var profile = 0, constraints = 0, level = 0, chromaFormat = 1, pocType = 0, maxRefFrames = 0
    var widthMBs = 0, heightMBs = 0, frameMbsOnly = 1
    var vui = false, videoSignal = false, videoFormat = 5, fullRange = 0, colourDesc = false
    var primaries = 2, transfer = 2, matrix = 2
    var timing = false, bitstreamRestriction = false, maxReorder = -1, maxDecBuffering = -1
    var ok = false

    var description: String {
        var s = "profile_idc=\(profile) level_idc=\(level) chroma_format=\(chromaFormat) poc_type=\(pocType) ref_frames=\(maxRefFrames) "
        s += "\(widthMBs * 16)x\(heightMBs * 16 * (2 - frameMbsOnly)) MB-Raster"
        if !vui { return s + "; keine VUI" }
        s += "; VUI: video_signal_type=\(videoSignal ? "ja" : "nein")"
        if videoSignal {
            s += " video_full_range_flag=\(fullRange)"
            s += colourDesc ? " colour_primaries=\(primaries) transfer=\(transfer) matrix=\(matrix)" : " (keine colour_description)"
        }
        s += " bitstream_restriction=\(bitstreamRestriction ? "max_num_reorder_frames=\(maxReorder) max_dec_frame_buffering=\(maxDecBuffering)" : "nein")"
        return s
    }

    init(_ nal: [UInt8]) {
        guard nal.count > 4 else { return }
        var b: [UInt8] = []
        var zeros = 0
        for x in nal.dropFirst() {
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            b.append(x); zeros = x == 0 ? zeros + 1 : 0
        }
        var pos = 0
        func u(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                guard pos / 8 < b.count else { return v }
                v = (v << 1) | Int((b[pos / 8] >> (7 - UInt8(pos % 8))) & 1); pos += 1
            }
            return v
        }
        func ue() -> Int { var z = 0; while u(1) == 0 && z < 32 { z += 1 }; return (1 << z) - 1 + u(z) }
        profile = u(8); constraints = u(8); level = u(8); _ = ue()
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chromaFormat = ue(); if chromaFormat == 3 { _ = u(1) }
            _ = ue(); _ = ue(); _ = u(1)
            if u(1) == 1 { return }
        }
        _ = ue()
        pocType = ue()
        if pocType == 0 { _ = ue() } else if pocType == 1 { _ = u(1); _ = ue(); _ = ue(); let n = ue(); for _ in 0..<n { _ = ue() } }
        maxRefFrames = ue(); _ = u(1)
        widthMBs = ue() + 1; heightMBs = ue() + 1
        frameMbsOnly = u(1); if frameMbsOnly == 0 { _ = u(1) }
        _ = u(1)
        if u(1) == 1 { _ = ue(); _ = ue(); _ = ue(); _ = ue() }
        vui = u(1) == 1
        ok = true
        guard vui else { return }
        if u(1) == 1 { if u(8) == 255 { _ = u(16); _ = u(16) } }
        if u(1) == 1 { _ = u(1) }
        videoSignal = u(1) == 1
        if videoSignal {
            videoFormat = u(3); fullRange = u(1); colourDesc = u(1) == 1
            if colourDesc { primaries = u(8); transfer = u(8); matrix = u(8) }
        }
        if u(1) == 1 { _ = ue(); _ = ue() }
        timing = u(1) == 1
        if timing { _ = u(32); _ = u(32); _ = u(1) }
        func hrd() { let c = ue(); _ = u(4); _ = u(4); for _ in 0...c { _ = ue(); _ = ue(); _ = u(1) }; _ = u(20) }
        let nh = u(1); if nh == 1 { hrd() }
        let vh = u(1); if vh == 1 { hrd() }
        if nh == 1 || vh == 1 { _ = u(1) }
        _ = u(1)
        bitstreamRestriction = u(1) == 1
        if bitstreamRestriction { _ = u(1); _ = ue(); _ = ue(); _ = ue(); _ = ue(); maxReorder = ue(); maxDecBuffering = ue() }
    }
}

/// Lowest H.264 level whose MaxMBPS / MaxFS / MaxBR allow the stream (High profile: cpbBrNalFactor 1.25).
private func requiredLevel(width: Int, height: Int, fps: Double, mbit: Double) -> String {
    let fs = Double(((width + 15) / 16) * ((height + 15) / 16))
    let levels: [(String, Double, Double, Double)] = [ // name, MaxMBPS, MaxFS, MaxBR (kbit/s, baseline factor)
        ("4.1", 245_760, 8_192, 50_000), ("4.2", 522_240, 8_704, 50_000), ("5.0", 589_824, 22_080, 135_000),
        ("5.1", 983_040, 36_864, 240_000), ("5.2", 2_073_600, 36_864, 240_000), ("6.0", 4_177_920, 139_264, 240_000),
        ("6.1", 8_355_840, 139_264, 480_000), ("6.2", 16_711_680, 139_264, 800_000)]
    for l in levels where fs <= l.2 && fs * fps <= l.1 && mbit * 1000 <= l.3 * 1.25 { return l.0 }
    return ">6.2"
}

// MARK: - lab

private struct Output {
    let data: Data
    let info: H264Encoder.FrameInfo
}

private struct FrameMetric {
    var t: Double           // output time relative to first submit (s)
    var kind: H264Encoder.FrameInfo.Kind
    var isKey: Bool
    var bytes: Int
    var encMs: Double
    var frame: Int
    var all, text, small, code, lines, chroma, ssimAll, ssimText: Double
    var encPSNR: Double?
}

private struct RunResult {
    var scenario: Scenario
    var label: String
    var fps: Int
    var bitrate: Double
    var duration: Double
    var inputs: Int
    var outputs: [Output]
    var metrics: [FrameMetric]
    var keyRequestT: Double?
    var codec = "?"
    var sps: SPSInfo?
    var lowLatency = false
    var decodeFailures = 0
}

private final class Lab {
    let o: LabOptions
    let content: Content
    var allResults: [RunResult] = []

    init(options: LabOptions) {
        o = options
        let t0 = Date()
        print("QualityLab: erzeuge Testinhalt 4096x2304 (CoreGraphics/CoreText → NV12 BT.709 video range) ...")
        content = Content()
        print(String(format: "  fertig in %.1f s. Ausgabe: %@", Date().timeIntervalSince(t0), o.outDir))
    }

    func run() -> Int32 {
        print("\nRegionen: Text 11–13pt \(content.regText), 9pt \(content.regSmall), Farbe \(content.regColor), Linien \(content.regLines), Code \(content.regCode)")
        writeSourceOverview()
        var variants: [(String, (Int, Double) -> H264Encoder.Settings)] = []
        let current: (Int, Double) -> H264Encoder.Settings = { fps, br in
            var s = H264Encoder.Settings(fps: fps, bitrateMbit: br); applyTune(self.o.tune, to: &s); return s
        }
        let legacy: (Int, Double) -> H264Encoder.Settings = { fps, br in
            var s = H264Encoder.Settings.legacy(fps: fps, bitrateMbit: br); applyTune(self.o.tune, to: &s); return s
        }
        switch o.mode {
        case .current: variants = [("neu", current)]
        case .legacy: variants = [("alt", legacy)]
        case .compare: variants = [("alt", legacy), ("neu", current)]
        }
        for fps in o.fpsList {
            for br in o.bitrates {
                for (label, make) in variants {
                    let settings = make(fps, br)
                    for sc in o.scenarios {
                        let r = runScenario(sc, settings: settings, label: label)
                        allResults.append(r)
                        printRow(r)
                    }
                }
            }
        }
        printSummary()
        return 0
    }

    // ---- running

    private func makePool(_ w: Int, _ h: Int) -> CVPixelBufferPool {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary, attrs as CFDictionary, &pool)
        return pool!
    }

    private func runScenario(_ sc: Scenario, settings: H264Encoder.Settings, label: String) -> RunResult {
        let fps = settings.fps
        let enc = H264Encoder(settings: settings)
        let lock = NSLock()
        var outputs: [Output] = []
        enc.onEncodedFrame = { d, info in lock.lock(); outputs.append(Output(data: d, info: info)); lock.unlock() }
        enc.startIdleRefresh() // as in production

        // schedule: (time offset s, frame index)
        var schedule: [(Double, Int)] = []
        var hold = 0.5
        var keyRequestAt: Double?
        switch sc {
        case .static:
            schedule = [(0, 0)]
            hold = o.staticSeconds
            keyRequestAt = o.staticSeconds / 2
        case .scroll, .motion:
            schedule = (0..<content.frameCount(sc, fps: fps)).map { (Double($0) / Double(fps), $0) }
        case .typing:
            schedule = (0..<content.frameCount(sc, fps: fps)).map { (Double($0) / 15, $0) }
            hold = 1.5
        }
        let pool = makePool(content.W, content.H)
        var seqToFrame: [Int] = []
        let t0 = DispatchTime.now().uptimeNanoseconds + 50_000_000
        func sleepUntil(_ ns: UInt64) {
            let now = DispatchTime.now().uptimeNanoseconds
            if ns > now { Thread.sleep(forTimeInterval: Double(ns - now) / 1e9) }
        }
        var keyRequested = false
        for (t, idx) in schedule {
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            content.render(sc, idx,
                           y: CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self),
                           ys: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                           uv: CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self),
                           uvs: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
            CVPixelBufferUnlockBaseAddress(pb, [])
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            sleepUntil(t0 + UInt64(t * 1e9))
            seqToFrame.append(idx)
            enc.queue.async { enc.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock())) }
        }
        let endT = (schedule.last?.0 ?? 0) + 1 / Double(fps)
        if let k = keyRequestAt {
            sleepUntil(t0 + UInt64(k * 1e9)); enc.requestKeyframe(); keyRequested = true
        }
        sleepUntil(t0 + UInt64((endT + hold) * 1e9))
        enc.stop()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); let outs = outputs; lock.unlock()

        var res = RunResult(scenario: sc, label: label, fps: fps, bitrate: settings.bitrateMbit, duration: endT + hold,
                            inputs: schedule.count, outputs: outs, metrics: [], keyRequestT: keyRequested ? keyRequestAt : nil)
        res.lowLatency = enc.usingLowLatencyRC
        if let cfg = enc.codecConfigJSON, let obj = try? JSONSerialization.jsonObject(with: cfg) as? [String: Any] {
            res.codec = obj["codec"] as? String ?? "?"
        }
        analyze(&res, seqToFrame: seqToFrame, t0: t0)
        return res
    }

    // ---- analysis

    private func analyze(_ res: inout RunResult, seqToFrame: [Int], t0: UInt64) {
        let dec = LabDecoder()
        let src = NV12(w: content.W, h: content.H)
        var srcIndex = -1
        let sc = res.scenario
        let n = res.outputs.count
        let dir = (o.outDir as NSString).appendingPathComponent(String(format: "%dfps-%gM-%@", res.fps, res.bitrate, res.label))
        if o.png { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let mid = content.frameCount(sc, fps: res.fps) / 2
        var midDone = false
        var keyAfterRequestDone = false
        for (k, out) in res.outputs.enumerated() {
            guard let pb = dec.decode(out.data) else { res.decodeFailures += 1; continue }
            if k == 0 { res.sps = SPSInfo(dec.lastSPS) }
            let fidx = seqToFrame[max(0, min(seqToFrame.count - 1, out.info.sourceSeq - 1))]
            if fidx != srcIndex {
                content.render(sc, fidx, y: src.y, ys: src.w, uv: src.uv, uvs: src.w)
                srcIndex = fidx
            }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let dv = NV12View(w: CVPixelBufferGetWidth(pb), h: CVPixelBufferGetHeight(pb),
                              y: CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self),
                              ys: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                              uv: CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self),
                              uvs: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
            let sv = src.view
            let full = IRect(x: 0, y: 0, w: content.W, h: content.H)
            let m = FrameMetric(
                t: Double(Int64(out.info.outputNs) - Int64(t0)) / 1e9, kind: out.info.kind, isKey: out.info.isKey,
                bytes: out.info.bytes, encMs: Double(out.info.outputNs - out.info.submitNs) / 1e6, frame: fidx,
                all: Metrics.psnr(Metrics.mseY(sv, dv, full)),
                text: Metrics.psnr(Metrics.mseY(sv, dv, content.regText)),
                small: Metrics.psnr(Metrics.mseY(sv, dv, content.regSmall)),
                code: Metrics.psnr(Metrics.mseY(sv, dv, content.regCode)),
                lines: Metrics.psnr(Metrics.mseY(sv, dv, content.regLines)),
                chroma: Metrics.psnr(Metrics.mseUV(sv, dv, content.regColor)),
                ssimAll: Metrics.ssim(sv, dv, full),
                ssimText: Metrics.ssim(sv, dv, content.regText),
                encPSNR: out.info.lumaMSE.map(Metrics.psnr))
            res.metrics.append(m)

            if o.png {
                var shots: [(String, IRect)] = []
                let textCrops: [(String, IRect)] = [
                    ("text13", IRect(x: content.regText.x + 8, y: content.regText.y, w: 320, h: 160)),
                    ("tiny9", IRect(x: content.regSmall.x + 8, y: content.regSmall.y, w: 320, h: 120)),
                    ("color", IRect(x: content.regColor.x + 8, y: content.regColor.y, w: 320, h: 160)),
                    ("lines", IRect(x: content.regLines.x + 1200, y: content.regLines.y, w: 320, h: 120)),
                ]
                let codeCrop = ("code", IRect(x: content.codeRect.x + 40, y: content.codeRect.y + 16 + 9 * 36, w: 320, h: 160))
                let photoCrop = ("photo", IRect(x: content.photoRect.x + 800, y: content.photoRect.y + 200, w: 320, h: 160))
                switch sc {
                case .static:
                    if k == 0 { shots = (textCrops + [codeCrop, photoCrop]).map { ("static-first-\($0.0)", $0.1) } }
                    if k == n - 1 { shots = (textCrops + [codeCrop, photoCrop]).map { ("static-final-\($0.0)", $0.1) } }
                    if out.info.kind == .keyframeRequest, !keyAfterRequestDone {
                        keyAfterRequestDone = true
                        shots = textCrops.prefix(2).map { ("static-keyreq-\($0.0)", $0.1) }
                    }
                case .scroll:
                    if fidx >= mid, !midDone { midDone = true; shots = textCrops.prefix(3).map { ("scroll-mid-\($0.0)", $0.1) } }
                    if k == n - 1 { shots = textCrops.prefix(2).map { ("scroll-after-\($0.0)", $0.1) } }
                case .typing:
                    let typed = IRect(x: content.typingBand.x - 40, y: content.typingBand.y - 60, w: 640, h: 120)
                    if fidx >= mid, !midDone { midDone = true; shots = [("typing-mid-line", typed)] }
                    if k == n - 1 { shots = [("typing-final-line", typed), ("typing-final-code", codeCrop.1)] }
                case .motion:
                    if fidx >= mid, !midDone { midDone = true; shots = [("motion-mid-code", codeCrop.1), ("motion-mid-video", photoCrop.1)] }
                }
                for (name, r) in shots {
                    writeCrop(path: (dir as NSString).appendingPathComponent("\(name).png"), rect: r.even,
                              original: content.originalBGRA(sc, fidx, rect: r.even), src: sv, dec: dv,
                              caption: String(format: "%@ | %d fps %g Mbit/s (%@) | Frame %d (%@%@), %d KB | Y-PSNR Ausschnitt %.2f dB",
                                              name, res.fps, res.bitrate, res.label, k, out.info.kind.rawValue, out.info.isKey ? ", IDR" : "",
                                              out.info.bytes / 1024, Metrics.psnr(Metrics.mseY(sv, dv, r.even))))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
    }

    // ---- PNG

    private func writePNG(_ img: CGImage, _ path: String) {
        guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
    }

    private func writeCrop(path: String, rect r: IRect, original: [UInt8]?, src: NV12View, dec: NV12View, caption: String) {
        let z = 3, gap = 12, head = 44, sub = 34
        var panels: [(String, [UInt8])] = []
        if let original { panels.append(("Original RGB (vor 4:2:0)", original)) }
        panels.append(("Quelle NV12 → RGB (wie Chrome)", BT709.toBGRA(src, rect: r)))
        panels.append(("Dekodiert → RGB (wie Chrome)", BT709.toBGRA(dec, rect: r)))
        var diff = [UInt8](repeating: 255, count: r.w * r.h * 4)
        for yy in 0..<r.h {
            for xx in 0..<r.w {
                let d = abs(Int(src.y[(r.y + yy) * src.ys + r.x + xx]) - Int(dec.y[(r.y + yy) * dec.ys + r.x + xx]))
                let v = UInt8(clamping: 255 - d * 8)
                let o = (yy * r.w + xx) * 4
                diff[o] = v; diff[o + 1] = v; diff[o + 2] = 255
            }
        }
        panels.append(("|ΔY| × 8 (weiß = identisch)", diff))
        let pw = r.w * z, ph = r.h * z
        let c = Canvas(w: panels.count * pw + (panels.count + 1) * gap, h: ph + head + sub + gap, fill: rgb(0x2B2B2B))
        for (pi, p) in panels.enumerated() {
            let ox = gap + pi * (pw + gap), oy = head + sub
            p.1.withUnsafeBufferPointer { px in
                for yy in 0..<ph {
                    let srow = (yy / z) * r.w
                    let drow = c.data + (oy + yy) * c.stride + ox * 4
                    for xx in 0..<pw {
                        let s = (srow + xx / z) * 4
                        drow[xx * 4] = px[s]; drow[xx * 4 + 1] = px[s + 1]; drow[xx * 4 + 2] = px[s + 2]; drow[xx * 4 + 3] = 255
                    }
                }
            }
            c.text(p.0, x: CGFloat(ox), baseline: CGFloat(head + 24), font: Fonts.ui(22, bold: true), color: rgb(0xFFFFFF))
        }
        c.text(caption, x: CGFloat(gap), baseline: 30, font: Fonts.ui(22), color: rgb(0xE0E0E0))
        writePNG(c.cgImage(), path)
    }

    private func writeSourceOverview() {
        guard o.png else { return }
        // half-size overview of the synthetic desktop with metric regions outlined
        let w = content.W / 2, h = content.H / 2
        let c = Canvas(w: w, h: h)
        c.ctx.saveGState()
        c.ctx.translateBy(x: 0, y: CGFloat(h)); c.ctx.scaleBy(x: 1, y: -1) // undo flip for image drawing
        c.ctx.interpolationQuality = .high
        c.ctx.draw(content.desktop.cgImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        c.ctx.restoreGState()
        c.ctx.setLineWidth(3)
        for (r, col) in [(content.regText, 0x00C000), (content.regSmall, 0xFF8000), (content.regColor, 0xFF00FF),
                         (content.regLines, 0x00C0FF), (content.regCode, 0xFFFF00), (content.typingBand, 0xFF0000)] {
            c.ctx.setStrokeColor(rgb(UInt32(col)))
            c.ctx.stroke(CGRect(x: r.x / 2, y: r.y / 2, width: r.w / 2, height: r.h / 2))
        }
        writePNG(c.cgImage(), (o.outDir as NSString).appendingPathComponent("source-overview.png"))
        let full = (o.outDir as NSString).appendingPathComponent("source-full-4096x2304.png")
        writePNG(content.desktop.cgImage(), full)
    }

    // ---- reporting

    private struct Agg {
        var mbps = 0.0, peak1s = 0.0, maxKB = 0.0, keyKB = 0.0, keys = 0, frames = 0, capFrames = 0
        var fps = 0.0, encAvg = 0.0, encMax = 0.0
        var all = 0.0, text = 0.0, small = 0.0, code = 0.0, lines = 0.0, chroma = 0.0, ssimAll = 0.0, ssimText = 0.0
        var minText = 0.0
    }

    private func aggregate(_ r: RunResult, _ sel: [FrameMetric]) -> Agg {
        var a = Agg()
        let ms = r.metrics
        guard !ms.isEmpty else { return a }
        let bytes = ms.reduce(0) { $0 + $1.bytes }
        a.mbps = Double(bytes) * 8 / r.duration / 1e6
        // max bytes in any 1 s window
        var j = 0, win = 0
        for i in 0..<ms.count {
            win += ms[i].bytes
            while ms[i].t - ms[j].t > 1.0 { win -= ms[j].bytes; j += 1 }
            a.peak1s = max(a.peak1s, Double(win) * 8 / 1e6)
        }
        a.maxKB = Double(ms.map(\.bytes).max() ?? 0) / 1024
        a.keyKB = Double(ms.first(where: { $0.isKey })?.bytes ?? 0) / 1024
        a.keys = ms.filter(\.isKey).count
        a.frames = ms.count
        let cap = ms.filter { $0.kind == .capture }
        a.capFrames = cap.count
        if cap.count > 1 { a.fps = Double(cap.count - 1) / (cap.last!.t - cap.first!.t) }
        a.encAvg = ms.map(\.encMs).reduce(0, +) / Double(ms.count)
        a.encMax = ms.map(\.encMs).max() ?? 0
        let s = sel.isEmpty ? ms : sel
        func mean(_ k: KeyPath<FrameMetric, Double>) -> Double { s.map { $0[keyPath: k] }.reduce(0, +) / Double(s.count) }
        a.all = mean(\.all); a.text = mean(\.text); a.small = mean(\.small); a.code = mean(\.code); a.lines = mean(\.lines)
        a.chroma = mean(\.chroma); a.ssimAll = mean(\.ssimAll); a.ssimText = mean(\.ssimText)
        a.minText = s.map(\.text).min() ?? 0
        return a
    }

    private static let header = String(format: "%-4@ %-7@ %4@ %5@ | %6@ %6@ %6@ %6@ %4@ %7@ %5@ %9@ | %5@ %5@ %5@ %5@ %5@ %5@ %6@ %6@ %5@",
                                       "neu?", "Szene", "fps", "Mbit", "Mbit/s", "1s-pk", "maxKB", "keyKB", "keys", "n/in", "fps", "enc ms",
                                       "Yall", "Text", "9pt", "Code", "Linie", "Chrom", "SSIMa", "SSIMt", "minTx")

    private func row(_ r: RunResult, _ a: Agg, tag: String) -> String {
        String(format: "%-4@ %-7@ %4d %5g | %6.1f %6.1f %6.0f %6.0f %4d %3d/%-3d %5.1f %4.1f/%-4.0f | %5.2f %5.2f %5.2f %5.2f %5.2f %5.2f %6.4f %6.4f %5.2f",
               r.label, tag, r.fps, r.bitrate, a.mbps, a.peak1s, a.maxKB, a.keyKB, a.keys, a.capFrames, r.inputs, a.fps,
               a.encAvg, a.encMax, a.all, a.text, a.small, a.code, a.lines, a.chroma, a.ssimAll, a.ssimText, a.minText)
    }

    private var printedHeader = false

    private func printRow(_ r: RunResult) {
        if !printedHeader {
            print("\nSpalten: Mbit/s = Bytes/Szenendauer, 1s-pk = max. Mbit in 1 s, n/in = Capture-Frames kodiert/geliefert, enc ms = Ø/max Encode-Latenz,")
            print("         Yall/Text/9pt/Code/Linie = Y-PSNR dB (Mittel über alle dekodierten Frames bzw. Endzustand), Chrom = Cb/Cr-PSNR farbiger Text,")
            print("         SSIMa/SSIMt = SSIM Y gesamt/Text, minTx = schlechtester Frame Text-PSNR\n")
            print(Lab.header)
            printedHeader = true
        }
        let a = aggregate(r, [])
        if r.decodeFailures > 0 { print("  !! \(r.decodeFailures) Frames nicht dekodierbar") }
        switch r.scenario {
        case .static:
            let first = r.metrics.first.map { [$0] } ?? []
            let final = r.metrics.last.map { [$0] } ?? []
            print(row(r, aggregate(r, first), tag: "stat1st"))
            print(row(r, aggregate(r, final), tag: "statEnd"))
            printConvergence(r)
        case .typing:
            print(row(r, a, tag: "typing"))
            print(row(r, aggregate(r, r.metrics.last.map { [$0] } ?? []), tag: "typeEnd"))
            let kinds = Dictionary(grouping: r.metrics, by: { $0.kind.rawValue }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
            let tail = r.metrics.suffix(12).map { String(format: "%.2fs %@%@ %dK %.1f", $0.t, $0.kind.rawValue, $0.isKey ? "(IDR)" : "", $0.bytes / 1024, $0.code) }
            print("      Frames: \(kinds); letzte: " + tail.joined(separator: " | "))
        default:
            print(row(r, a, tag: r.scenario.rawValue))
        }
    }

    private func at(_ r: RunResult, _ t: Double) -> FrameMetric? { r.metrics.last(where: { $0.t <= t }) }

    private func printConvergence(_ r: RunResult) {
        var s = "      Konvergenz Text/9pt/Code-PSNR (dB) nach t:"
        for t in [0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 1.5] {
            if let m = at(r, t) { s += String(format: "  %.2fs: %.1f/%.1f/%.1f", t, m.text, m.small, m.code) }
        }
        print(s)
        if let k = r.keyRequestT, let ki = r.metrics.firstIndex(where: { $0.kind == .keyframeRequest }) {
            let km = r.metrics[ki]
            var s2 = String(format: "      Keyframe-Anfrage bei %.2fs (neuer Client): IDR %d KB → Text %.1f dB", k, km.bytes / 1024, km.text)
            for dt in [0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 1.5] {
                if let m = at(r, km.t + dt), m.t > km.t { s2 += String(format: "  +%.2fs: %.1f", dt, m.text) }
            }
            print(s2)
        }
        let kinds = Dictionary(grouping: r.metrics, by: { $0.kind.rawValue }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        let bytes = r.metrics.reduce(0) { $0 + $1.bytes }
        print("      Frames: \(kinds), gesamt \(bytes / 1024) KB in \(String(format: "%.1f", r.duration)) s"
              + (r.metrics.contains { $0.encPSNR != nil } ? String(format: ", Encoder-PSNR letzter Frame %.1f dB (Decoder: %.1f dB)",
                                                                    r.metrics.last?.encPSNR ?? 0, r.metrics.last?.all ?? 0) : ""))
    }

    private func printSummary() {
        print("\n==== Codec / Level / Farbsignalisierung ====")
        var seen = Set<String>()
        for r in allResults {
            let key = "\(r.fps)-\(r.bitrate)-\(r.label)"
            guard !seen.contains(key), let sps = r.sps else { continue }
            seen.insert(key)
            let need = requiredLevel(width: content.W, height: content.H, fps: Double(r.fps), mbit: r.bitrate * max(1, 1.5))
            print(String(format: "%3d fps %5g Mbit/s (%@): codec %@ (Level %.1f), nötig laut Tabelle: %@, RC=%@",
                         r.fps, r.bitrate, r.label, r.codec, Double(sps.level) / 10, need, r.lowLatency ? "LowLatency" : "Standard"))
            print("      SPS: \(sps)")
            let rangeOK = !sps.videoSignal || sps.fullRange == 0
            let matrixOK = !sps.colourDesc || sps.matrix == 1
            print("      Farbcheck: video_full_range_flag \(sps.videoSignal ? "\(sps.fullRange)" : "fehlt (Decoder-Default = limited)") → \(rangeOK ? "OK (video range wie NV12-Capture)" : "FALSCH (würde ausgewaschen/zu kräftig)"), "
                  + "Matrix \(sps.colourDesc ? "\(sps.matrix)" : "fehlt") → \(matrixOK ? "OK (BT.709)" : "ABWEICHEND"), "
                  + "Reorder: \(sps.maxReorder == 0 ? "0 (OK, keine Puffer-Latenz)" : "\(sps.maxReorder) !!")")
        }
        print("\nPNG-Ausschnitte: \(o.outDir)")
    }
}
