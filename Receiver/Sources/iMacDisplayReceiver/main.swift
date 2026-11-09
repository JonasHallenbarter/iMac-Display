import AppKit
import Foundation

// iMac Display – Empfänger
//
//   (ohne Argumente)          Fenster mit Checkliste
//   --monitor                 direkt Monitor-Modus (so startet der Autostart): Bild des MacBooks im Vollbild
// Nur für Tests/Entwicklung:
//   --host <ip:port>          anderes Ziel statt 10.77.0.1:8080 (auch IMAC_RECEIVER_HOST)
//   --probe-decoder           Probedekodierung 4096×2304 ausgeben
//   --print-status            Checkliste als Text ausgeben
//   --render-preview <Ordner> Vorschaubilder der Checkliste als PNG
//   --autostart on|off|status LaunchAgent schreiben/entfernen (respektiert IMAC_RECEIVER_HOME/_LAUNCHCTL)
//   --network setup|reset     Netzwerk-Aktion (nur mit IMAC_RECEIVER_DRY_RUN=1)
//   --uninstall               alle Deinstallations-Schritte (nur mit IMAC_RECEIVER_DRY_RUN=1)
// Test-Umgebung (siehe TestHooks.swift / Player.swift): IMAC_RECEIVER_WINDOW=WxH (Fenster statt Vollbild),
//   IMAC_RECEIVER_SCREEN=n, IMAC_RECEIVER_RENDERER=vt, IMAC_RECEIVER_TEST_STATS=<datei>, IMAC_RECEIVER_TEST_VERIFY=1,
//   IMAC_RECEIVER_TEST_CORRUPT=n

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func requireDryRun(_ what: String) {
    if !Config.dryRun {
        FileHandle.standardError.write("\(what) über die Kommandozeile nur mit IMAC_RECEIVER_DRY_RUN=1 (Testmodus).\n".data(using: .utf8)!)
        exit(2)
    }
}
func currentFactsWithReach() -> Facts {
    let sem = DispatchSemaphore(value: 0)
    var st: ReachState = .unknown
    var req = URLRequest(url: URL(string: "http://\(Config.host)/")!)
    req.timeoutInterval = 1
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]
    URLSession(configuration: c).dataTask(with: req) { _, resp, err in
        if let h = resp as? HTTPURLResponse { st = .ok(h.statusCode) } else { st = .fail(err?.localizedDescription ?? "?") }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 3)
    return Facts.current(monitor: .off, reach: st)
}

if args.contains("--print-status") {
    DecoderProbe.runNow()
    print(Checks.text(Checks.build(currentFactsWithReach())))
    exit(0)
}
if args.contains("--probe-decoder") {
    print("Probedekodierung H.264 \(DecoderProbe.width)×\(DecoderProbe.height): \(DecoderProbe.run())")
    exit(0)
}
if let v = argValue("--autostart") {
    switch v {
    case "on": do { try Autostart.enable() } catch { print("Fehler: \(error)"); exit(1) }
    case "off": Autostart.disable()
    default: break
    }
    print("Autostart: \(Autostart.state())")
    Log.flush()
    exit(0)
}
if let v = argValue("--network") {
    requireDryRun("--network")
    let f = Facts.current(monitor: .off, reach: .unknown)
    guard let p = f.primary else { print("Kein Ethernet-Anschluss"); exit(1) }
    let r = v == "setup" ? NetworkChanger.setup(p) : NetworkChanger.reset(service: p.service ?? "?")
    print("\(r.ok ? "OK" : "FEHLER"): \(r.message)")
    print("Backup: \(NetworkBackup.load().map { "\($0.service): \($0.previous.summary)" } ?? "keins")")
    Log.flush()
    exit(r.ok ? 0 : 1)
}
if args.contains("--uninstall") {
    requireDryRun("--uninstall")
    let m = AppModel()
    m.refresh(quick: true)
    m.runUninstall(UninstallOptions())
    exit(0)
}
if let dir = argValue("--render-preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    PreviewRenderer.render(to: URL(fileURLWithPath: dir))
    exit(0)
}

let app = NSApplication.shared
// Monitor-Modus beim Start: per Autostart (--monitor) – oder wenn Autostart an ist und macOS die App kurz nach
// dem Hochfahren selbst wieder öffnet („Fenster beim erneuten Anmelden wieder öffnen“, ohne --monitor).
let openedAfterBoot = Autostart.state() == .on && ProcessInfo.processInfo.systemUptime < 600
let delegate = AppDelegate(monitorAtLaunch: args.contains("--monitor") || openedAfterBoot)
app.delegate = delegate
app.setActivationPolicy(.regular)
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { NSApp.terminate(nil) }   // sauber beenden (Assertions freigeben, Protokoll)
termSource.resume()
app.run()
