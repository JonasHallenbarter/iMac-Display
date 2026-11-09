import AppKit
import QuartzCore

// Sharpness / motion test picture shown full screen on the virtual display (--demo-window or menu).
// Static part (text, 1-px patterns, gradients) is drawn once by DemoView; the animated part
// (tickers, moving boxes, frame counter) lives in a layer-hosting AnimationView driven by the
// display link of the screen it is on (macOS 14+) or a 60 Hz timer.

// MARK: - Window controller

@MainActor
final class DemoWindowController {
    let displayID: CGDirectDisplayID
    /// Called when the user closes the window (Esc / double click).
    var onUserClose: (() -> Void)?

    private var window: DemoWindow?
    private var screenObserver: NSObjectProtocol?
    private var retryTimer: Timer?
    private var waitStarted: Date?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    func show() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            }
        }
        guard let screen = Self.screen(for: displayID) else {
            // A freshly created virtual display shows up in NSScreen.screens a little later.
            if waitStarted == nil { waitStarted = Date() }
            if retryTimer == nil {
                let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.retry() }
                }
                RunLoop.main.add(t, forMode: .common)
                retryTimer = t
            }
            return
        }
        retryTimer?.invalidate(); retryTimer = nil; waitStarted = nil
        if let w = window {
            place(w, on: screen)
            w.orderFrontRegardless()
            return
        }
        let w = DemoWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                           backing: .buffered, defer: false, screen: screen)
        w.isReleasedWhenClosed = false
        w.level = .statusBar               // above normal windows and the menu bar of that display
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isOpaque = true
        w.backgroundColor = .white
        w.hasShadow = false
        w.title = "iMac Display – Testbild"
        let view = DemoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onClose = { [weak self] in self?.userClosed() }
        w.contentView = view
        w.onClose = { [weak self] in self?.userClosed() }
        place(w, on: screen)
        w.orderFrontRegardless()
        window = w
        logLine("Testbild-Fenster auf Display \(displayID) geöffnet: \(NSStringFromRect(w.frame)), Skalierung \(w.backingScaleFactor)x")
    }

    func close() {
        retryTimer?.invalidate(); retryTimer = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        if let w = window {
            (w.contentView as? DemoView)?.stopAnimation()
            w.orderOut(nil)
            w.close()
            logLine("Testbild-Fenster geschlossen")
        }
        window = nil
    }

    private func retry() {
        if let s = waitStarted, Date().timeIntervalSince(s) > 10 {
            logLine("Testbild: Bildschirm für Display \(displayID) nicht gefunden")
            retryTimer?.invalidate(); retryTimer = nil; waitStarted = nil
            return
        }
        if Self.screen(for: displayID) != nil { show() }
    }

    private func screensChanged() {
        guard let screen = Self.screen(for: displayID) else { return }
        if let w = window { place(w, on: screen) } else { show() }
    }

    private func place(_ w: NSWindow, on screen: NSScreen) {
        if w.frame != screen.frame { w.setFrame(screen.frame, display: true) }
    }

    private func userClosed() {
        close()
        onUserClose?()
    }
}

final class DemoWindow: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }
}

// MARK: - Static content

final class DemoView: NSView {
    var onClose: (() -> Void)?
    private let anim: AnimationView
    private var patterns: [(String, CGImage)] = []
    private var patternScale: CGFloat = 0

    static let sample = "Franz jagt im komplett verwahrlosten Taxi quer durch Bayern. 0123456789 äöüß ÄÖÜ €@#&%"

    override init(frame: NSRect) {
        let animFrame = NSRect(x: 40, y: 830, width: max(200, frame.width - 80), height: max(100, frame.height - 830 - 20))
        anim = AnimationView(frame: animFrame)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(anim)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onClose?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    func stopAnimation() { anim.stop() }

    // MARK: drawing helpers

    private func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor) {
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
    }

    private func fill(_ r: NSRect, _ c: NSColor) {
        c.setFill()
        r.fill()
    }

    private func label(_ s: String, _ x: CGFloat, _ y: CGFloat, dark: Bool = false) {
        text(s, x, y, .systemFont(ofSize: 11, weight: .medium), dark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.35, alpha: 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? ctx.userSpaceToDeviceSpaceTransform.a
        fill(bounds, .white)

        // Header
        text("iMac Display – Testbild für Schärfe und Bewegung", 40, 22, .systemFont(ofSize: 28, weight: .semibold), .black)
        let info = String(format: "Fenster %.0f×%.0f pt · %.0fx → %.0f×%.0f px · Doppelklick oder Esc schließt das Testbild",
                          bounds.width, bounds.height, scale, bounds.width * scale, bounds.height * scale)
        text(info, 40, 62, .systemFont(ofSize: 13), NSColor(white: 0.3, alpha: 1))

        let sizes: [CGFloat] = [9, 10, 11, 12, 13, 14]

        // 1) Black on white
        var p = NSRect(x: 40, y: 96, width: 960, height: 214)
        fill(p, .white)
        NSColor(white: 0.8, alpha: 1).setStroke(); NSBezierPath(rect: p.insetBy(dx: 0.25, dy: 0.25)).stroke()
        label("Schwarz auf Weiß", p.minX + 12, p.minY + 8)
        var y = p.minY + 28
        for s in sizes {
            text("\(Int(s)) pt  " + Self.sample, p.minX + 12, y, .systemFont(ofSize: s), .black)
            y += s * 1.55
        }
        text("Menlo 11:  il1| O0o {}[]() => != <= -> 0x7F; // Code-Zeile", p.minX + 12, y + 2,
             NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular), .black)
        text("Georgia 12: Serifenschrift mit feinen Haarlinien – Hamburgefonstiv", p.minX + 480, y + 2,
             NSFont(name: "Georgia", size: 12) ?? .systemFont(ofSize: 12), .black)
        text("Grau 11 pt: sekundärer Text, wie in Seitenleisten und Statuszeilen", p.minX + 12, y + 22,
             .systemFont(ofSize: 11), NSColor(white: 0.45, alpha: 1))

        // 2) White on dark
        p = NSRect(x: 40, y: 320, width: 960, height: 214)
        fill(p, NSColor(calibratedWhite: 0.118, alpha: 1))
        label("Weiß auf Dunkel", p.minX + 12, p.minY + 8, dark: true)
        y = p.minY + 28
        for s in sizes {
            text("\(Int(s)) pt  " + Self.sample, p.minX + 12, y, .systemFont(ofSize: s), .white)
            y += s * 1.55
        }
        text("Menlo 11:  il1| O0o {}[]() => != <= -> 0x7F; // Code-Zeile", p.minX + 12, y + 2,
             NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular), .white)
        text("Grau 11 pt: sekundärer Text auf dunklem Grund", p.minX + 480, y + 2,
             .systemFont(ofSize: 11), NSColor(white: 0.6, alpha: 1))

        // 3) Colored text
        p = NSRect(x: 40, y: 544, width: 960, height: 270)
        let half = p.width / 2
        fill(NSRect(x: p.minX, y: p.minY, width: half, height: p.height), .white)
        fill(NSRect(x: p.minX + half, y: p.minY, width: half, height: p.height), NSColor(calibratedWhite: 0.118, alpha: 1))
        NSColor(white: 0.8, alpha: 1).setStroke(); NSBezierPath(rect: p.insetBy(dx: 0.25, dy: 0.25)).stroke()
        label("Farbiger Text", p.minX + 12, p.minY + 8)
        label("Farbiger Text auf Dunkel", p.minX + half + 12, p.minY + 8, dark: true)
        let light: [(String, NSColor)] = [("Rot", .systemRed), ("Grün", .systemGreen), ("Blau", .systemBlue),
                                          ("Orange", .systemOrange), ("Lila", .systemPurple), ("Türkis", .systemTeal)]
        let dark: [(String, NSColor)] = [("Gelb", .systemYellow), ("Cyan", .cyan), ("Magenta", .magenta),
                                         ("Hellgrün", NSColor(calibratedRed: 0.5, green: 1, blue: 0.4, alpha: 1)),
                                         ("Orange", .systemOrange), ("Rosa", .systemPink)]
        y = p.minY + 28
        for (i, (n, c)) in light.enumerated() {
            let s: CGFloat = [11, 12, 13][i % 3]
            text("\(n) \(Int(s)) pt – Schnelle Füchse springen über faule Hunde 12345", p.minX + 12, y, .systemFont(ofSize: s), c)
            text("\(dark[i].0) \(Int(s)) pt – Schnelle Füchse springen über faule Hunde 12345", p.minX + half + 12, y,
                 .systemFont(ofSize: s), dark[i].1)
            y += 22
        }
        y += 6
        let worst: [(String, NSColor, NSColor)] = [("Rot auf Blau", .red, .blue), ("Blau auf Rot", .blue, .red),
                                                   ("Grün auf Magenta", .green, .magenta), ("Gelb auf Weiß", .systemYellow, .white)]
        var x = p.minX + 12
        for (n, fg, bg) in worst {
            let r = NSRect(x: x, y: y, width: 222, height: 34)
            fill(r, bg)
            text("\(n) 12 pt (4:2:0)", r.minX + 8, r.minY + 9, .systemFont(ofSize: 12, weight: .medium), fg)
            x += 234
        }
        y += 44
        text("Farbsäume an „Rot auf Blau“ sind bei H.264 4:2:0 normal; schwarzer/weißer Text muss randscharf sein.",
             p.minX + 12, y, .systemFont(ofSize: 11), NSColor(white: 0.35, alpha: 1))

        // 4) 1-px patterns (exact device pixels)
        if patterns.isEmpty || patternScale != scale {
            patterns = Self.makePatterns(tile: CGSize(width: 180, height: 120), scale: scale)
            patternScale = scale
        }
        let px0: CGFloat = 1040, py0: CGFloat = 96
        ctx.saveGState()
        ctx.interpolationQuality = .none
        for (i, (name, img)) in patterns.enumerated() {
            let col = CGFloat(i % 5), row = CGFloat(i / 5)
            let r = NSRect(x: px0 + col * 197, y: py0 + row * 150, width: 180, height: 120)
            NSImage(cgImage: img, size: r.size).draw(in: r, from: .zero, operation: .copy, fraction: 1,
                                                     respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
            label(name, r.minX, r.maxY + 5)
        }
        ctx.restoreGState()

        // 5) Gradients
        let gx: CGFloat = 1040, gw: CGFloat = 968
        label("Farbverlauf (Farbton)", gx, 400)
        let hue = NSGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            NSColor(calibratedHue: $0, saturation: 1, brightness: 1, alpha: 1)
        })!
        hue.draw(in: NSRect(x: gx, y: 416, width: gw, height: 44), angle: 0)
        label("Grauverlauf (Banding?)", gx, 466)
        NSGradient(starting: .black, ending: .white)!.draw(in: NSRect(x: gx, y: 482, width: gw, height: 44), angle: 0)
        label("32 Graustufen", gx, 532)
        for i in 0..<32 {
            fill(NSRect(x: gx + CGFloat(i) * gw / 32, y: 548, width: ceil(gw / 32), height: 30),
                 NSColor(calibratedWhite: CGFloat(i) / 31, alpha: 1))
        }
        label("Rot / Grün / Blau", gx, 584)
        for (i, c) in [NSColor.red, .green, .blue].enumerated() {
            NSGradient(starting: .black, ending: c)!.draw(in: NSRect(x: gx, y: 600 + CGFloat(i) * 22, width: gw, height: 20), angle: 0)
        }

        // 6) Hints
        let hy: CGFloat = 676
        fill(NSRect(x: gx, y: hy, width: gw, height: 138), NSColor(calibratedWhite: 0.95, alpha: 1))
        label("So prüfen", gx + 12, hy + 8)
        let hints = [
            "• Die 1-px-Muster müssen auf dem iMac als feine, gleichmäßige Muster erscheinen – nicht grau, verschwommen oder mit Moiré.",
            "• 9-pt-Text soll ohne Unschärfe lesbar sein (Chrome-Zoom 100 %, Display „Standard“ 2048×1152).",
            "• Unten: Laufschriften und Kästen sollen gleichmäßig laufen; im Streifen leuchtet je Bild ein Feld weiter.",
            "• Bleibt ein Feld hängen oder springt der Zähler, gingen Bilder verloren (Aufnahme, Netz oder Decoder).",
            "• Auf dem iMac zeigt Taste „s“ die Statistik (fps, Decoder-Warteschlange, verworfene Bilder).",
        ]
        for (i, h) in hints.enumerated() {
            text(h, gx + 12, hy + 28 + CGFloat(i) * 21, .systemFont(ofSize: 12), NSColor(white: 0.15, alpha: 1))
        }
    }

    // MARK: pattern bitmaps

    private static func makePatterns(tile: CGSize, scale: CGFloat) -> [(String, CGImage)] {
        let w = Int(tile.width * scale), h = Int(tile.height * scale)
        typealias RGB = (UInt8, UInt8, UInt8)
        let bk: RGB = (0, 0, 0), wh: RGB = (255, 255, 255)
        func img(_ f: (Int, Int) -> RGB) -> CGImage { patternImage(w: w, h: h, f) }
        let R = Double(w * w + h * h).squareRoot() / 2
        return [
            ("1-px-Schachbrett", img { x, y in (x + y) % 2 == 0 ? bk : wh }),
            ("1-px-Linien senkrecht", img { x, _ in x % 2 == 0 ? bk : wh }),
            ("1-px-Linien waagerecht", img { _, y in y % 2 == 0 ? bk : wh }),
            ("2-px-Schachbrett", img { x, y in (x / 2 + y / 2) % 2 == 0 ? bk : wh }),
            ("1-px Rot/Blau senkrecht", img { x, _ in x % 2 == 0 ? (255, 0, 0) : (0, 0, 255) }),
            ("1-px Grün/Magenta waagerecht", img { _, y in y % 2 == 0 ? (0, 255, 0) : (255, 0, 255) }),
            ("1-px-Diagonalen", img { x, y in (x + y) % 4 == 0 ? bk : wh }),
            ("1-px-Gitter (alle 4 px)", img { x, y in (x % 4 == 0 || y % 4 == 0) ? bk : wh }),
            ("Zonenplatte (Aliasing)", img { x, y in
                let dx = Double(x - w / 2), dy = Double(y - h / 2)
                let v = UInt8(127.5 + 127.5 * cos(Double.pi * (dx * dx + dy * dy) / (2 * R)))
                return (v, v, v)
            }),
            ("Graue 1-px-Linien 25/75 %", img { x, _ in x % 2 == 0 ? (64, 64, 64) : (191, 191, 191) }),
        ]
    }

    private static func patternImage(w: Int, h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = f(x, y)
                let i = (y * w + x) * 4
                data[i] = r; data[i + 1] = g; data[i + 2] = b
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // MARK: snapshot (development: --demo-snapshot <png>)

    @MainActor
    static func writeSnapshot(to path: String, pointSize: CGSize, scale: CGFloat) -> Bool {
        let v = DemoView(frame: NSRect(origin: .zero, size: pointSize))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pointSize.width * scale),
                                         pixelsHigh: Int(pointSize.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = pointSize
        v.anim.step(time: CACurrentMediaTime() + 1.234)
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

// MARK: - Animated content

final class AnimationView: NSView {
    private let root = CALayer()
    private var tickers: [(layer: CATextLayer, period: CGFloat, speed: CGFloat, y: CGFloat)] = []
    private let box1 = CALayer()
    private let box2 = CALayer()
    private let counter = CATextLayer()
    private var cells: [CALayer] = []
    private let vscroll = CATextLayer()
    private var vscrollPeriod: CGFloat = 1
    private let vscrollClip = CALayer()

    private var frame0: CFTimeInterval = 0
    private var frameNo = 0
    private var hzWindow: [CFTimeInterval] = []
    private var timer: Timer?
    private var link: AnyObject?

    private let tickerWidth: CGFloat
    private var scale: CGFloat = 2

    override init(frame: NSRect) {
        tickerWidth = max(200, frame.width - 520)
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.10, alpha: 1).cgColor
        layer = root            // layer-hosting: we own the tree
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func textLayer(_ s: String, font: NSFont, color: NSColor, bg: NSColor? = nil) -> (CATextLayer, CGFloat) {
        let t = CATextLayer()
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        t.string = attr
        t.contentsScale = scale
        t.isWrapped = false
        t.frame = CGRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
        if let bg { t.backgroundColor = bg.cgColor }
        t.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "frame": NSNull()]
        return (t, size.width)
    }

    private func build() {
        let label = { (s: String, x: CGFloat, y: CGFloat) in
            let (t, _) = self.textLayer(s, font: .systemFont(ofSize: 11, weight: .medium), color: NSColor(white: 0.7, alpha: 1))
            t.frame.origin = CGPoint(x: x, y: y)
            self.root.addSublayer(t)
        }
        label("Bewegung (\(Int(tickerWidth)) pt breit) – Laufschriften 240 / 120 / 60 pt/s, Kästen 800 pt/s", 12, 6)

        // Tickers in a clipping container
        let clip = CALayer()
        clip.frame = CGRect(x: 12, y: 24, width: tickerWidth, height: 112)
        clip.masksToBounds = true
        root.addSublayer(clip)
        let specs: [(String, CGFloat, NSColor, NSColor?, CGFloat, CGFloat)] = [
            ("+++ Laufschrift 24 pt – läuft sie gleichmäßig ohne Ruckeln? +++ iMac Display · 60 Hz · ", 24, .white, nil, 240, 0),
            ("Kleine Laufschrift 13 pt auf Dunkel – Ränder sollen auch in Bewegung sauber bleiben · 0123456789 · ", 13, NSColor(white: 0.85, alpha: 1), nil, 120, 42),
            ("Langsamer schwarzer Text auf Weiß, 13 pt, 60 pt/s – hier fällt Ruckeln am stärksten auf · äöü ÄÖÜ ß · ", 13, .black, .white, 60, 74),
        ]
        for (s, size, fg, bg, speed, y) in specs {
            let font = NSFont.systemFont(ofSize: size, weight: size > 20 ? .semibold : .regular)
            var unit = s
            while (unit as NSString).size(withAttributes: [.font: font]).width < tickerWidth + 50 { unit += s }
            let w1 = (unit as NSString).size(withAttributes: [.font: font]).width
            let (t, _) = textLayer(unit + unit, font: font, color: fg, bg: bg)
            t.frame.origin.y = y
            clip.addSublayer(t)
            tickers.append((t, w1, speed, y))
        }

        // Moving boxes
        let track = CALayer()
        track.frame = CGRect(x: 12, y: 146, width: tickerWidth, height: 84)
        track.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        track.masksToBounds = true
        root.addSublayer(track)
        for (b, c) in [(box1, NSColor.systemOrange), (box2, NSColor.systemBlue)] {
            b.frame = CGRect(x: 0, y: 2, width: 80, height: 80)
            b.backgroundColor = c.cgColor
            b.borderColor = NSColor.white.cgColor
            b.borderWidth = 2
            b.actions = ["position": NSNull(), "bounds": NSNull()]
            track.addSublayer(b)
        }
        box2.frame = CGRect(x: 0, y: 22, width: 40, height: 40)
        box2.cornerRadius = 20

        // Frame counter + 60-cell strip
        let (c, _) = textLayer("Frame 0000000 · 60.0 Hz · 00:00:00.000", font: .monospacedDigitSystemFont(ofSize: 26, weight: .medium),
                               color: .white)
        counter.string = c.string
        counter.contentsScale = scale
        counter.frame = CGRect(x: 12, y: 238, width: 640, height: 34)
        counter.actions = ["contents": NSNull()]
        root.addSublayer(counter)
        for i in 0..<60 {
            let l = CALayer()
            l.frame = CGRect(x: 670 + CGFloat(i) * 12, y: 244, width: 10, height: 24)
            l.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
            l.actions = ["backgroundColor": NSNull()]
            root.addSublayer(l)
            cells.append(l)
        }

        // Vertical scroll column on the right
        let vx = 12 + tickerWidth + 20
        vscrollClip.frame = CGRect(x: vx, y: 24, width: max(100, bounds.width - vx - 12), height: max(50, bounds.height - 36))
        vscrollClip.masksToBounds = true
        vscrollClip.backgroundColor = NSColor.white.cgColor
        root.addSublayer(vscrollClip)
        label("Vertikales Scrollen 60 pt/s", vx, 6)
        let lines = (1...24).map { "Zeile \($0): Text scrollt wie in einem Browser- oder Editorfenster." }
        let font = NSFont.systemFont(ofSize: 12)
        let unit = lines.joined(separator: "\n")
        let attr = NSMutableAttributedString(string: unit + "\n" + unit,
                                             attributes: [.font: font, .foregroundColor: NSColor.black])
        let para = NSMutableParagraphStyle(); para.minimumLineHeight = 20; para.maximumLineHeight = 20
        attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
        vscroll.string = attr
        vscroll.contentsScale = scale
        vscroll.isWrapped = false
        vscrollPeriod = CGFloat(lines.count) * 20
        vscroll.frame = CGRect(x: 10, y: 0, width: vscrollClip.bounds.width - 20, height: vscrollPeriod * 2)
        vscroll.actions = ["position": NSNull(), "bounds": NSNull()]
        vscrollClip.addSublayer(vscroll)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop(); return }
        let s = window?.backingScaleFactor ?? 2
        if s != scale {
            scale = s
            for l in [counter, vscroll] + tickers.map({ $0.layer }) { l.contentsScale = s }
        }
        start()
    }

    func start() {
        guard timer == nil && link == nil else { return }
        frame0 = CACurrentMediaTime()
        frameNo = 0
        if #available(macOS 14.0, *) {
            let l = displayLink(target: self, selector: #selector(linkFired(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step(time: CACurrentMediaTime()) }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
    }

    @available(macOS 14.0, *)
    @objc private func linkFired(_ l: CADisplayLink) {
        step(time: l.targetTimestamp)
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    func step(time: CFTimeInterval) {
        let t = CGFloat(time - frame0)
        frameNo += 1
        hzWindow.append(time)
        while let f = hzWindow.first, time - f > 1.0 { hzWindow.removeFirst() }
        let hz = hzWindow.count > 1 ? Double(hzWindow.count - 1) / (hzWindow.last! - hzWindow.first!) : 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tk in tickers {
            let off = (t * tk.speed).truncatingRemainder(dividingBy: tk.period)
            tk.layer.frame.origin = CGPoint(x: snap(-off), y: tk.y)
        }
        let travel = max(1, tickerWidth - 80)
        let ph = (t * 800).truncatingRemainder(dividingBy: travel * 2)
        box1.frame.origin.x = snap(ph < travel ? ph : 2 * travel - ph)
        box2.frame.origin.x = snap((travel + 40) / 2 + sin(t * 2 * .pi / 3) * (travel - 40) / 2)
        vscroll.frame.origin.y = snap(-(t * 60).truncatingRemainder(dividingBy: vscrollPeriod))

        let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
        counter.string = NSAttributedString(
            string: String(format: "Frame %07d · %4.1f Hz · %@", frameNo, hz, df.string(from: Date())),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.white])
        let cur = frameNo % 60
        cells[(cur + 59) % 60].backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        cells[cur].backgroundColor = NSColor.systemGreen.cgColor
        CATransaction.commit()
    }
}
