import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import ServiceManagement

// MARK: - CLI

struct CLIOptions {
    var width = 4096
    var height = 2304
    var fps = 60
    var bitrate = 100.0
    var port: UInt16 = 8080
    var hiDPI = true
    var allowAnyNetwork = false
    var name = "iMac 4K (Ethernet)"
    var webPath: String?
    var selftestEncoder = false
    var testPattern = false
    /// Virtuelles Display dauerhaft halten (statt nur, solange ein iMac verbunden ist).
    var alwaysOn = false
    /// Sekunden ohne Client, nach denen das virtuelle Display entfernt wird.
    var idleTimeout = 10.0
    /// Testbild-Fenster auf dem virtuellen Display zeigen.
    var demoWindow = false
    /// Menüleisten-App-Modus erzwingen (Standard: nur im .app-Bundle ohne Argumente).
    var forceApp = false
    var unregisterLoginItem = false
    var demoSnapshotPath: String?
    /// Einrichtungsfenster auch im CLI-Modus öffnen.
    var setupWindow = false
    /// Systemänderungen (Netzwerk, Berechtigungen, Anmeldeobjekt, Deinstallation) nur protokollieren.
    var dryRun = false
    var renderSetupPreviewDir: String?
    var selftestSetup = false
    var testUninstall = false
    /// Test: alle Knöpfe des Einrichtungsfensters im Dry-Run nacheinander auslösen, dann beenden.
    var testActions = false
    /// Test: virtuelles Display an-/abbauen, aber nichts aufnehmen (ohne Bildschirmaufnahme-Berechtigung testbar).
    var noCapture = false
    /// CLI: erst nach „Verbinden“ verbinden (Wunsch wird gespeichert) – wie die App. Standard im CLI: automatisch.
    var manualConnect = false
    /// Verbindungswunsch beim Start auf „an“ setzen (Test).
    var connect = false
    /// Eigene UserDefaults-Domäne (Test), damit die Einstellungen der installierten App unberührt bleiben.
    var defaultsSuite: String?
    /// App-Modus: Protokoll in diese Datei statt ~/Library/Logs/iMacDisplay.log (Test).
    var logFile: String?
    /// Test: Befehle auf stdin (state, press, connect, disconnect, brightness …).
    var testStdin = false
    /// Seriennummer des virtuellen Displays (Test neben der installierten App: muss sich unterscheiden).
    var displaySerial: UInt32 = 0x0A770001
}

let usage = """
Verwendung: imac-display [Optionen]

  --width <px>          Pixelbreite des virtuellen Displays (Standard 4096)
  --height <px>         Pixelhöhe des virtuellen Displays (Standard 2304)
  --fps <n>             Bildrate (Standard 60)
  --bitrate <Mbit/s>    H.264-Bitrate (Standard 100)
  --port <n>            HTTP/WebSocket-Port (Standard 8080)
  --no-hidpi            Kein HiDPI: Punkte = Pixel (Standard: HiDPI, 2048x1152 Punkte)
  --allow-any-network   Verbindungen aus allen Netzen erlauben (Standard: nur Loopback,
                        10.77.0.0/24, 169.254.0.0/16)
  --name <text>         Name des Displays (Standard "iMac 4K (Ethernet)")
  --web <pfad>          index.html von diesem Pfad statt aus dem Bundle laden (Entwicklung)
  --always-on           Virtuelles Display dauerhaft anlegen (Standard: nur solange ein iMac
                        verbunden ist; 10 s nach der letzten Verbindung wird es entfernt)
  --idle-timeout <s>    Sekunden ohne iMac bis zum Entfernen des Displays (Standard 10)
  --demo-window         Schärfe-/Bewegungs-Testbild auf dem virtuellen Display anzeigen
  --app                 Als Menüleisten-App laufen (Standard, wenn das .app ohne Argumente startet)
  --selftest-encoder    Nur den H.264-Encoder mit synthetischen Bildern testen und beenden
  --selftest-quality    Qualitätstest (QualityLab) ausführen und beenden
  --test-pattern        Kein virtuelles Display/keine Aufnahme: synthetisches Testbild streamen
                        (Test von Server/Browser ohne Bildschirmaufnahme-Berechtigung)
  --no-capture          Test: Display an-/abbauen, aber keine Bildschirmaufnahme starten
  --manual-connect      Erst nach „Verbinden“ verbinden, Wunsch wird gespeichert (wie die App;
                        Standard im Terminal: automatisch verbinden, sobald der iMac da ist)
  --connect             Verbindungswunsch beim Start einschalten
  --defaults-suite <n>  Einstellungen in der Domäne <n> statt der Standard-Domäne (Test)
  --log-file <pfad>     App-Modus: Protokoll in diese Datei (Test; Standard ~/Library/Logs/iMacDisplay.log)
  --display-serial <hex> Seriennummer des virtuellen Displays (Test neben der installierten App;
                        Standard 0A770001)
  --test-stdin          Test: Befehle auf stdin (state, press, connect, disconnect, brightness <0…1>,
                        drag, step, menu, menuclick <Titel>, transmission on|off, quit)
  --setup-window        Fenster „Einrichtung & Status“ beim Start öffnen (auch im CLI-Modus)
  --dry-run             Systemänderungen (Netzwerk, Berechtigung, Anmeldeobjekt, Deinstallation) nur
                        protokollieren (auch per Umgebungsvariable IMAC_DISPLAY_DRY_RUN=1)
  --selftest-setup      Systemprüfungen der Einrichtung ausgeben (Dry-Run) und beenden
  --unregister-login-item  Anmeldeobjekt (Start bei Anmeldung) entfernen und beenden
  --test-actions-dry-run   Test: alle Knöpfe der Einrichtung im Dry-Run auslösen, dann beenden
                        (Netzwerkdienst für den Test: IMAC_DISPLAY_TEST_SERVICE="<Dienstname>")
  --test-uninstall-dry-run Test: Deinstallation im Dry-Run
  Signal USR1 (kill -USR1 <pid>) schaltet „Übertragung aktiv“ um (Test).
  Signal USR2 (kill -USR2 <pid>) drückt den großen Knopf: „Verbinden“ bzw. „Trennen“ (Test).
  -h, --help            Diese Hilfe

"""

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func parseCLI(_ args: [String]) -> CLIOptions {
    var o = CLIOptions()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("Fehlender Wert für \(flag)\n\n" + usage) }
        return args[i]
    }
    func int(_ flag: String, _ range: ClosedRange<Int>) -> Int {
        let v = value(flag)
        guard let n = Int(v), range.contains(n) else { fail("Ungültiger Wert für \(flag): \(v)") }
        return n
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--width": o.width = int(a, 64...8192)
        case "--height": o.height = int(a, 64...8192)
        case "--fps": o.fps = int(a, 1...240)
        case "--bitrate":
            let v = value(a)
            guard let d = Double(v), d > 0, d <= 1000 else { fail("Ungültiger Wert für --bitrate: \(v)") }
            o.bitrate = d
        case "--port": o.port = UInt16(int(a, 1...65535))
        case "--no-hidpi": o.hiDPI = false
        case "--allow-any-network": o.allowAnyNetwork = true
        case "--name": o.name = value(a)
        case "--web": o.webPath = value(a)
        case "--always-on": o.alwaysOn = true
        case "--idle-timeout": o.idleTimeout = Double(int(a, 1...86400))
        case "--demo-window": o.demoWindow = true
        case "--app": o.forceApp = true
        case "--selftest-encoder": o.selftestEncoder = true
        case "--test-pattern": o.testPattern = true
        case "--unregister-login-item": o.unregisterLoginItem = true
        case "--demo-snapshot": o.demoSnapshotPath = value(a) // Entwicklung: Testbild als PNG rendern
        case "--no-capture": o.noCapture = true
        case "--setup-window": o.setupWindow = true
        case "--dry-run": o.dryRun = true
        case "--render-setup-preview": o.renderSetupPreviewDir = value(a) // Entwicklung: Screenshots des Einrichtungsfensters
        case "--selftest-setup": o.selftestSetup = true
        case "--test-uninstall-dry-run": o.testUninstall = true; o.dryRun = true
        case "--test-actions-dry-run": o.testActions = true; o.dryRun = true
        case "--manual-connect": o.manualConnect = true
        case "--connect": o.connect = true
        case "--defaults-suite": o.defaultsSuite = value(a)
        case "--log-file": o.logFile = value(a)
        case "--test-stdin": o.testStdin = true
        case "--display-serial":
            let v = value(a)
            guard let n = UInt32(v.hasPrefix("0x") ? String(v.dropFirst(2)) : v, radix: 16) else { fail("Ungültiger Wert für --display-serial: \(v)") }
            o.displaySerial = n
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("Unbekannte Option: \(a)\n\n" + usage)
        }
        i += 1
    }
    if o.hiDPI && (o.width % 2 != 0 || o.height % 2 != 0) { fail("Bei HiDPI müssen Breite und Höhe gerade sein.") }
    return o
}

// MARK: - Network helpers

func ipv4Addresses() -> [(iface: String, ip: String)] {
    var result: [(String, String)] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        let ifa = cur.pointee
        if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") { result.append((String(cString: ifa.ifa_name), ip)) }
            }
        }
        p = ifa.ifa_next
    }
    return result
}

func printURLs(port: UInt16) {
    let addrs = ipv4Addresses()
    print("")
    print("Auf dem iMac in Chrome öffnen:")
    if let a = addrs.first(where: { $0.ip == "10.77.0.1" }) {
        print("  >>> http://10.77.0.1:\(port)/   (Ethernet, \(a.iface)) <<<")
    } else {
        let ll = addrs.filter { $0.ip.hasPrefix("169.254.") }
        if ll.isEmpty {
            print("  (10.77.0.1 ist nicht konfiguriert – Ethernet-Kabel/statische IP prüfen)")
        } else {
            print("  (10.77.0.1 nicht gefunden, Link-Local-Adresse verwenden:)")
            for a in ll { print("  >>> http://\(a.ip):\(port)/   (\(a.iface)) <<<") }
        }
    }
    let others = addrs.filter { $0.ip != "10.77.0.1" && !$0.ip.hasPrefix("169.254.") }
    if !others.isEmpty {
        print("  Weitere Adressen (nur mit --allow-any-network erreichbar):")
        for a in others { print("    http://\(a.ip):\(port)/   (\(a.iface))") }
    }
    print("  Lokaler Test auf diesem Mac: http://127.0.0.1:\(port)/")
    print("")
}

// MARK: - Synthetic frames (encoder self-test, --test-pattern)

func makeNV12Buffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    let st = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                 attrs as CFDictionary, &pb)
    guard st == kCVReturnSuccess, let pb else { fail("CVPixelBufferCreate fehlgeschlagen (\(st))", code: 1) }
    CVPixelBufferLockBaseAddress(pb, [])
    // Cheap pattern (memset per row): moving diagonal-ish bands + a moving block, so frames differ.
    let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    for row in 0..<height {
        let line = y + row * yStride
        memset(line, Int32(16 + ((row / 4 + frame * 8) & 0xFF) * 219 / 255), width)
        let bx = (frame * 97 + row / 64 * 131) % max(1, width - 256)
        memset(line + bx, 235, 256)
    }
    let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    for row in 0..<(height / 2) {
        memset(uv + row * uvStride, Int32(64 + ((row / 32 + frame * 4) & 0x7F)), width)
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

// MARK: - Encoder self-test

func runEncoderSelftest(_ o: CLIOptions) -> Never {
    print("Encoder-Selbsttest: \(o.width)x\(o.height) @ \(o.fps) fps, \(o.bitrate) Mbit/s")
    let enc = H264Encoder(settings: .init(fps: o.fps, bitrateMbit: o.bitrate))
    let lock = NSLock()
    var outputs: [(key: Bool, size: Int, ts: UInt64, head: String)] = []
    var configs: [String] = []
    enc.onConfig = { d in lock.lock(); configs.append(String(data: d, encoding: .utf8)!); lock.unlock() }
    enc.onFrame = { data, key, ts in
        let head = data.prefix(5).map { String(format: "%02x", $0) }.joined(separator: " ")
        lock.lock(); outputs.append((key, data.count, ts, head)); lock.unlock()
    }
    print("Erzeuge synthetische NV12-Bilder ...")
    let buffers = (0..<8).map { makeNV12Buffer(width: o.width, height: o.height, frame: $0) }
    let n = 60
    let start = CMClockGetTime(CMClockGetHostTimeClock())
    let t0 = Date()
    var callTime = 0.0
    for i in 0..<n {
        let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(i), timescale: CMTimeScale(o.fps)))
        let c0 = Date()
        enc.queue.sync { enc.encode(buffers[i % buffers.count], pts: pts) }
        if i > 0 { callTime += Date().timeIntervalSince(c0) }
        Thread.sleep(forTimeInterval: 1.0 / Double(o.fps))
    }
    Thread.sleep(forTimeInterval: 0.3)
    let encodeTime = Date().timeIntervalSince(t0)
    lock.lock(); let normalCount = outputs.count; lock.unlock()

    print("Keyframe-Anfrage ohne neue Bilder (statischer Bildschirm) ...")
    enc.requestKeyframe()
    Thread.sleep(forTimeInterval: 0.3)
    lock.lock(); let afterKeyReq = outputs.count; let gotKey = outputs.last?.key ?? false; lock.unlock()

    print("Leerlauf-Wiederholung (1,5 s warten) ...")
    enc.startIdleRefresh()
    Thread.sleep(forTimeInterval: 1.5)
    enc.stop()

    lock.lock(); defer { lock.unlock() }
    for (i, f) in outputs.enumerated() where i < 5 || f.key || i >= outputs.count - 3 {
        print(String(format: "  #%03d %@ %8d Bytes  ts=%9llu us  [%@]", i, f.key ? "KEY  " : "delta", f.size, f.ts, f.head))
    }
    let bytes = outputs.reduce(0) { $0 + $1.size }
    let monotonic = zip(outputs, outputs.dropFirst()).allSatisfy { $0.ts < $1.ts }
    print("Configs: \(configs)")
    print("Ausgabe: \(outputs.count) Frames (\(normalCount) normal in \(String(format: "%.2f", encodeTime)) s), "
          + "\(outputs.filter { $0.key }.count) Keyframes, \(bytes) Bytes, Zeitstempel monoton: \(monotonic)")
    print(String(format: "Mittlere Dauer pro EncodeFrame-Aufruf: %.1f ms", callTime / Double(n - 1) * 1000))
    print("Keyframe auf Anfrage (gecachter Buffer): \(afterKeyReq > normalCount && gotKey ? "OK" : "FEHLT")")
    print("Leerlauf-Wiederholung: \(outputs.count > afterKeyReq ? "OK" : "FEHLT")")
    let ok = !configs.isEmpty && outputs.first?.key == true && outputs.first?.head.hasPrefix("00 00 00 01") == true && (outputs.first.map { UInt8($0.head.suffix(2), radix: 16)! & 0x1F } == 7)
        && afterKeyReq > normalCount && gotKey && monotonic
    print(ok ? "SELBSTTEST OK" : "SELBSTTEST FEHLGESCHLAGEN")
    exit(ok ? 0 : 1)
}

// MARK: - index.html

/// SwiftPM's generated `Bundle.module` looks for `<Bundle.main.bundleURL>/imac-display_imac-display.bundle`
/// (= next to the executable for a CLI, but the *root* of an .app – where codesign rejects unsealed files)
/// and otherwise falls back to the absolute build path, with a fatalError if neither exists.
/// So: in the .app the page lives in Contents/Resources/index.html (Bundle.main); Bundle.module is only
/// used outside an app bundle (CLI from .build/…).
func loadIndexHTML(webPath: String?, inAppBundle: Bool) -> Data? {
    if let webPath {
        guard let d = FileManager.default.contents(atPath: webPath) else { fail("Kann \(webPath) nicht lesen") }
        return d
    }
    var candidates: [URL] = []
    if let u = Bundle.main.url(forResource: "index", withExtension: "html") { candidates.append(u) }
    if let r = Bundle.main.resourceURL {
        candidates.append(r.appendingPathComponent("imac-display_imac-display.bundle/index.html"))
    }
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("imac-display_imac-display.bundle/index.html"))
    }
    for c in candidates {
        if let d = try? Data(contentsOf: c) { return d }
    }
    if !inAppBundle, let u = Bundle.module.url(forResource: "index", withExtension: "html") {
        return try? Data(contentsOf: u)
    }
    return nil
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)
let rawArgs = Array(CommandLine.arguments.dropFirst())
if rawArgs.contains("--selftest-quality") {
    exit(QualityLab.run(arguments: CommandLine.arguments))
}
// Finder/LaunchServices may add "-psn_0_12345" (older macOS); Xcode adds "-NSDocumentRevisionsDebugMode YES".
var cliArgs: [String] = []
do {
    var i = 0
    while i < rawArgs.count {
        let a = rawArgs[i]
        if a.hasPrefix("-psn_") { i += 1; continue }
        if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 2; continue }
        cliArgs.append(a); i += 1
    }
}
let inAppBundle = Bundle.main.bundleURL.pathExtension == "app"
var opts = parseCLI(cliArgs)
let appMode = opts.forceApp || (inAppBundle && cliArgs.isEmpty)

if opts.selftestEncoder { runEncoderSelftest(opts) }
if opts.dryRun { DryRun.forced = true }
if opts.selftestSetup { DryRun.forced = true; MainActor.assumeIsolated { exit(runSetupSelftest()) } }
if let dir = opts.renderSetupPreviewDir {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.accessory)
        exit(SetupPreview.render(to: dir))
    }
}

if opts.unregisterLoginItem {
    if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
        print("Kein Anmeldeobjekt registriert (\(Bundle.main.bundlePath)).")
        exit(0)
    }
    do {
        try SMAppService.mainApp.unregister()
        print("Anmeldeobjekt entfernt (\(Bundle.main.bundlePath)).")
    } catch {
        print("Anmeldeobjekt nicht entfernt: \(error.localizedDescription)")
    }
    exit(0)
}

if appMode, opts.defaultsSuite == nil, let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    // Zweiter Start (z. B. eine Kopie aus dem Disk-Image): Fenster der laufenden Instanz öffnen, selbst beenden.
    // Vor AppLog.startFileLogging, damit das Protokoll der laufenden Instanz nicht geleert wird.
    print("iMac Display läuft bereits – dort wird „Einrichtung & Status“ geöffnet, diese Instanz beendet sich.")
    DistributedNotificationCenter.default().postNotificationName(showSetupNotification, object: nil,
                                                                userInfo: nil, deliverImmediately: true)
    exit(0)
}

if appMode {
    // Einstellungen für den App-Modus (optional): defaults write de.local.imac-display bitrate -float 80
    let ud = opts.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    if let v = ud.object(forKey: "fps") as? NSNumber, (1...240).contains(v.intValue) { opts.fps = v.intValue }
    if let v = ud.object(forKey: "bitrate") as? NSNumber, v.doubleValue > 0, v.doubleValue <= 1000 { opts.bitrate = v.doubleValue }
    AppLog.startFileLogging(path: opts.logFile ?? AppLog.defaultPath)
    logLine("iMac Display \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") gestartet (App-Modus, \(Bundle.main.bundlePath))")
}

if let path = opts.demoSnapshotPath {
    MainActor.assumeIsolated {
        let ok = DemoView.writeSnapshot(to: path, pointSize: CGSize(width: opts.width / (opts.hiDPI ? 2 : 1),
                                                                     height: opts.height / (opts.hiDPI ? 2 : 1)),
                                        scale: opts.hiDPI ? 2 : 1)
        print(ok ? "Testbild gespeichert: \(path)" : "Testbild konnte nicht gespeichert werden")
        exit(ok ? 0 : 1)
    }
}

guard let indexHTML = loadIndexHTML(webPath: opts.webPath, inAppBundle: inAppBundle) else {
    logLine("FEHLER: index.html nicht gefunden (weder in Contents/Resources noch im SwiftPM-Ressourcenbundle)")
    exit(1)
}

MainActor.assumeIsolated {
    let controller = AppController(options: opts, appMode: appMode, indexHTML: indexHTML)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
}
