import AppKit
import CoreGraphics
import CoreServices
import QuartzCore

// MARK: - Eingabe-Leerlauf

/// Sekunden seit der letzten Eingabe an DIESEM Mac (Tastatur, Maus, Trackpad) – CGEventSource, keine Berechtigung nötig.
/// Test (nur IMAC_RECEIVER_DRY_RUN=1): IMAC_RECEIVER_FAKE_INPUT_IDLE=<s> bzw. Testkanal „fakeIdle <s>“ / „fakeInput“
/// geben den Wert vor (er läuft dann von selbst weiter, wie der echte).
enum InputIdle {
    /// kCGAnyInputEventType (~0)
    static let anyInput = CGEventType(rawValue: ~0)!
    private static var fake: (base: Double, at: Double)? = {
        guard Config.dryRun, let s = Config.env["IMAC_RECEIVER_FAKE_INPUT_IDLE"], let v = Double(s) else { return nil }
        return (v, CACurrentMediaTime())
    }()
    static var isFaked: Bool { fake != nil }

    static func seconds() -> Double {
        if let f = fake { return f.base + (CACurrentMediaTime() - f.at) }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// nil = wieder echte Eingaben messen. Nur im Testmodus wirksam.
    static func setFake(_ seconds: Double?) {
        guard Config.dryRun else { return }
        fake = seconds.map { ($0, CACurrentMediaTime()) }
    }
}

// MARK: - Ausschalten per Apple Event (Apple Technical Q&A QA1134)

enum ShutdownResult: Equatable {
    case sent                                   // Apple Event zugestellt – macOS fährt herunter
    case simulated(String)                      // Testmodus: nur protokolliert („würde jetzt ausschalten“)
    case failed(code: Int, message: String)
    case notCompleted                           // zugestellt, aber der Mac läuft nach 90 s noch (z. B. Programm hat abgebrochen)
}

enum ShutdownPermission: Equatable {
    case notChecked
    case granted
    case needsConsent                           // -1744: macOS fragt beim ersten Mal nach
    case denied                                 // -1743: in Automation abgelehnt
    case unavailable(Int)                       // z. B. -600 Systemprozess nicht gefunden
}

enum SystemShutdown {
    /// Warum dieser Prozess NICHT wirklich ausschalten darf (nil = darf). Mehrfach gesichert:
    /// Testmodus, ausdrückliches Verbot, Testfenster und „läuft nicht als .app“ (nacktes Binary aus dem Build-Ordner).
    static var blockReason: String? {
        if Config.dryRun { return "Testmodus (IMAC_RECEIVER_DRY_RUN=1)" }
        if Config.env["IMAC_RECEIVER_NO_SHUTDOWN"] == "1" { return "IMAC_RECEIVER_NO_SHUTDOWN=1" }
        if Config.env["IMAC_RECEIVER_WINDOW"] != nil { return "Testfenster (IMAC_RECEIVER_WINDOW)" }
        if !Config.isAppBundle { return "läuft nicht als App (Entwicklung)" }
        return nil
    }

    /// Ziel wie in QA1134: der Systemprozess (= loginwindow der Sitzung), PSN { 0, kSystemProcess }.
    private static func systemProcess() -> NSAppleEventDescriptor? {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 1 /* kSystemProcess */)
        return NSAppleEventDescriptor(descriptorType: DescType(typeProcessSerialNumber), bytes: &psn,
                                      length: MemoryLayout<ProcessSerialNumber>.size)
    }

    /// Mac ausschalten (kAEShutDown = 'shut': Programme werden zum Beenden aufgefordert; eines mit ungesicherten
    /// Änderungen kann das noch verhindern). `completion` auf dem Main-Thread.
    static func request(_ completion: @escaping (ShutdownResult) -> Void) {
        if let why = blockReason {
            Log.write("[Testmodus] würde jetzt ausschalten (Apple Event kAEShutDown an loginwindow) – nicht gesendet: \(why)")
            completion(.simulated(why))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = sendShutdownEvent()          // blockiert ggf. bis zur Antwort (oder bis zur Zustimmung im Dialog)
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Einzige Stelle, die das Ereignis baut und sendet.
    private static func sendShutdownEvent() -> ShutdownResult {
        if let why = blockReason { return .simulated(why) }          // zweite Sicherung
        guard let target = systemProcess() else { return .failed(code: -1, message: "Interner Fehler (Ziel)") }
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEShutDown),
                                                      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        guard let desc = event.aeDesc else { return .failed(code: -1, message: "Interner Fehler (Apple Event)") }
        Log.write("Automatisch ausschalten: sende Apple Event kAEShutDown an loginwindow")
        var reply = AEDesc()
        let st = AESendMessage(desc, &reply, AESendMode(kAEWaitReply) | AESendMode(kAECanInteract), 60 * 60 /* Ticks = 60 s */)
        var code = Int(st)
        if st == noErr {
            let r = NSAppleEventDescriptor(aeDescNoCopy: &reply)       // übernimmt reply (kein AEDisposeDesc)
            if let e = r.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)) { code = Int(e.int32Value) }
        } else {
            AEDisposeDesc(&reply)
        }
        if code == 0 { return .sent }
        return .failed(code: code, message: describe(code))
    }

    /// Erlaubnis prüfen (AEDeterminePermissionToAutomateTarget, macOS 10.14+) – sendet KEIN Apple Event.
    /// ask = macOS-Dialog zeigen, falls nötig (blockiert bis zur Antwort → nie auf dem Main-Thread). Im Testmodus nie fragen.
    static func checkPermission(ask: Bool) -> ShutdownPermission {
        guard let target = systemProcess(), let desc = target.aeDesc else { return .unavailable(-1) }
        let st = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kCoreEventClass), AEEventID(kAEShutDown),
                                                       ask && blockReason == nil)
        switch Int(st) {
        case 0: return .granted
        case -1744: return .needsConsent
        case -1743: return .denied
        default: return .unavailable(Int(st))
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case -1743: return "macOS hat das Ausschalten nicht erlaubt (Automation, Fehler -1743)"
        case -1744: return "macOS verlangt zuerst eine Erlaubnis (Automation, Fehler -1744)"
        case -600: return "Systemprozess (loginwindow) nicht gefunden (Fehler -600)"
        case -609: return "Verbindung zum Systemprozess unterbrochen (Fehler -609)"
        case -1712: return "keine Antwort vom System (Zeitüberschreitung, Fehler -1712) – evtl. wartet ein Dialog"
        case -128: return "abgebrochen (Fehler -128) – z. B. von einem Programm mit ungesicherten Änderungen"
        default: return "Fehler \(code)"
        }
    }

    static let automationPrefsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

// MARK: - Steuerung „Automatisch ausschalten nach 10 Min. ohne Bild“

/// Zustand für die Checkliste
struct AutoShutdownInfo: Equatable {
    enum Phase: Equatable {
        case off
        case picture                            // Bild läuft → wartet
        case waiting(remaining: Double)         // so viele Sekunden bis zum Countdown (falls kein Bild/keine Eingabe)
        case countdown(remaining: Int)
        case requested                          // Apple Event zugestellt
    }
    var enabled = true
    var phase: Phase = .off
    var lastResult: ShutdownResult?
    var lastResultAt: Date?
    var permission: ShutdownPermission = .notChecked
    var idleLimit: Double = Config.shutdownIdle
    var countdownLength: Double = Config.shutdownCountdown
}

final class AutoShutdown {
    static let defaultsKey = "autoShutdown"
    static let completionTimeout = 90.0         // so lange nach dem Apple Event noch am Leben → „nicht abgeschlossen“

    let idleLimit = Config.shutdownIdle
    let countdownLength = Config.shutdownCountdown

    /// Bild vom MacBook wird gerade gezeigt
    var pictureShowing: () -> Bool = { false }
    /// Player (Monitor-Modus) – zeigt den Countdown im Vollbild; nil → schwebendes Fenster
    var player: () -> PlayerController? = { nil }
    /// Zustand für die Anzeige geändert (Main-Thread)
    var onChange: (() -> Void)?
    /// Countdown beginnt/endet (Bildschirm aufwecken bzw. wieder freigeben)
    var onCountdownActive: ((Bool) -> Void)?
    /// direkt vor dem Senden: Energie-Assertions freigeben
    var beforeShutdown: (() -> Void)?

    private(set) var info = AutoShutdownInfo()
    private var base = CACurrentMediaTime()     // Beginn der aktuellen Wartezeit (Start, Einschalten, Abbruch, Bild weg)
    private var countdownStart: Double?
    private var requestedAt: Double?
    private var sending = false
    private var timer: Timer?
    private var panel: CountdownPanel?
    private var shownIn = ""                    // „player“ / „panel“ / ""
    private var lastLoggedMinute = -1
    private(set) var counters: [String: Int] = ["countdowns": 0, "cancelInput": 0, "cancelPicture": 0, "cancelOther": 0,
                                               "fired": 0, "simulated": 0, "sent": 0, "failed": 0]
    private(set) var lastEvent = ""

    init() {
        UserDefaults.standard.register(defaults: [Self.defaultsKey: true])     // Standard: AN (Wunsch des Nutzers)
        var on = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if let e = Config.env["IMAC_RECEIVER_AUTO_SHUTDOWN"] { on = e == "1" }   // Test: Startwert ohne Speichern
        info.enabled = on
    }

    var enabled: Bool {
        get { info.enabled }
        set {
            guard newValue != info.enabled else { return }
            info.enabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            Log.write("Automatisch ausschalten: \(newValue ? "an" : "aus")")
            if !newValue { cancel("ausgeschaltet", counter: "cancelOther") }
            base = CACurrentMediaTime()
            if newValue { info.lastResult = nil }
            tick()
        }
    }

    /// Hält das System wach, damit es statt in den Ruhezustand zu gehen nach der Wartezeit ausschaltet.
    /// Nach einem fehlgeschlagenen Versuch nicht mehr (sonst schliefe der Mac nie, falls Ausschalten unmöglich ist).
    var holdsSystemAwake: Bool {
        guard info.enabled, !sending, requestedAt == nil else { return false }
        if case .failed = info.lastResult { return false }
        return true
    }
    var isShuttingDown: Bool { sending || requestedAt != nil }

    func start() {
        base = CACurrentMediaTime()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.write("Automatisch ausschalten: \(info.enabled ? "an" : "aus") (nach \(Self.duration(idleLimit)) ohne Bild und ohne Eingabe, "
                  + "Countdown \(Int(countdownLength)) s)\(InputIdle.isFaked ? " – Test: Eingabe-Leerlauf vorgegeben" : "")")
        tick()
        if SystemShutdown.blockReason == nil { checkPermission(ask: false) }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        hideCountdown()
    }

    /// Erlaubnis prüfen (ask: macOS-Dialog zeigen, falls nötig). Im Hintergrund, Ergebnis in info.permission.
    func checkPermission(ask: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = SystemShutdown.checkPermission(ask: ask)
            DispatchQueue.main.async {
                if p != self.info.permission { Log.write("Automatisch ausschalten: Erlaubnis \(p)\(ask ? " (nachgefragt)" : "")") }
                self.info.permission = p
                if p == .granted, case .failed(let c, _)? = self.info.lastResult, c == -1743 || c == -1744 { self.info.lastResult = nil }
                self.onChange?()
            }
        }
    }

    /// Countdown abbrechen (Knopf, Testkanal)
    func cancelCountdown() { cancel("Abbrechen", counter: "cancelOther") }

    // MARK: Ablauf

    func tick() {
        let before = info
        defer { if info != before { onChange?() } }
        guard info.enabled else { info.phase = .off; hideCountdown(); return }
        let now = CACurrentMediaTime()
        if sending { return }
        if let r = requestedAt {
            info.phase = .requested
            if now - r > Self.completionTimeout {
                requestedAt = nil
                info.lastResult = .notCompleted; info.lastResultAt = Date()
                Log.write("Automatisch ausschalten: Mac läuft nach \(Int(Self.completionTimeout)) s noch – Ausschalten wurde abgebrochen "
                          + "(z. B. Programm mit ungesicherten Änderungen). Neuer Versuch nach \(Self.duration(idleLimit)) ohne Bild.")
                base = now
            }
            return
        }
        if pictureShowing() {
            if countdownStart != nil { cancel("Bild vom MacBook", counter: "cancelPicture") }
            base = now
            info.phase = .picture
            return
        }
        let idle = InputIdle.seconds()
        if let cs = countdownStart {
            let elapsed = now - cs
            // Eingabe nach Beginn des Countdowns (0,3 s Toleranz: das Aufwecken des Bildschirms ist keine Eingabe)
            if idle + 0.3 < elapsed { cancel("Eingabe (Maus/Tastatur)", counter: "cancelInput"); return }
            if elapsed >= countdownLength { fire(); return }
            let remaining = Int(ceil(countdownLength - elapsed))
            info.phase = .countdown(remaining: remaining)
            showCountdown(remaining, fraction: max(0, 1 - elapsed / countdownLength))
            return
        }
        let inactive = min(now - base, idle)
        if inactive >= idleLimit {
            startCountdown(now)
        } else {
            info.phase = .waiting(remaining: idleLimit - inactive)
        }
    }

    private func startCountdown(_ now: Double) {
        countdownStart = now
        counters["countdowns", default: 0] += 1
        lastEvent = "countdown"
        Log.write("Automatisch ausschalten: \(Self.duration(idleLimit)) ohne Bild und ohne Eingabe – Countdown \(Int(countdownLength)) s")
        onCountdownActive?(true)
        player()?.bringToFront()
        info.phase = .countdown(remaining: Int(countdownLength))
        showCountdown(Int(countdownLength), fraction: 1)
    }

    private func cancel(_ why: String, counter: String) {
        guard countdownStart != nil else { return }
        countdownStart = nil
        counters[counter, default: 0] += 1
        lastEvent = "abgebrochen: \(why)"
        Log.write("Automatisch ausschalten: Countdown abgebrochen – \(why). Wartezeit beginnt neu.")
        base = CACurrentMediaTime()
        hideCountdown()
        onCountdownActive?(false)
        if info.enabled { info.phase = .waiting(remaining: idleLimit) }
    }

    private func fire() {
        countdownStart = nil
        counters["fired", default: 0] += 1
        lastEvent = "abgelaufen"
        Log.write("Automatisch ausschalten: Countdown abgelaufen – schalte den iMac aus")
        hideCountdown()
        onCountdownActive?(false)
        sending = true
        info.phase = .requested                 // bis zur Antwort (kann auf den Zustimmungs-Dialog warten)
        onChange?()
        beforeShutdown?()                       // Energie-Assertions freigeben
        SystemShutdown.request { [weak self] r in
            guard let self else { return }
            self.sending = false
            self.info.lastResult = r
            self.info.lastResultAt = Date()
            let now = CACurrentMediaTime()
            switch r {
            case .sent:
                self.counters["sent", default: 0] += 1
                self.requestedAt = now
                Log.write("Automatisch ausschalten: Apple Event zugestellt – macOS fährt herunter")
            case .simulated:
                self.counters["simulated", default: 0] += 1
                self.base = now
            case .failed(let code, let msg):
                self.counters["failed", default: 0] += 1
                self.base = now
                if code == -1743 { self.info.permission = .denied }
                Log.write("Automatisch ausschalten FEHLGESCHLAGEN: \(msg). Neuer Versuch nach \(Self.duration(self.idleLimit)) ohne Bild.")
            case .notCompleted:
                self.base = now
            }
            self.tick()
            self.onChange?()
        }
    }

    // MARK: Countdown-Anzeige

    static func message(_ s: Int) -> String {
        "Der iMac wird in \(s) \(s == 1 ? "Sekunde" : "Sekunden") ausgeschaltet – Maus bewegen oder Taste drücken zum Abbrechen."
    }

    private func showCountdown(_ remaining: Int, fraction: Double) {
        if let p = player(), p.isVisible {
            if panel != nil { panel?.close(); panel = nil }
            p.setCountdown(remaining: remaining, fraction: fraction)
            shownIn = "player"
        } else {
            if panel == nil {
                panel = CountdownPanel { [weak self] in self?.cancelCountdown() }
                panel?.present()
            }
            panel?.update(remaining: remaining, fraction: fraction)
            shownIn = "panel"
        }
    }

    private func hideCountdown() {
        player()?.setCountdown(remaining: nil, fraction: 0)
        panel?.close(); panel = nil
        shownIn = ""
    }

    static func duration(_ s: Double) -> String {
        s >= 60 && s.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(s / 60)) Min." : "\(Int(s)) s"
    }

    /// Für den Testkanal
    var snapshot: [String: Any] {
        var phase = ""
        var remaining = 0.0
        switch info.phase {
        case .off: phase = "off"
        case .picture: phase = "picture"
        case .waiting(let r): phase = "waiting"; remaining = r
        case .countdown(let r): phase = "countdown"; remaining = Double(r)
        case .requested: phase = "requested"
        }
        var d: [String: Any] = ["enabled": info.enabled, "phase": phase, "remaining": (remaining * 10).rounded() / 10,
                                "shownIn": shownIn, "inputIdle": (InputIdle.seconds() * 10).rounded() / 10,
                                "idleLimit": idleLimit, "countdownLength": countdownLength, "lastEvent": lastEvent,
                                "permission": "\(info.permission)", "holdsSystemAwake": holdsSystemAwake,
                                "blockReason": SystemShutdown.blockReason ?? "", "panelText": panel?.text ?? "",
                                "playerCountdown": player()?.countdownText ?? ""]
        for (k, v) in counters { d[k] = v }
        if let r = info.lastResult { d["lastResult"] = "\(r)" }
        return d
    }
}

// MARK: - Countdown-Anzeige (im Vollbild-Player und im schwebenden Fenster)

/// Dünner Fortschrittsbalken (zeichnet selbst → auch in Vorschaubildern sichtbar)
final class CountdownBar: NSView {
    var fraction: Double = 1 { didSet { needsDisplay = true } }
    var track = NSColor(calibratedWhite: 0.2, alpha: 1)
    var fill = NSColor(calibratedWhite: 0.78, alpha: 1)
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = r.height / 2
        track.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        let w = max(r.height, r.width * CGFloat(max(0, min(1, fraction))))
        fill.setFill(); NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: w, height: r.height), xRadius: radius, yRadius: radius).fill()
    }
}

/// Text + Balken: „Der iMac wird in 42 Sekunden ausgeschaltet“ / „Maus bewegen oder Taste drücken zum Abbrechen.“
final class CountdownView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "Maus bewegen oder Taste drücken zum Abbrechen.")
    private let bar = CountdownBar()
    private(set) var remaining = 0
    var titleSize: CGFloat = 48 { didSet { relayout() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in [title, sub] {
            l.alignment = .center; l.isSelectable = false; l.drawsBackground = false; l.isBezeled = false
            addSubview(l)
        }
        title.textColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        sub.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        addSubview(bar)
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    var text: String { AutoShutdown.message(remaining) }

    func set(remaining: Int, fraction: Double) {
        if remaining != self.remaining || title.stringValue.isEmpty {
            self.remaining = remaining
            title.stringValue = "Der iMac wird in \(remaining) \(remaining == 1 ? "Sekunde" : "Sekunden") ausgeschaltet"
            relayout()
        }
        bar.fraction = fraction
    }

    /// Bevorzugte Größe für die aktuelle Schrift (Breite fest nach dem längsten Text, damit nichts springt)
    var preferredSize: NSSize {
        let t = longestTitleWidth, s = sub.intrinsicContentSize
        let w = ceil(max(t, s.width)) + 8
        return NSSize(width: w, height: ceil(title.intrinsicContentSize.height + titleSize * 0.35 + s.height + titleSize * 0.6 + barHeight))
    }
    private var barHeight: CGFloat { max(3, (titleSize * 0.09).rounded()) }
    private var longestTitleWidth: CGFloat {
        let f = title.font ?? .systemFont(ofSize: titleSize)
        return ("Der iMac wird in 60 Sekunden ausgeschaltet" as NSString).size(withAttributes: [.font: f]).width
    }

    private func relayout() {
        if title.font?.pointSize != titleSize { title.font = .systemFont(ofSize: titleSize, weight: .regular) }
        let subSize = max(12, (titleSize * 0.46).rounded())
        if sub.font?.pointSize != subSize { sub.font = .systemFont(ofSize: subSize, weight: .regular) }
        let size = preferredSize
        let t = title.intrinsicContentSize, s = sub.intrinsicContentSize
        let w = max(bounds.width, size.width)
        let bh = barHeight
        bar.frame = NSRect(x: ((w - size.width) / 2 + 4).rounded(), y: 0, width: size.width - 8, height: bh)
        sub.frame = NSRect(x: ((w - s.width) / 2).rounded(), y: (bh + titleSize * 0.6).rounded(), width: s.width, height: s.height)
        title.frame = NSRect(x: ((w - t.width) / 2).rounded(), y: (sub.frame.maxY + titleSize * 0.35).rounded(), width: t.width, height: t.height)
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); relayout() }
}

/// Schwebendes Fenster für den Countdown, wenn der Monitor-Modus nicht läuft (über allen Fenstern, alle Spaces).
final class CountdownPanel: NSPanel {
    private let content = CountdownView(frame: .zero)
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        content.titleSize = 30
        let cs = content.preferredSize
        let size = NSSize(width: max(560, cs.width + 64), height: cs.height + 110)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "iMac Display – Ausschalten"
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.96).cgColor
        bg.layer?.cornerRadius = 18
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
        content.frame = NSRect(x: (size.width - cs.width) / 2, y: 76, width: cs.width, height: cs.height)
        bg.addSubview(content)
        let b = NSButton(title: "Abbrechen", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.target = self
        b.action = #selector(cancelPressed)
        b.keyEquivalent = "\u{1b}"
        b.sizeToFit()
        b.frame = NSRect(x: (size.width - max(140, b.frame.width)) / 2, y: 24, width: max(140, b.frame.width), height: b.frame.height)
        bg.addSubview(b)
        contentView = bg
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }

    var text: String { content.text }

    func present() {
        let screen = NSScreen.screens.first ?? NSScreen.main
        if let f = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: (f.midX - frame.width / 2).rounded(), y: (f.midY - frame.height / 2).rounded()))
        }
        orderFrontRegardless()
    }

    func update(remaining: Int, fraction: Double) { content.set(remaining: remaining, fraction: fraction) }

    @objc private func cancelPressed() { onCancel() }
}
