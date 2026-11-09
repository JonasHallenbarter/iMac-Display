import AppKit
import CoreImage

/// QR-Code nativ mit CoreImage (CIQRCodeGenerator, macOS 10.9+) – kein Netz, keine Bibliothek.
/// Das Bild hat genau 1 Pixel pro Modul inklusive 4 Module weißem Ruhebereich (Quiet Zone) ringsum und wird
/// beim Zeichnen nur mit „nächster Nachbar“ vergrößert → scharfe Module.
enum QRCode {
    static let quietZone = 4

    struct Code {
        let image: CGImage      // 1 px = 1 Modul, inkl. Ruhebereich
        let modules: Int        // Kantenlänge in Modulen inkl. Ruhebereich
    }

    private static var cache: [String: Code] = [:]

    /// Fehlerkorrektur „M“ (15 %) – für die Projekt-URL ergibt das Version 4 (33 × 33 Module).
    static func make(_ text: String, correction: String = "M") -> Code? {
        let key = correction + text
        if let c = cache[key] { return c }
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue(correction, forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        // CoreImage liefert 1 px pro Modul mit 1 Modul Rand → Symbol ausschneiden und eigenen Ruhebereich setzen
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        let ext = out.extent.integral
        guard let raw = ctx.createCGImage(out, from: ext) else { return nil }
        let symbol = Int(ext.width) - 2
        let n = symbol + 2 * quietZone
        guard symbol > 0, let bmp = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bmp.interpolationQuality = .none
        bmp.setFillColor(gray: 1, alpha: 1)
        bmp.fill(CGRect(x: 0, y: 0, width: n, height: n))
        // raw hat 1 Modul Rand; so platzieren, dass das Symbol bei quietZone…quietZone+symbol liegt
        bmp.draw(raw, in: CGRect(x: quietZone - 1, y: quietZone - 1, width: symbol + 2, height: symbol + 2))
        guard let img = bmp.makeImage() else { return nil }
        let c = Code(image: img, modules: n)
        cache[key] = c
        return c
    }

    /// QR-Codes in einem Bild lesen (CIDetector) – für Tests der gezeichneten Ruhebilder.
    static func decode(_ image: CGImage) -> [String] {
        let ci = CIImage(cgImage: image)
        let det = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
                             options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (det?.features(in: ci) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}

/// Zeichnet einen QR-Code pixelgenau: Kantenlänge immer ein ganzzahliges Vielfaches der Modulzahl (in Pixeln),
/// Interpolation aus. Zeichnet in draw(_:) (nicht als Layer-Inhalt), damit Vorschaubilder (cacheDisplay) ihn enthalten.
final class QRCodeView: NSView {
    var code: QRCode.Code? { didSet { needsDisplay = true } }
    /// Ecken des weißen Felds leicht abrunden (in Modulen; < Ruhebereich, damit der Code unberührt bleibt)
    var cornerModules: CGFloat = 1.5

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// Größte Kantenlänge ≤ `target` pt, die ganze Pixel pro Modul ergibt (mind. 2 px pro Modul).
    static func snappedSide(target: CGFloat, modules: Int, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        let perModule = max(2, (target * s / CGFloat(modules)).rounded())
        return perModule * CGFloat(modules) / s
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let code, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        let m = r.width / CGFloat(code.modules)
        ctx.saveGState()
        ctx.interpolationQuality = .none          // Module scharf (nächster Nachbar); Ecken-Clip bleibt geglättet
        let radius = min(m * cornerModules, m * CGFloat(QRCode.quietZone) * 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(code.image, in: r)
        ctx.restoreGState()
    }
}
