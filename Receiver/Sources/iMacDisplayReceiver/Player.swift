import AppKit
import CoreMedia
import QuartzCore

/// Zustand des Bildes für die Checkliste.
enum PictureInfo: Equatable {
    case off
    case waiting(connected: Bool)
    case standby                 // v2: MacBook verbunden, aber dort noch nicht auf „Verbinden“ geklickt
    case playing(fps: Double, width: Int, height: Int, hardware: Bool?)
    case failing(String)
}

struct StreamConfig: Equatable {
    var codec: String
    var width: Int
    var height: Int
    var fps: Double?
}

/// Der native Player: Vollbildfenster, WebSocket, H.264 → Anzeige, Ruhebild „Aktuell kein aktiver Monitor“
/// mit QR-Code und „Jetzt verbinden“. Protokoll v2 (docs/PROTOCOL.md): Steuer-Nachrichten `status` (Bereitschaft/aktiv,
/// alle 2 s = Lebenszeichen) und `brightness` (Helligkeit des iMac setzen); meldet `hello` und die Helligkeit zurück.
final class PlayerController: NSObject {
    static let idleAfter = 3.0          // so lange kein neues Bild → Ruhebild
    static let keyframeWait = 1.2       // so lange auf einen Keyframe gewartet → anfordern
    static let quietRefresh = 4.0       // gar keine Nachricht → Keyframe anfordern
    static let statsEvery = 5.0
    static let shiftEvery = Double(Config.env["IMAC_RECEIVER_SHIFT_SECONDS"] ?? "") ?? 60   // Einbrennschutz
    static let brightnessPoll = 2.0     // Helligkeit abfragen (iMac-Tasten) und bei Änderung melden
    /// Test: Helligkeit nicht wirklich setzen, nur protokollieren (IMAC_RECEIVER_TEST_BRIGHTNESS=log)
    static let brightnessLogOnly = Config.env["IMAC_RECEIVER_TEST_BRIGHTNESS"] == "log"

    struct Stats {
        var framesIn = 0, bytesIn = 0, enqueued = 0, shown = 0, skipped = 0, keyReqs = 0, errors = 0
        var idleSwitches = 0, formatChanges = 0, recoveries = 0
        var fps = 0.0, mbps = 0.0
        var wStart = CACurrentMediaTime(), wFrames = 0, wBytes = 0
        var latency = LatencyStats()      // Empfang → angezeigt (VT-Renderer bzw. Testprüfung)
    }

    let host: String
    let hostLabel: String
    let renderer: VideoRenderer
    private let client: StreamClient
    private let depack = H264Depacketizer()          // nur auf client.queue
    private(set) var window: PlayerWindow?
    private var root: PlayerRootView?
    private var timers: [Timer] = []
    private var observers: [NSObjectProtocol] = []
    private var active = false
    private var startedAt = 0.0
    let fullScreen: Bool
    private let testWindowSize: NSSize?

    private(set) var connected = false
    private(set) var showingVideo = false
    private(set) var waitingKey = true
    private var waitingSince = CACurrentMediaTime()
    private var lastKeyReq = -100.0
    private var lastFrameAt = 0.0
    private var keyEnqueuedAt = 0.0
    private var failStreak = 0                       // Fehler in Folge ohne ein bestätigtes Bild dazwischen
    static let confirmAfter = 0.25                   // Layer: so lange nach dem Keyframe ohne Fehler → Bild gilt als ok
    private(set) var config: StreamConfig?
    private(set) var videoSize: (w: Int, h: Int) = (0, 0)
    private(set) var lastError: String?
    private var lastErrorAt = -100.0
    private var lastErrorLogAt = -100.0
    private var suppressedErrorLogs = 0
    private var cursorHidden = false
    private var loggedUnreachable = false
    private var lastPlayLog = 0.0
    private(set) var stats = Stats()
    private var recvTimes: [Int64: Double] = [:]
    private let corruptEvery = Int(Config.env["IMAC_RECEIVER_TEST_CORRUPT"] ?? "") ?? 0
    private var corruptCounter = 0                    // nur auf client.queue
    var verifier: AnyObject?                          // Testprüfung (TestHooks.swift)

    // Protokoll v2: Zustand des MacBooks (nil = unbekannt, z. B. alter Server ohne `status`)
    private(set) var serverActive: Bool?
    private(set) var serverAutoReconnect: Bool?
    private(set) var statusCount = 0
    private var lastStatusAt = 0.0
    // Helligkeit
    private var reportedBrightness: (supported: Bool, value: Float?)?
    private var lastSetBrightness: Float?
    private var brightnessReportScheduled = false
    private(set) var brightnessSets = 0
    private(set) var brightnessReports = 0
    private(set) var lastBrightnessReport = ""
    private var lastBrightnessLogAt = -100.0
    private var suppressedBrightnessLogs = 0
    // Countdown „Automatisch ausschalten“ (nil = keiner)
    private(set) var countdownText: String = ""

    /// Cmd+Q / Menü im Player (wird vom App-Delegate über das Hauptmenü ausgelöst)
    var onUserQuit: (() -> Void)?

    init(host: String) {
        self.host = host
        hostLabel = host.hasSuffix(":8080") ? String(host.dropLast(5)) : host
        client = StreamClient(url: URL(string: "ws://\(host)/ws")!)
        let r = (Config.env["IMAC_RECEIVER_RENDERER"] ?? UserDefaults.standard.string(forKey: "renderer"))?.lowercased()
        renderer = r == "vt" ? VTRenderer() : LayerRenderer()
        if let s = Config.env["IMAC_RECEIVER_WINDOW"] {
            let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
            testWindowSize = p.count == 2 ? NSSize(width: p[0], height: p[1]) : NSSize(width: 1024, height: 576)
        } else {
            testWindowSize = nil
        }
        fullScreen = testWindowSize == nil
        super.init()
    }

    // MARK: Start / Stopp

    func start() {
        guard !active else { return }
        active = true
        startedAt = CACurrentMediaTime()
        buildWindow()
        renderer.onFailure = { [weak self] why in self?.recover(why) }
        renderer.onShown = { [weak self] pts in self?.frameShown(pts: pts) }
        client.onEvent = { [weak self] ev in self?.clientEvent(ev) }
        client.start()
        installVerifierIfRequested(self)
        timers.append(timer(0.25) { $0.tick() })
        timers.append(timer(0.5) { $0.updateStatsOverlay() })
        timers.append(timer(1.0) { $0.updateWindowStats() })
        timers.append(timer(Self.statsEvery) { $0.sendStats() })
        timers.append(timer(Self.shiftEvery) { $0.root?.shiftIdleText(animated: true) })
        timers.append(timer(Self.brightnessPoll) { $0.reportBrightness(force: false) })
        Log.write("Monitor-Modus: Player gestartet – \(fullScreen ? "Vollbild" : "Testfenster") , Ziel ws://\(host)/ws, Renderer \(renderer.name)")
    }

    func stop() {
        guard active else { return }
        active = false
        timers.forEach { $0.invalidate() }
        timers = []
        client.onEvent = nil
        client.stop()
        (verifier as? StoppableHook)?.stopHook()
        verifier = nil
        renderer.flush(removeImage: true)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        setCursorHidden(false)
        if fullScreen { NSApp.presentationOptions = [] }
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        root = nil
        Log.write("Monitor-Modus: Player beendet (\(stats.shown) Bilder, \(stats.errors) Fehler, \(stats.keyReqs) Keyframe-Anfragen)")
    }

    private func timer(_ interval: TimeInterval, _ body: @escaping (PlayerController) -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in if let self { body(self) } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    // MARK: Fenster

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let s = Config.env["IMAC_RECEIVER_SCREEN"], let i = Int(s), i >= 0, i < screens.count { return screens[i] }
        return screens.first          // Bildschirm mit der Menüleiste
    }

    private func windowFrame(_ screen: NSScreen) -> NSRect {
        guard let size = testWindowSize else { return screen.frame }
        let f = screen.frame
        return NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    private func buildWindow() {
        let screen = targetScreen()
        let frame = screen.map(windowFrame) ?? NSRect(x: 0, y: 0, width: 1024, height: 576)
        let w = PlayerWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.title = "iMac Display – Bild"
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenNone]
        w.acceptsMouseMovedEvents = false
        let v = PlayerRootView(frame: NSRect(origin: .zero, size: frame.size), videoLayer: renderer.layer,
                               hideCursor: fullScreen)
        v.hostLabel = hostLabel
        v.onKey = { [weak self] e in self?.key(e) }
        v.onGeometryChange = { [weak self] in self?.geometryChanged() }
        w.contentView = v
        w.setFrame(frame, display: false)
        root = v
        window = w
        updateIdleText()
        if fullScreen { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refit()
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.updateCursor() })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateCursor()
                if NSApp.isActive { self?.requestKeyframe(force: false) }
            })
        }
        updateCursor()
        geometryChanged()
    }

    /// Bildschirm geändert (Auflösung, angeschlossen/abgezogen) → Fenster wieder genau auf den Bildschirm
    private func refit() {
        guard let w = window, let s = targetScreen() else { return }
        let f = windowFrame(s)
        if w.frame != f {
            w.setFrame(f, display: true)
            Log.write("Bildschirm geändert – Fenster neu: \(Int(f.width))×\(Int(f.height)) pt @\(s.backingScaleFactor)x")
        }
        geometryChanged()
    }

    /// Wird das Bild 1:1 (ein Videopixel = ein Bildschirmpixel) gezeigt?
    var geometry: (pt: NSSize, scale: CGFloat, px: NSSize, exact: Bool) {
        let size = root?.bounds.size ?? .zero
        let scale = window?.backingScaleFactor ?? 1
        let px = NSSize(width: size.width * scale, height: size.height * scale)
        let exact = videoSize.w > 0 && Int(px.width.rounded()) == videoSize.w && Int(px.height.rounded()) == videoSize.h
        return (size, scale, px, exact)
    }

    private func geometryChanged() {
        renderer.setExactPixelMapping(geometry.exact)
    }

    /// Player-Fenster ist auf dem Bildschirm (für den Countdown)
    var isVisible: Bool { window?.isVisible == true && window?.isMiniaturized == false }

    /// Countdown „Automatisch ausschalten“ im Player zeigen (nil = ausblenden)
    func setCountdown(remaining: Int?, fraction: Double) {
        root?.setCountdown(remaining: remaining, fraction: fraction)
        countdownText = remaining.map { AutoShutdown.message($0) } ?? ""
    }

    func bringToFront() {
        guard let w = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func updateCursor() {
        guard let w = window else { return }
        setCursorHidden(fullScreen && w.isKeyWindow && NSApp.isActive)
    }

    private func setCursorHidden(_ hide: Bool) {
        if hide && !cursorHidden { NSCursor.hide(); cursorHidden = true }
        else if !hide && cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    private func key(_ e: NSEvent) {
        // Esc und alle anderen Tasten: nichts (kein versehentliches Beenden). Cmd+Q läuft über das Hauptmenü.
        if e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           e.charactersIgnoringModifiers?.lowercased() == "s" {
            root?.statsVisible.toggle()
            updateStatsOverlay()
        }
    }

    // MARK: Netzwerk-Ereignisse

    private func clientEvent(_ ev: StreamClient.Event) {
        // läuft auf client.queue
        switch ev {
        case .video(var data, let offset, let key, let ts, let recv):
            if corruptEvery > 0 { corruptCounter += 1; if corruptCounter % corruptEvery == 0 { data = Self.corrupt(data, offset, corruptCounter) } }
            let bytes = data.count - offset
            do {
                let out = try depack.process(data, offset: offset, timestampUs: ts)
                DispatchQueue.main.async { [weak self] in self?.handleSample(out, flagKey: key, bytes: bytes, recv: recv) }
            } catch {
                let why = "\(error)"
                DispatchQueue.main.async { [weak self] in self?.handleBadData(why, bytes: bytes) }
            }
        case .config(let d):
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            DispatchQueue.main.async { [weak self] in self?.handleConfig(j) }
        case .opened:
            DispatchQueue.main.async { [weak self] in self?.opened() }
        case .closed(let why):
            DispatchQueue.main.async { [weak self] in self?.closed(why) }
        case .control(let j):
            DispatchQueue.main.async { [weak self] in self?.handleControl(j) }
        }
    }

    /// Test (IMAC_RECEIVER_TEST_CORRUPT=n): jede n-te Nachricht beschädigen
    private static func corrupt(_ d: Data, _ offset: Int, _ n: Int) -> Data {
        var m = d
        let len = m.count - offset
        guard len > 16 else { return m }
        if n % 3 == 0 { return m.prefix(offset + len / 2) }          // abgeschnitten
        for _ in 0..<24 { let i = offset + Int.random(in: 8..<len); m[m.startIndex + i] ^= UInt8.random(in: 1...255) }
        return m
    }

    private func opened() {
        guard active else { return }
        connected = true
        loggedUnreachable = false
        Log.write("Verbunden mit MacBook ws://\(host)/ws")
        serverActive = nil; serverAutoReconnect = nil
        setWaiting()
        waitingSince = CACurrentMediaTime()          // neuer Client bekommt ohnehin gleich einen Keyframe
        sendJSON(["type": "hello", "app": "receiver", "version": Config.version])
        reportedBrightness = nil
        reportBrightness(force: true)
        updateIdleText()
    }

    private func closed(_ why: String) {
        guard active else { return }
        let was = connected
        connected = false
        serverActive = nil; serverAutoReconnect = nil
        if was { Log.write("Verbindung zum MacBook getrennt: \(why)") }
        else if !loggedUnreachable { loggedUnreachable = true; Log.write("MacBook \(host) nicht erreichbar (\(why)) – versuche es alle 1–2 s weiter") }
        setWaiting()
        if showingVideo { enterIdle() }
        updateIdleText()
    }

    // MARK: Steuer-Nachrichten (v2)

    private func handleControl(_ j: [String: Any]) {
        guard active else { return }
        switch j["type"] as? String {
        case "status":
            statusCount += 1
            lastStatusAt = CACurrentMediaTime()
            let a = (j["active"] as? NSNumber)?.boolValue
            let r = (j["autoReconnect"] as? NSNumber)?.boolValue
            if a != serverActive {
                Log.write(a == true ? "MacBook: Übertragung aktiv" : (a == false ? "MacBook: Bereitschaft (nicht verbunden) – „Jetzt verbinden“" : "MacBook: Status unbekannt"))
            }
            serverActive = a
            serverAutoReconnect = r
            updateIdleText()
        case "brightness":
            guard let n = j["value"] as? NSNumber, n.doubleValue.isFinite else {
                Log.write("Helligkeit vom MacBook: ungültiger Wert \(String(describing: j["value"]))"); return
            }
            applyBrightness(Float(min(1, max(0, n.doubleValue))))
        default:
            break                                    // unbekannte Typen ignorieren
        }
    }

    private func applyBrightness(_ v: Float) {
        brightnessSets += 1
        let ok: Bool
        if Self.brightnessLogOnly {
            ok = true
        } else {
            ok = Brightness.set(v)
        }
        if ok { lastSetBrightness = v }
        let now = CACurrentMediaTime()
        if now - lastBrightnessLogAt > 2 {
            let what = Self.brightnessLogOnly ? "[Test] nur protokolliert" : (ok ? "gesetzt (\(Brightness.methodDescription))" : "nicht möglich (\(Brightness.methodDescription))")
            Log.write("Helligkeit vom MacBook: \(Int((v * 100).rounded())) % – \(what)"
                      + (suppressedBrightnessLogs > 0 ? " (+\(suppressedBrightnessLogs) weitere)" : ""))
            lastBrightnessLogAt = now; suppressedBrightnessLogs = 0
        } else {
            suppressedBrightnessLogs += 1
        }
        // nach jedem Setzen melden – bei schnellen Folgen (Regler ziehen) höchstens alle 0,1 s, der letzte Wert immer
        if !brightnessReportScheduled {
            brightnessReportScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.brightnessReportScheduled = false
                self?.reportBrightness(force: true)
            }
        }
    }

    /// {"type":"brightness","supported":…,"value":…} – nach dem Verbinden, nach jedem Setzen, bei Änderung (> 0,5 %)
    private func reportBrightness(force: Bool) {
        guard active, connected else { return }
        let supported = Self.brightnessLogOnly || Brightness.isSupported
        var value: Float? = Self.brightnessLogOnly ? lastSetBrightness ?? 0.5 : (supported ? Brightness.get() : nil)
        if value == nil, supported { value = lastSetBrightness }
        if !force, let last = reportedBrightness, last.supported == supported {
            switch (last.value, value) {
            case (nil, nil): return
            case let (a?, b?) where abs(a - b) <= 0.005: return
            default: break
            }
        }
        reportedBrightness = (supported, value)
        var j: [String: Any] = ["type": "brightness", "supported": supported]
        if let value { j["value"] = NSDecimalNumber(string: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value))) }
        if Self.brightnessLogOnly { j["test"] = true }
        brightnessReports += 1
        lastBrightnessReport = sendJSON(j)
    }

    @discardableResult
    private func sendJSON(_ j: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) else { return "" }
        client.send(s)
        return s
    }

    /// MacBook ist da, aber nicht verbunden (v2 `status active:false`) und schickt kein Video (seit dem Verbinden
    /// noch keins bzw. seit 1,5 s keins mehr – der Status kann dem ersten Bild bis zu 2 s hinterherhinken)
    var isStandby: Bool {
        connected && serverActive == false && CACurrentMediaTime() - client.lastVideoAt > 1.5
    }

    private func handleConfig(_ j: [String: Any]?) {
        guard active, let j, let codec = j["codec"] as? String,
              let w = (j["width"] as? NSNumber)?.intValue, let h = (j["height"] as? NSNumber)?.intValue else {
            Log.write("Unvollständige Stream-Konfiguration: \(String(describing: j))"); return
        }
        let c = StreamConfig(codec: codec, width: w, height: h, fps: (j["fps"] as? NSNumber)?.doubleValue)
        if c != config { Log.write("Stream: \(codec) \(w)×\(h) @ \(c.fps.map { "\(Int($0))" } ?? "?") fps") }
        config = c
        if videoSize.w == 0 { videoSize = (w, h); geometryChanged() }
    }

    private func handleBadData(_ why: String, bytes: Int) {
        guard active else { return }
        stats.framesIn += 1; stats.bytesIn += bytes; stats.wBytes += bytes
        if why == H264Error.noFormat.description || waitingKey { stats.skipped += 1; if CACurrentMediaTime() - waitingSince > Self.keyframeWait { requestKeyframe(force: false) }; return }
        noteError("Ungültige Bilddaten: \(why)")
        setWaiting()
        requestKeyframe(force: true)
    }

    // MARK: Bilder

    private func handleSample(_ out: H264Depacketizer.Output, flagKey: Bool, bytes: Int, recv: Double) {
        guard active else { return }
        stats.framesIn += 1; stats.bytesIn += bytes; stats.wBytes += bytes
        let now = CACurrentMediaTime()
        if out.formatChanged || out.width != videoSize.w || out.height != videoSize.h {
            if out.formatChanged { stats.formatChanges += 1; renderer.flush(removeImage: false) }
            if out.width != videoSize.w || out.height != videoSize.h {
                Log.write("Videoformat: \(out.width)×\(out.height)")
                videoSize = (out.width, out.height)
                geometryChanged()
            }
        }
        if waitingKey && !out.isIDR {
            stats.skipped += 1
            if now - waitingSince > Self.keyframeWait { requestKeyframe(force: false) }
            return
        }
        if !renderer.enqueue(out.sample) {
            recover(renderer.healthProblem() ?? "Renderer nimmt keine Bilder an")
            return
        }
        if out.isIDR { waitingKey = false; keyEnqueuedAt = now }
        stats.enqueued += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(out.sample)
        recvTimes[pts.value] = recv
        if recvTimes.count > 240 { recvTimes = recvTimes.filter { $0.key >= pts.value - 2_000_000 } }
        (verifier as? FrameObservingHook)?.enqueued(out.sample, receivedAt: recv)
        if !renderer.reportsShownFrames && layerConfirmed(now) { frameShown(pts: nil) }
    }

    /// Der Layer meldet auf macOS 12 nicht, ob ein Bild dekodiert wurde – nur Fehler. Ein Bild gilt als gezeigt, wenn
    /// seit dem Keyframe 0,25 s ohne Fehler vergangen sind (dann ist der Keyframe sicher dekodiert). So bleibt bei einem
    /// Decoder, der den Stream gar nicht kann, die Meldung stehen statt ständig schwarz zu flackern.
    private func layerConfirmed(_ now: Double) -> Bool {
        guard !waitingKey, renderer.healthProblem() == nil else { return false }
        if showingVideo { return true }
        return now - keyEnqueuedAt >= Self.confirmAfter
    }

    private func frameShown(pts: CMTime?) {
        guard active else { return }
        let now = CACurrentMediaTime()
        if let pts, let r = recvTimes.removeValue(forKey: pts.value) { stats.latency.add((now - r) * 1000) }
        if waitingKey { return }                    // verspätetes Bild aus einem geleerten Decoder
        lastFrameAt = now
        stats.shown += 1
        stats.wFrames += 1
        // Fehlerserie erst beenden, wenn sicher dekodiert wurde (VT: jedes gemeldete Bild; Layer: Keyframe ist 0,25 s alt)
        if renderer.reportsShownFrames || now - keyEnqueuedAt >= Self.confirmAfter { failStreak = 0 }
        if !showingVideo && connected { enterVideo() }
    }

    private func setWaiting() {
        if !waitingKey { waitingSince = CACurrentMediaTime() }
        waitingKey = true
    }

    func requestKeyframe(force: Bool) {
        guard active, connected, !isStandby else { return }     // Bereitschaft: kein Encoder → nichts anfordern
        let now = CACurrentMediaTime()
        if now - lastKeyReq < (force ? 0.25 : 1.0) { return }
        lastKeyReq = now
        stats.keyReqs += 1
        client.send(#"{"type":"keyframe"}"#)
    }

    private func noteError(_ why: String) {
        stats.errors += 1
        lastError = why
        let now = CACurrentMediaTime()
        lastErrorAt = now
        if now - lastErrorLogAt > 10 {
            Log.write(why + (suppressedErrorLogs > 0 ? " (+\(suppressedErrorLogs) weitere Fehler)" : ""))
            lastErrorLogAt = now; suppressedErrorLogs = 0
        } else {
            suppressedErrorLogs += 1
        }
    }

    /// Decoder/Anzeige gestört: leeren, auf Keyframe warten, einen anfordern.
    private func recover(_ why: String) {
        guard active else { return }
        noteError(why)
        stats.recoveries += 1
        failStreak += 1
        renderer.flush(removeImage: failStreak >= 3)
        setWaiting()
        if failStreak >= 3 && showingVideo { enterIdle() }
        requestKeyframe(force: true)
    }

    private func enterVideo() {
        guard !showingVideo else { return }
        showingVideo = true
        root?.idleVisible = false
        Log.write("Bild läuft (\(videoSize.w)×\(videoSize.h), \(geometry.exact ? "1:1" : "skaliert auf \(Int(geometry.px.width))×\(Int(geometry.px.height)) px"))")
        lastPlayLog = CACurrentMediaTime()
    }

    private func enterIdle() {
        guard showingVideo else { return }
        showingVideo = false
        stats.idleSwitches += 1
        renderer.flush(removeImage: true)          // kein eingefrorenes letztes Bild
        recvTimes.removeAll()
        setWaiting()
        root?.idleVisible = true
        updateIdleText()
        Log.write("Kein Bild mehr – „Aktuell kein aktiver Monitor“")
    }

    private func tick() {
        guard active else { return }
        let now = CACurrentMediaTime()
        if showingVideo && (!connected || now - lastFrameAt > Self.idleAfter) { enterIdle() }
        if let why = renderer.healthProblem() { recover(why) }
        // Standbild: nach dem Keyframe kommt evtl. lange kein weiteres Bild → hier bestätigen
        if !showingVideo && connected && !renderer.reportsShownFrames && layerConfirmed(now) { frameShown(pts: nil) }
        if connected {
            if waitingKey && now - waitingSince > Self.keyframeWait { requestKeyframe(force: false) }
            // lange kein Video (Status-Nachrichten zählen hier nicht) → Keyframe anfordern
            if now - max(client.lastVideoAt, client.openedAt) > Self.quietRefresh { requestKeyframe(force: false) }
        }
        updateIdleText()
        // Autostart bei der Anmeldung: Finder/Dock kommen evtl. erst danach nach vorne → in den ersten 20 s
        // nach vorne holen, sonst lägen Dock und Menüleiste über dem Bild.
        if fullScreen && !NSApp.isActive && now - startedAt < 20 && Int(now * 4) % 4 == 0 { bringToFront() }
        (verifier as? TickingHook)?.tick(self)
    }

    /// Ruhebild: Überschrift + Hinweiszeile je nach Zustand
    static let standbyHint = "Auf dem MacBook in „iMac Display“ auf „Verbinden“ klicken."
    static let unreachableHint = "MacBook per Kabel anschließen und „iMac Display“ öffnen."

    private func updateIdleText() {
        let heading: String, t: String
        if connected {
            if let e = lastError, CACurrentMediaTime() - lastErrorAt < 5, failStreak >= 3 {
                heading = "Bild kann nicht angezeigt werden"
                t = "\(e) – neuer Versuch …"
            } else if serverActive == false {
                heading = "Jetzt verbinden"
                t = Self.standbyHint
            } else {
                heading = "Verbunden"
                t = serverActive == true ? "Das Bild kommt gleich …" : "Warte auf das Bild des MacBooks …"
            }
        } else {
            heading = "Jetzt verbinden"
            t = Self.unreachableHint
        }
        root?.setIdleText(heading: heading, context: t)
    }

    // MARK: Statistik

    private func updateWindowStats() {
        let now = CACurrentMediaTime(), dt = now - stats.wStart
        guard dt >= 0.9 else { return }
        stats.fps = Double(stats.wFrames) / dt
        stats.mbps = Double(stats.wBytes) * 8 / 1e6 / dt
        stats.wFrames = 0; stats.wBytes = 0; stats.wStart = now
        if showingVideo && now - lastPlayLog > 300 {
            lastPlayLog = now
            Log.write(String(format: "Bild: %.1f fps, %.1f Mbit/s, %d Fehler, %d Keyframe-Anfragen", stats.fps, stats.mbps, stats.errors, stats.keyReqs))
        }
        (verifier as? TickingHook)?.second(self)
    }

    private func sendStats() {
        guard showingVideo else { return }
        let j: [String: Any] = [
            "type": "stats",
            "fps": (stats.fps * 10).rounded() / 10,
            "decodeQueue": 0,
            "dropped": stats.skipped,
            "mbps": (stats.mbps * 10).rounded() / 10,
            "drawMs": (stats.latency.mean * 10).rounded() / 10,
            "keyframeRequests": stats.keyReqs,
            "errors": stats.errors,
            "hw": "videotoolbox",
            "renderer": renderer is LayerRenderer ? "avsbdl" : "vt",
        ]
        if let d = try? JSONSerialization.data(withJSONObject: j), let s = String(data: d, encoding: .utf8) { client.send(s) }
    }

    var picture: PictureInfo {
        if showingVideo { return .playing(fps: stats.fps, width: videoSize.w, height: videoSize.h, hardware: renderer.usingHardware) }
        if let e = lastError, failStreak >= 3, CACurrentMediaTime() - lastErrorAt < 10 { return .failing(e) }
        if isStandby { return .standby }
        return .waiting(connected: connected)
    }

    var statsText: String {
        let g = geometry
        let lat = stats.latency.count > 0 ? String(format: "%.1f ms (p95 %.1f)", stats.latency.mean, stats.latency.p95) : "–"
        return """
        Bild        \(showingVideo ? "läuft" : "kein Bild")   \(connected ? "verbunden" : "nicht verbunden")\(waitingKey ? " · warte auf Keyframe" : "")
        fps         \(String(format: "%.1f", stats.fps))
        Mbit/s      \(String(format: "%.1f", stats.mbps))
        Fehler      \(stats.errors)   Keyframe-Anfragen \(stats.keyReqs)   verworfen \(stats.skipped)
        Bilder      empfangen \(stats.framesIn)  angezeigt \(stats.shown)
        Latenz      \(lat)
        Auflösung   \(videoSize.w)×\(videoSize.h)   Ansicht \(Int(g.pt.width))×\(Int(g.pt.height)) pt @\(g.scale)x = \(Int(g.px.width))×\(Int(g.px.height)) px \(g.exact ? "(1:1)" : "(skaliert)")
        Codec       \(config?.codec ?? "–")\(config?.fps.map { " @ \(Int($0)) fps" } ?? "") · VideoToolbox (\(renderer.name))
        Verbindung  ws://\(host)/ws   Neuverbindungen \(client.reconnects)
        MacBook     \(serverActive.map { $0 ? "aktiv" : "Bereitschaft" } ?? "–")\(serverAutoReconnect == true ? " · verbindet automatisch" : "")   Status-Nachrichten \(statusCount)
        Helligkeit  \(reportedBrightness.map { $0.supported ? ($0.value.map { "\(Int(($0 * 100).rounded())) %" } ?? "?") : "nicht einstellbar" } ?? "–")   gesetzt \(brightnessSets)×
        """
    }

    private func updateStatsOverlay() {
        guard let r = root, r.statsVisible else { return }
        r.setStatsText(statsText)
    }

    /// Für Tests (Testkanal „player“ und IMAC_RECEIVER_TEST_STATS)
    var testSnapshot: [String: Any] {
        let g = geometry
        var d: [String: Any] = [
            "connected": connected, "showingVideo": showingVideo, "waitingKey": waitingKey,
            "framesIn": stats.framesIn, "enqueued": stats.enqueued, "shown": stats.shown, "skipped": stats.skipped,
            "keyReqs": stats.keyReqs, "errors": stats.errors, "recoveries": stats.recoveries, "idleSwitches": stats.idleSwitches,
            "formatChanges": stats.formatChanges, "reconnects": client.reconnects,
            "fps": stats.fps, "mbps": stats.mbps, "video": "\(videoSize.w)x\(videoSize.h)",
            "viewPt": "\(Int(g.pt.width))x\(Int(g.pt.height))", "scale": g.scale, "viewPx": "\(Int(g.px.width))x\(Int(g.px.height))",
            "exact": g.exact, "renderer": renderer.name, "idleText": root?.idleTitle ?? "", "idleSub": root?.idleSubtitle ?? "",
            "idleHeading": root?.idleHeading ?? "", "idleLink": root?.idleLink ?? "", "qrVisible": root?.qrVisible ?? false,
            "serverActive": serverActive.map { $0 ? "true" : "false" } ?? "nil", "autoReconnect": serverAutoReconnect.map { $0 ? "true" : "false" } ?? "nil",
            "statusCount": statusCount, "controlCount": client.controlCount, "standby": isStandby,
            "brightnessSets": brightnessSets, "brightnessReports": brightnessReports, "lastBrightnessReport": lastBrightnessReport,
            "countdown": countdownText,
            "idleVisible": root?.idleVisible ?? false, "statsVisible": root?.statsVisible ?? false,
            "idleOffset": root.map { "\(Int($0.idleOffset.x)),\(Int($0.idleOffset.y))" } ?? "",
            "cursorHidden": cursorHidden, "presentation": NSApp.presentationOptions.rawValue,
            "windowFrame": window.map { NSStringFromRect($0.frame) } ?? "", "lastError": lastError ?? "",
            "latMean": stats.latency.mean, "latP50": stats.latency.p50, "latP95": stats.latency.p95, "latMax": stats.latency.max,
            "latCount": stats.latency.count, "memMB": Double(memoryFootprint()) / 1_048_576,
            "layerBounds": NSStringFromRect(renderer.layer.bounds), "layerScale": renderer.layer.contentsScale,
        ]
        if let h = verifier as? TickingHook { h.addSnapshot(&d) }
        return d
    }
}

// MARK: - Latenz-Statistik

struct LatencyStats {
    private var values: [Double] = []
    private(set) var count = 0
    mutating func add(_ ms: Double) {
        values.append(ms); count += 1
        if values.count > 600 { values.removeFirst(values.count - 600) }
    }
    mutating func reset() { values = []; count = 0 }
    var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    private func pct(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }
    var p50: Double { pct(0.5) }
    var p95: Double { pct(0.95) }
    var max: Double { values.max() ?? 0 }
}

func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

// MARK: - Fenster & Ansicht

final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Randloses Fenster darf die Menüleiste überdecken
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) {}      // Esc: nichts
}

/// Nur das Video-Layer (layer-hosting), Größe = Ansicht, contentsScale = Bildschirm-Faktor.
final class VideoHostView: NSView {
    let videoLayer: CALayer
    init(frame: NSRect, videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.isOpaque = true
        layer = root
        wantsLayer = true
        root.addSublayer(videoLayer)
        layoutVideo()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); layoutVideo() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutVideo() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); layoutVideo() }

    func layoutVideo() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        videoLayer.contentsScale = scale
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Schwarze Fläche, die sich auch selbst zeichnet (damit Vorschaubilder per cacheDisplay schwarz sind)
final class BlackView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); dirtyRect.fill() }
}

/// Ruhebild (kein Bild vom MacBook), mittig und symmetrisch, auf Schwarz:
///
///                 Aktuell kein aktiver Monitor            groß, hellgrau (wie bisher)
///                      Jetzt verbinden                    Überschrift
///     Auf dem MacBook in „iMac Display“ auf „Verbinden“ klicken.   Hinweis je nach Zustand
///                        ▄▄▄▄▄▄▄▄
///                        █ QR   █                         CIQRCodeGenerator, Link zum GitHub-Projekt
///                        ▀▀▀▀▀▀▀▀
///             github.com/JonasHallenbarter/iMac-Display   klein, gedämpft
///
/// Die ganze Gruppe wandert alle 60 s langsam an eine andere Stelle (Einbrennschutz).
final class PlayerRootView: NSView {
    let videoHost: VideoHostView
    private let idleView = BlackView()
    private let idleBox = NSView()
    private let titleLabel = PlayerRootView.label("Aktuell kein aktiver Monitor")
    private let headingLabel = PlayerRootView.label("Jetzt verbinden")
    private let contextLabel = PlayerRootView.label("")
    private let linkLabel = PlayerRootView.label(PlayerRootView.linkText)
    private let qrView = QRCodeView()
    private let countdownView = CountdownView(frame: .zero)
    private let statsLabel = NSTextField(labelWithString: "")
    private let hideCursor: Bool
    private lazy var blankCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus(); NSColor.clear.set(); NSRect(x: 0, y: 0, width: 1, height: 1).fill(); img.unlockFocus()
        return NSCursor(image: img, hotSpot: .zero)
    }()
    var hostLabel = ""
    var onKey: ((NSEvent) -> Void)?
    var onGeometryChange: (() -> Void)?
    /// Versatz der Gruppe als Anteil (-1…1) von 16 % Breite / 22 % Höhe (begrenzt, damit alles sichtbar bleibt)
    private var shift = CGPoint.zero
    private(set) var idleOffset = CGPoint.zero
    /// Skalierung für das pixelgenaue QR-Raster (Vorschaubilder: 2, sonst die des Fensters)
    var scaleOverride: CGFloat?

    static let linkText = Config.projectURL.replacingOccurrences(of: "https://", with: "")

    private static func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .center
        l.isSelectable = false
        l.drawsBackground = false
        l.isBezeled = false
        l.lineBreakMode = .byClipping
        return l
    }

    var idleTitle: String { titleLabel.stringValue }
    var idleHeading: String { headingLabel.stringValue }
    var idleSubtitle: String { contextLabel.stringValue }
    var idleLink: String { linkLabel.stringValue }
    var qrVisible: Bool { !idleView.isHidden && !idleBox.isHidden && qrView.code != nil }
    /// Lage des QR-Codes in dieser Ansicht (Tests/Vorschau)
    var qrFrame: NSRect { qrView.convert(qrView.bounds, to: self) }
    var countdownText: String { countdownView.isHidden ? "" : countdownView.text }
    var idleVisible: Bool {
        get { !idleView.isHidden }
        set { idleView.isHidden = !newValue }
    }
    var statsVisible: Bool {
        get { !statsLabel.isHidden }
        set { statsLabel.isHidden = !newValue }
    }

    init(frame: NSRect, videoLayer: CALayer, hideCursor: Bool) {
        videoHost = VideoHostView(frame: NSRect(origin: .zero, size: frame.size), videoLayer: videoLayer)
        self.hideCursor = hideCursor
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        videoHost.autoresizingMask = [.width, .height]
        addSubview(videoHost)

        idleView.frame = bounds
        idleView.autoresizingMask = [.width, .height]
        addSubview(idleView)
        titleLabel.textColor = NSColor(calibratedWhite: 0xb4 / 255.0, alpha: 1)     // #b4b4b4 wie bisher
        headingLabel.textColor = NSColor(calibratedWhite: 0xd0 / 255.0, alpha: 1)   // #d0d0d0
        contextLabel.textColor = NSColor(calibratedWhite: 0x80 / 255.0, alpha: 1)   // #808080
        linkLabel.textColor = NSColor(calibratedWhite: 0x58 / 255.0, alpha: 1)      // #585858 klein, gedämpft
        qrView.code = QRCode.make(Config.projectURL)
        for v in [titleLabel, headingLabel, contextLabel, qrView, linkLabel] as [NSView] { idleBox.addSubview(v) }
        idleView.addSubview(idleBox)

        countdownView.isHidden = true
        addSubview(countdownView)

        statsLabel.font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        statsLabel.textColor = NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1)
        statsLabel.drawsBackground = true
        statsLabel.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.7)
        statsLabel.isBezeled = false
        statsLabel.isSelectable = false
        statsLabel.maximumNumberOfLines = 0
        statsLabel.isHidden = true
        addSubview(statsLabel)
        shiftIdleText(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }       // nichts weiterreichen (kein Piepton)
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func resetCursorRects() { if hideCursor { addCursorRect(bounds, cursor: blankCursor) } }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); dirtyRect.fill() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutIdle()
        layoutCountdown()
        layoutStats()
        onGeometryChange?()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutIdle()                                  // QR-Raster an die neue Pixeldichte anpassen
        onGeometryChange?()
    }

    func setIdleText(heading: String, context: String) {
        guard headingLabel.stringValue != heading || contextLabel.stringValue != context else { return }
        headingLabel.stringValue = heading
        contextLabel.stringValue = context
        layoutIdle()
    }

    func setStatsText(_ s: String) {
        statsLabel.stringValue = s
        layoutStats()
    }

    /// Countdown „Automatisch ausschalten“: mittig statt der Ruhebild-Gruppe (nil = ausblenden)
    func setCountdown(remaining: Int?, fraction: Double) {
        if let remaining {
            countdownView.set(remaining: remaining, fraction: fraction)
            if countdownView.isHidden {
                countdownView.isHidden = false
                idleBox.isHidden = true
                layoutCountdown()
            }
        } else if !countdownView.isHidden {
            countdownView.isHidden = true
            idleBox.isHidden = false
        }
    }

    private func layoutStats() {
        let size = statsLabel.intrinsicContentSize
        statsLabel.frame = NSRect(x: 8, y: bounds.height - 8 - size.height, width: size.width + 18, height: size.height)
    }

    private func layoutCountdown() {
        let w = bounds.width
        countdownView.titleSize = min(84, max(22, (w * 0.022).rounded()))       // 45 pt bei 2048 pt
        let s = countdownView.preferredSize
        countdownView.frame = NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                                     width: s.width, height: s.height)
    }

    private var pixelScale: CGFloat { scaleOverride ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Schriftgrößen wie bisher im Browser: Titel clamp(28px, 3.1vw, 120px), Hinweis clamp(13px, .95vw, 36px)
    private func layoutIdle(animated: Bool = false) {
        let w = bounds.width, h = bounds.height
        let big = min(120, max(28, w * 0.031))                 // 63,5 pt bei 2048 pt Breite
        let small = min(36, max(13, w * 0.0095))               // 19,5 pt
        let headSize = (big * 0.5).rounded()                   // 32 pt
        let linkSize = max(11, (small * 0.8).rounded())        // 16 pt
        if titleLabel.font?.pointSize != big { titleLabel.font = .systemFont(ofSize: big, weight: .light) }
        if headingLabel.font?.pointSize != headSize { headingLabel.font = .systemFont(ofSize: headSize, weight: .regular) }
        if contextLabel.font?.pointSize != small { contextLabel.font = .systemFont(ofSize: small, weight: .regular) }
        if linkLabel.font?.pointSize != linkSize { linkLabel.font = .systemFont(ofSize: linkSize, weight: .regular) }

        let scale = pixelScale
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let modules = qrView.code?.modules ?? 41
        // ca. 20 % der Höhe (≈ 236 pt bei 1152 pt), auf ganze Pixel pro Modul gerundet → scharfe Module
        let qr = QRCodeView.snappedSide(target: min(420, max(110, h * 0.205)), modules: modules, scale: scale)

        let t = titleLabel.intrinsicContentSize, hd = headingLabel.intrinsicContentSize
        let c = contextLabel.intrinsicContentSize, l = linkLabel.intrinsicContentSize
        let gTitle = (big * 0.8).rounded()                     // Titel → Überschrift
        let gHead = (headSize * 0.3).rounded()                 // Überschrift → Hinweis
        let gQR = (small * 2.1).rounded()                      // Hinweis → QR
        let gLink = (small * 0.85).rounded()                   // QR → Link
        let bw = ceil(max(t.width, hd.width, c.width, l.width, qr)) + 4
        let bh = ceil(t.height + gTitle + hd.height + gHead + c.height + gQR + qr + gLink + l.height)
        func center(_ width: CGFloat) -> CGFloat { px((bw - width) / 2) }
        var y: CGFloat = 0
        linkLabel.frame = NSRect(x: center(l.width), y: y, width: l.width, height: l.height); y += l.height + gLink
        qrView.frame = NSRect(x: center(qr), y: px(y), width: qr, height: qr); y += qr + gQR
        contextLabel.frame = NSRect(x: center(c.width), y: y, width: c.width, height: c.height); y += c.height + gHead
        headingLabel.frame = NSRect(x: center(hd.width), y: y, width: hd.width, height: hd.height); y += hd.height + gTitle
        titleLabel.frame = NSRect(x: center(t.width), y: y, width: t.width, height: t.height)

        // Versatz begrenzen, damit die Gruppe immer ganz sichtbar bleibt
        let dx = min(w * 0.16, max(0, (w - bw) / 2 - 16)) * shift.x
        let dy = min(h * 0.22, max(0, (h - bh) / 2 - 16)) * shift.y
        idleOffset = CGPoint(x: dx, y: dy)
        let f = NSRect(x: ((w - bw) / 2 + dx).rounded(), y: ((h - bh) / 2 + dy).rounded(), width: bw, height: bh)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 6
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                idleBox.animator().frame = f
            }
        } else {
            idleBox.frame = f
        }
    }

    /// Einbrennschutz: Gruppe alle 60 s langsam an eine andere Stelle schieben
    func shiftIdleText(animated: Bool) {
        shift = CGPoint(x: Double.random(in: -1...1), y: Double.random(in: -1...1))
        layoutIdle(animated: animated)
    }

    /// Für Vorschaubilder: Versatz fest vorgeben (-1…1)
    func setShift(_ p: CGPoint) {
        shift = p
        layoutIdle()
    }
}
