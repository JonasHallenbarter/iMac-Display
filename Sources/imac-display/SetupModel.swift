import AppKit
import ServiceManagement

/// What the app itself knows (filled by AppController every refresh).
struct AppStatus {
    var bundlePath = Bundle.main.bundlePath
    var inApplications = false
    var onDiskImage = false
    var screenCaptureGranted = false
    var transmissionEnabled = true
    var serverRunning = false
    var serverError: String?
    var port: UInt16 = 8080
    var clients = 0
    var clientIP: String?
    var clientStats: [String: Any]?
    var displayActive = false
    var pixelSize = "4096×2304"
    var pointSize = "2048×1152"
    var capturing = false
    var fps = 0.0
    var mbit = 0.0
    var testPattern = false
    var loginStatus: SMAppService.Status = .notRegistered
    var dryRun = false
}

enum CheckState { case ok, warning, error, inactive, info }

struct RowAction: Identifiable {
    let id = UUID()
    let title: String
    var prominent = false
    let run: @MainActor () -> Void
}

struct CheckRow: Identifiable {
    let id: String
    var state: CheckState
    var title: String
    var detail: String
    var hint: String?
    var actions: [RowAction] = []
    var disclosureTitle: String?
    var disclosureText: String?
}

struct UninstallOptions {
    var loginItem = true
    var screenCapture = true
    var network = true
    var firewall = true
    var prefsAndLog = true
    var app = true
}

/// Everything the setup window can trigger. Implemented by AppController (no-op for previews).
@MainActor
protocol SetupActions: AnyObject {
    func moveToApplications()
    func requestScreenCapture()
    func revokeScreenCapture()
    func resetScreenCaptureEntry()
    func relaunchApp()
    func configureNetwork(service: String)
    func restoreNetwork(service: String)
    func openSettings(_ url: String)
    func setTransmission(_ on: Bool)
    func setLoginItem(_ on: Bool)
    func showLog()
    func performUninstall(_ o: UninstallOptions)
}

enum SettingsURL {
    static let screenCapture = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let localNetwork = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    static let firewall = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
    static let network = "x-apple.systempreferences:com.apple.Network-Settings.extension"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var app = AppStatus()
    @Published var probe: ProbeResult?
    @Published var showUninstall = false
    @Published var uninstall = UninstallOptions()
    /// Filled when the uninstall sheet opens: does the application firewall list this app?
    @Published var firewallEntry = false
    /// Filled when the uninstall sheet opens: network services the app changed (with saved previous setting).
    @Published var networkBackups: [String] = []
    /// Last action result, shown under the header (e.g. "Dry-Run: networksetup …").
    @Published var message: String?

    weak var actions: SetupActions?
    private var pingOKWithoutClientSince: Date?

    init(actions: SetupActions?) { self.actions = actions }

    func openUninstall() {
        uninstall = UninstallOptions()
        firewallEntry = SystemProbe.firewallListsApp(app.bundlePath)
        networkBackups = NetworkSetup.backups.keys.sorted()
        showUninstall = true
    }

    func update(app: AppStatus, probe: ProbeResult?) {
        self.app = app
        if let probe { self.probe = probe }
        if self.probe?.pingOK == true && app.clients == 0 && app.serverRunning {
            if pingOKWithoutClientSince == nil { pingOKWithoutClientSince = Date() }
        } else {
            pingOKWithoutClientSince = nil
        }
    }

    /// Forces the "Lokales Netzwerk" hint (previews).
    var forceLocalNetworkHint = false

    var localNetworkSuspect: Bool {
        if forceLocalNetworkHint { return true }
        guard #available(macOS 15.0, *), let s = pingOKWithoutClientSince else { return false }
        return Date().timeIntervalSince(s) > 15
    }

    var rows: [CheckRow] { Self.buildRows(app: app, probe: probe, localNetworkSuspect: localNetworkSuspect, actions: actions) }

    var errorRowIDs: Set<String> { Set(rows.filter { $0.state == .error }.map(\.id)) }

    var summary: (CheckState, String) {
        let r = rows
        if !app.transmissionEnabled { return (.inactive, "Übertragung ist ausgeschaltet") }
        if let e = r.first(where: { $0.state == .error }) { return (.error, "Problem: \(e.title)") }
        if app.clients > 0 && (app.capturing || app.testPattern) { return (.ok, "Läuft – der iMac zeigt den virtuellen Bildschirm") }
        if let w = r.first(where: { $0.state == .warning }) { return (.warning, "\(w.title): \(w.detail)") }
        return (.ok, "Bereit – wartet auf den iMac")
    }

    // MARK: - Rows

    static func buildRows(app: AppStatus, probe: ProbeResult?, localNetworkSuspect: Bool,
                          actions: SetupActions?) -> [CheckRow] {
        weak let a = actions
        var rows: [CheckRow] = []

        // a) App-Ort
        if app.inApplications {
            rows.append(CheckRow(id: "location", state: .ok, title: "App-Ort",
                                 detail: "Installiert in \((app.bundlePath as NSString).deletingLastPathComponent)"))
        } else {
            rows.append(CheckRow(
                id: "location", state: .warning, title: "App-Ort",
                detail: app.onDiskImage ? "Die App läuft direkt aus dem Disk-Image."
                    : "Die App läuft aus \((app.bundlePath as NSString).deletingLastPathComponent).",
                hint: "In den Ordner „Programme“ verschieben – nur dort funktionieren „Bei Anmeldung starten“ und die Berechtigungen dauerhaft.",
                actions: [RowAction(title: "In Programme verschieben", prominent: true) { a?.moveToApplications() }]))
        }

        // b) Bildschirmaufnahme
        if app.testPattern {
            rows.append(CheckRow(id: "capture", state: .inactive, title: "Bildschirmaufnahme",
                                 detail: "Testbild-Modus – keine Aufnahme nötig."))
        } else if app.screenCaptureGranted {
            rows.append(CheckRow(id: "capture", state: .ok, title: "Bildschirmaufnahme",
                                 detail: "Erlaubt.",
                                 actions: [RowAction(title: "Entziehen") { a?.revokeScreenCapture() }],
                                 disclosureTitle: "Was macht „Entziehen“?",
                                 disclosureText: "tccutil reset ScreenCapture de.local.imac-display\n"
                                    + "Entfernt nur die Berechtigung dieser App (ohne Administrator-Passwort). Danach startet iMac Display neu."))
        } else {
            rows.append(CheckRow(
                id: "capture", state: .error, title: "Bildschirmaufnahme",
                detail: "Nicht erlaubt – ohne diese Erlaubnis bleibt der iMac schwarz.",
                hint: "„Erlauben …“ klicken, in den Systemeinstellungen „iMac Display“ einschalten, dann „Neu starten“. "
                    + "Steht der Schalter dort schon auf „ein“ (z. B. nach einem Update)? Dann „Eintrag zurücksetzen“ und noch einmal erlauben.",
                actions: [RowAction(title: "Erlauben …", prominent: true) { a?.requestScreenCapture() },
                          RowAction(title: "Neu starten") { a?.relaunchApp() },
                          RowAction(title: "Eintrag zurücksetzen") { a?.resetScreenCaptureEntry() }],
                disclosureTitle: "Was passiert dabei?",
                disclosureText: "Erlauben: macOS trägt „iMac Display“ in die Liste ein – einschalten musst du selbst.\n"
                    + "Eintrag zurücksetzen: tccutil reset ScreenCapture de.local.imac-display\n"
                    + "Betrifft nur diese App, kein Administrator-Passwort nötig."))
        }

        // Server / Übertragung
        if !app.transmissionEnabled {
            rows.append(CheckRow(id: "server", state: .inactive, title: "Übertragung",
                                 detail: "Ausgeschaltet – der iMac bekommt kein Bild, im Hintergrund läuft nichts.",
                                 actions: [RowAction(title: "Einschalten", prominent: true) { a?.setTransmission(true) }]))
        } else if let e = app.serverError {
            rows.append(CheckRow(id: "server", state: .error, title: "Übertragung",
                                 detail: "Startet nicht – Port \(app.port) ist belegt oder gesperrt.",
                                 hint: "Läuft iMac Display schon ein zweites Mal (z. B. im Terminal mit run.sh)? Das andere Programm beenden, dann „Erneut versuchen“. Fehler: \(e)",
                                 actions: [RowAction(title: "Erneut versuchen") { a?.setTransmission(true) }]))
        } else {
            rows.append(CheckRow(id: "server", state: app.serverRunning ? .ok : .warning, title: "Übertragung",
                                 detail: app.serverRunning ? "Bereit – nur ein Gerät am Kabel kann sich verbinden, nicht das WLAN."
                                    : "Startet …",
                                 disclosureTitle: app.serverRunning ? "Technische Details" : nil,
                                 disclosureText: app.serverRunning ? "HTTP/WebSocket auf Port \(app.port). Erlaubt sind nur 127.0.0.1, "
                                    + "10.77.0.0/24 (Kabel) und 169.254.0.0/16 (Link-Local). Ausschalten: Schalter „Übertragung aktiv“." : nil))
        }

        // c) Ethernet-Kabel
        let chosen = probe?.chosen
        var cableUp = false
        if probe == nil {
            rows.append(CheckRow(id: "cable", state: .inactive, title: "Ethernet-Kabel", detail: "Wird geprüft …"))
        } else if let c = chosen {
            cableUp = c.linkActive
            if c.linkActive {
                let slow = c.speedText == "100 Mbit/s" || c.speedText == "10 Mbit/s"
                rows.append(CheckRow(
                    id: "cable", state: slow ? .warning : .ok, title: "Ethernet-Kabel",
                    detail: "\(c.serviceName ?? c.portName) – verbunden" + (c.speedText.map { ", \($0)" } ?? ""),
                    hint: slow ? "Nur \(c.speedText!) – für 4K mit 60 fps sind 1 Gbit/s nötig (Cat5e-Kabel, Gigabit-Adapter)." : nil))
            } else {
                rows.append(CheckRow(
                    id: "cable", state: .warning, title: "Ethernet-Kabel",
                    detail: "\(c.serviceName ?? c.portName) – kein Kabel eingesteckt oder der iMac ist aus.",
                    hint: "Kabel an beiden Macs fest einstecken; am Adapter sollte die Link-LED leuchten. Der iMac muss eingeschaltet sein."))
            }
        } else {
            rows.append(CheckRow(
                id: "cable", state: .warning, title: "Ethernet-Kabel",
                detail: "Kein Ethernet-Adapter gefunden.",
                hint: "USB-C/Thunderbolt-Ethernet-Adapter anschließen. Erscheint er auch dann nicht: Systemeinstellungen → Netzwerk prüfen.",
                actions: [RowAction(title: "Netzwerk-Einstellungen") { a?.openSettings(SettingsURL.network) }]))
        }

        // d) Netzwerkadresse 10.77.0.1
        var addressOK = false
        if let c = chosen {
            let hasAddr = c.ipv4.contains(NetworkSetup.macIP)
            let configured = probe?.chosenConfig?.isCableConfig == true
            addressOK = hasAddr
            if let svc = c.serviceName {
                let setupCmd = NetworkSetup.setupCommand(service: svc)
                let restoreCmd = NetworkSetup.restoreCommand(service: svc)
                let disclosure = """
                Einrichten (mit Administrator-Passwort):
                  \(setupCmd)
                Zurücksetzen auf \(NetworkSetup.restoreDescription(service: svc)):
                  \(restoreCmd)

                Geändert wird nur der Dienst „\(svc)“: Adresse \(NetworkSetup.macIP), Maske \(NetworkSetup.netmask), \
                kein Router. WLAN, Internet und andere Dienste bleiben unverändert.
                """
                let changedByApp = NetworkSetup.backup(for: svc) != nil
                if hasAddr || configured {
                    rows.append(CheckRow(
                        id: "address", state: .ok, title: "Netzwerkadresse \(NetworkSetup.macIP)",
                        detail: hasAddr ? "Eingerichtet auf „\(svc)“." : "Auf „\(svc)“ eingerichtet (aktiv, sobald das Kabel steckt).",
                        actions: [RowAction(title: "Zurücksetzen") { a?.restoreNetwork(service: svc) }],
                        disclosureTitle: "Was wird geändert?",
                        disclosureText: disclosure + (changedByApp ? "" : "\n\n(Diese Einstellung wurde nicht von der App gesetzt; Zurücksetzen stellt DHCP ein.)")))
                } else {
                    var detail = "Noch nicht eingerichtet – „\(svc)“ steht auf \(Self.describe(probe?.chosenConfig))."
                    if let other = probe?.addressOnOtherService { detail += " \(NetworkSetup.macIP) liegt auf \(other)." }
                    rows.append(CheckRow(
                        id: "address", state: cableUp ? .error : .warning, title: "Netzwerkadresse \(NetworkSetup.macIP)",
                        detail: detail,
                        hint: "„Einrichten“ gibt nur diesem Adapter die feste Adresse \(NetworkSetup.macIP) (ohne Router). macOS fragt nach dem Administrator-Passwort.",
                        actions: [RowAction(title: "Einrichten", prominent: true) { a?.configureNetwork(service: svc) }]
                            + (changedByApp ? [RowAction(title: "Zurücksetzen") { a?.restoreNetwork(service: svc) }] : []),
                        disclosureTitle: "Was wird geändert?", disclosureText: disclosure))
                }
            } else {
                rows.append(CheckRow(
                    id: "address", state: .warning, title: "Netzwerkadresse \(NetworkSetup.macIP)",
                    detail: "Für den Adapter „\(c.portName)“ fehlt in den Netzwerk-Einstellungen ein Eintrag.",
                    hint: "Systemeinstellungen → Netzwerk → „…“ → „Dienst hinzufügen“ → Adapter wählen; danach hier „Einrichten“.",
                    actions: [RowAction(title: "Netzwerk-Einstellungen") { a?.openSettings(SettingsURL.network) }]))
            }
            if let def = probe?.defaultRouteInterface, def == c.device {
                rows[rows.count - 1].state = .error
                rows[rows.count - 1].hint = "Das Internet läuft gerade über das Kabel statt über das WLAN. In den Netzwerk-Einstellungen beim Dienst „\(c.serviceName ?? c.device)“ das Feld „Router“ leeren – oder hier „Zurücksetzen“ und danach „Einrichten“."
            }
        } else {
            rows.append(CheckRow(id: "address", state: .inactive, title: "Netzwerkadresse \(NetworkSetup.macIP)",
                                 detail: "Wartet auf einen Ethernet-Adapter."))
        }

        // e) iMac erreichbar
        if !cableUp || !addressOK {
            rows.append(CheckRow(id: "ping", state: .inactive, title: "iMac erreichbar (\(NetworkSetup.iMacIP))",
                                 detail: cableUp ? "Erst die Netzwerkadresse einrichten." : "Wartet auf das Kabel."))
        } else if probe?.pingOK == true {
            rows.append(CheckRow(id: "ping", state: .ok, title: "iMac erreichbar (\(NetworkSetup.iMacIP))", detail: "Antwortet über das Kabel."))
        } else {
            rows.append(CheckRow(
                id: "ping", state: .warning, title: "iMac erreichbar (\(NetworkSetup.iMacIP))",
                detail: "Keine Antwort.",
                hint: "Am iMac: eingeschaltet und angemeldet? In der App „iMac Display Empfänger“ die Adresse \(NetworkSetup.iMacIP) eingerichtet? Kabel am iMac fest eingesteckt?"))
        }

        // f) iMac verbunden
        if app.clients > 0 {
            var d = "Verbunden" + (app.clientIP.map { " (\($0))" } ?? "") + (app.clients > 1 ? " – \(app.clients) Clients" : "")
            if let s = app.clientStats {
                var parts: [String] = []
                if let f = s["fps"] as? NSNumber { parts.append(String(format: "%.0f fps", f.doubleValue)) }
                if let hw = s["hw"] as? String { parts.append(hw.contains("hardware") ? "Hardware-Decoder" : (hw.contains("software") ? "Software-Decoder" : "Decoder \(hw)")) }
                if let dr = s["dropped"] as? NSNumber { parts.append("\(dr.intValue) verworfen") }
                if let ms = s["decodeMs"] as? NSNumber { parts.append(String(format: "%.0f ms Dekodieren", ms.doubleValue)) }
                if !parts.isEmpty { d += " · " + parts.joined(separator: " · ") }
            }
            rows.append(CheckRow(id: "client", state: .ok, title: "iMac verbunden", detail: d))
        } else if !app.transmissionEnabled {
            rows.append(CheckRow(id: "client", state: .inactive, title: "iMac verbunden", detail: "Übertragung ist ausgeschaltet."))
        } else if probe?.pingOK == true {
            rows.append(CheckRow(id: "client", state: .warning, title: "iMac verbunden",
                                 detail: "Der iMac ist erreichbar, zeigt aber noch nichts an.",
                                 hint: "Auf dem iMac die App „iMac Display Empfänger“ öffnen."))
        } else {
            rows.append(CheckRow(id: "client", state: .inactive, title: "iMac verbunden", detail: "Wartet auf den iMac."))
        }

        // g) Virtuelles Display
        if app.testPattern {
            rows.append(CheckRow(id: "display", state: .inactive, title: "Virtueller Bildschirm",
                                 detail: String(format: "Testbild-Modus · %.0f fps · %.0f Mbit/s", app.fps, app.mbit)))
        } else if app.displayActive {
            rows.append(CheckRow(
                id: "display", state: app.capturing ? .ok : .warning, title: "Virtueller Bildschirm",
                detail: "Aktiv: \(app.pixelSize) Pixel (\(app.pointSize) Punkte)"
                    + (app.capturing ? String(format: " · %.0f fps · %.0f Mbit/s", app.fps, app.mbit) : " · Aufnahme startet …")))
        } else {
            rows.append(CheckRow(id: "display", state: .inactive, title: "Virtueller Bildschirm",
                                 detail: app.transmissionEnabled ? "Inaktiv – wird angelegt, sobald der iMac verbunden ist."
                                    : "Inaktiv (Übertragung aus)."))
        }

        // h) Lokales Netzwerk (macOS 15+), nur bei Verdacht
        if localNetworkSuspect {
            rows.append(CheckRow(
                id: "localnet", state: .warning, title: "Lokales Netzwerk",
                detail: "Der iMac antwortet, verbindet sich aber seit über 15 s nicht.",
                hint: "Datenschutz & Sicherheit → Lokales Netzwerk → „iMac Display“ erlauben. Danach auf dem iMac den Empfänger neu starten.",
                actions: [RowAction(title: "Einstellungen öffnen") { a?.openSettings(SettingsURL.localNetwork) }]))
        }

        // i) Firewall (nur Info)
        if let p = probe, let on = p.firewallOn {
            if p.firewallBlockAll == true {
                rows.append(CheckRow(
                    id: "firewall", state: .error, title: "Firewall",
                    detail: "„Alle eingehenden Verbindungen blockieren“ ist an – der iMac kann sich nicht verbinden.",
                    hint: "Systemeinstellungen → Netzwerk → Firewall → Optionen: diese Einstellung ausschalten.",
                    actions: [RowAction(title: "Firewall-Einstellungen") { a?.openSettings(SettingsURL.firewall) }]))
            } else {
                rows.append(CheckRow(
                    id: "firewall", state: .info, title: "Firewall",
                    detail: on ? "Eingeschaltet. Beim ersten Verbinden fragt macOS, ob „iMac Display“ eingehende Verbindungen annehmen darf → „Erlauben“."
                        : "Ausgeschaltet – keine Einstellung nötig."))
            }
        }
        return rows
    }

    static func describe(_ c: ServiceIPv4Config?) -> String {
        guard let c else { return "unbekannt" }
        switch c.mode {
        case .dhcp: return "automatisch (DHCP)"
        case .manual: return "manuell \(c.ip ?? "")"
        case .manualWithDHCPRouter: return "manuell mit DHCP-Router"
        case .bootp: return "BOOTP"
        case .off: return "IPv4 aus"
        case .unknown: return "unbekannt"
        }
    }
}

// MARK: - Self-test (--selftest-setup): read-only probes + dry-run of all changing commands

private func describe(_ c: ServiceIPv4Config) -> String {
    "\(c.mode.rawValue)" + (c.ip.map { " \($0)" } ?? "") + (c.subnet.map { "/\($0)" } ?? "")
        + (c.router.map { " Router \($0)" } ?? "") + (c.clientID.map { " Client-ID \($0)" } ?? "")
}

@MainActor
func runSetupSelftest() -> Int32 {
    print("Einrichtung – Selbsttest (Dry-Run, es wird nichts geändert)")
    let t0 = Date()
    let p = SystemProbe.probe()
    print(String(format: "Prüfung dauerte %.2f s", Date().timeIntervalSince(t0)))
    print("Kabel-Adapter (Kandidaten):")
    for w in p.wired {
        print("  \(w.displayName) port=\"\(w.portName)\" service=\(w.serviceName ?? "-") link=\(w.linkActive) "
              + "media=\(w.media ?? "-") speed=\(w.speedText ?? "-") ipv4=\(w.ipv4)")
    }
    print("Gewählt: \(p.chosen?.displayName ?? "keiner"); Konfiguration: \(p.chosenConfig.map { "\($0.mode.rawValue) \($0.ip ?? "")" } ?? "-")")
    print("Ping: \(p.pingOK.map { "\($0)" } ?? "nicht versucht"); Firewall an: \(p.firewallOn.map { "\($0)" } ?? "?"); "
          + "alles blockieren: \(p.firewallBlockAll.map { "\($0)" } ?? "?"); Standardroute über: \(p.defaultRouteInterface ?? "?")")
    // Without a plugged-in adapter: test the command path with an existing (inactive) service name.
    let fallback = ProcessInfo.processInfo.environment["IMAC_DISPLAY_TEST_SERVICE"]
    var ok = true
    if let svc = fallback ?? p.chosen?.serviceName {
        print("Dienst für Befehlstest: \(svc)")
        NetworkSetup.clearBackup(service: svc)
        print("Aktuelle Einstellung: \(SystemProbe.serviceConfig(svc).map { describe($0) } ?? "nicht lesbar")")
        print("Befehl Einrichten:   \(NetworkSetup.setupCommand(service: svc))")
        print("Befehl Zurücksetzen (ohne Sicherung): \(NetworkSetup.restoreCommand(service: svc))")
        let r1 = NetworkSetup.configure(service: svc)
        print("Einrichten → \(r1)")
        print("Gesicherte Einstellung (Dry-Run-Schlüssel): \(NetworkSetup.backup(for: svc).map { describe($0) } ?? "-")")
        print("Befehl Zurücksetzen nach Sicherung: \(NetworkSetup.restoreCommand(service: svc))")
        let r2 = NetworkSetup.restore(service: svc)
        print("Zurücksetzen → \(r2)")
        let cleared = NetworkSetup.backup(for: svc) == nil
        print("Sicherung nach Zurücksetzen: \(cleared ? "gelöscht" : "noch da")")
        ok = ok && cleared
    }
    // Unknown service: nothing may happen (no backup, no command)
    if case .failed(let e) = NetworkSetup.configure(service: "Gibt es nicht 4711") {
        print("Unbekannter Dienst → abgelehnt: \(e)")
    } else { print("FEHLER: unbekannter Dienst wurde nicht abgelehnt"); ok = false }
    // Restore commands for every kind of saved setting
    let svc = "USB 10/100/1000 LAN"
    let cases: [(ServiceIPv4Config?, String)] = [
        (nil, "-setdhcp 'USB 10/100/1000 LAN'"),
        (.init(service: svc, mode: .dhcp, raw: ""), "-setdhcp 'USB 10/100/1000 LAN'"),
        (.init(service: svc, mode: .dhcp, raw: "", clientID: "mbp"), "-setdhcp 'USB 10/100/1000 LAN' 'mbp'"),
        (.init(service: svc, mode: .manual, ip: "192.168.5.2", subnet: "255.255.255.0", router: "192.168.5.1", raw: ""),
         "-setmanual 'USB 10/100/1000 LAN' 192.168.5.2 255.255.255.0 192.168.5.1"),
        (.init(service: svc, mode: .manual, ip: "192.168.5.2", subnet: "255.255.0.0", raw: ""),
         "-setmanual 'USB 10/100/1000 LAN' 192.168.5.2 255.255.0.0"),
        (.init(service: svc, mode: .manualWithDHCPRouter, ip: "192.168.5.9", raw: ""),
         "-setmanualwithdhcprouter 'USB 10/100/1000 LAN' 192.168.5.9"),
        (.init(service: svc, mode: .bootp, raw: ""), "-setbootp 'USB 10/100/1000 LAN'"),
        (.init(service: svc, mode: .off, raw: ""), "-setv4off 'USB 10/100/1000 LAN'"),
        (.init(service: svc, mode: .manual, ip: NetworkSetup.macIP, subnet: NetworkSetup.netmask, raw: ""),
         "-setdhcp 'USB 10/100/1000 LAN'"),
    ]
    for (b, want) in cases {
        let got = NetworkSetup.restoreCommand(service: svc, backup: b)
        let good = got == "/usr/sbin/networksetup " + want
        ok = ok && good
        print("  Zurücksetzen bei \(b.map { describe($0) } ?? "keiner Sicherung"): \(got) \(good ? "OK" : "FEHLER (erwartet \(want))")")
    }
    let setup = NetworkSetup.setupCommand(service: "Ethernet 'A'")
    print("  Einrichten mit Sonderzeichen: \(setup)")
    ok = ok && setup == #"/usr/sbin/networksetup -setmanual 'Ethernet '\''A'\''' 10.77.0.1 255.255.255.0"#
    print("  Firewall-Eintrag entfernen: \(Firewall.removeCommand(appPath: "/Applications/iMac Display.app"))")
    print("Befehl Entziehen: /usr/bin/tccutil \(AppController.tccResetArguments(bundleID: Bundle.main.bundleIdentifier ?? "de.local.imac-display").joined(separator: " "))")
    var app = AppStatus()
    app.inApplications = false
    app.screenCaptureGranted = CGPreflightScreenCaptureAccess()
    app.serverRunning = true
    let rows = SetupModel.buildRows(app: app, probe: p, localNetworkSuspect: false, actions: nil)
    print("Checkliste:")
    for r in rows {
        print("  [\(r.state)] \(r.title): \(r.detail)" + (r.hint.map { "\n        Was tun? \($0)" } ?? "")
              + (r.actions.isEmpty ? "" : "\n        Buttons: " + r.actions.map(\.title).joined(separator: ", ")))
    }
    // Parser checks with canned networksetup output
    let manual = ServiceIPv4Config.parse(service: "X", output: "Manual Configuration\nIP address: 10.77.0.1\nSubnet mask: 255.255.255.0\nRouter: none\n")
    let dhcp = ServiceIPv4Config.parse(service: "X", output: "DHCP Configuration\nClient ID: \nIPv6: Automatic\n")
    let mr = ServiceIPv4Config.parse(service: "X", output: "Manual Configuration\nIP address: 192.168.5.2\nSubnet mask: 255.255.255.0\nRouter: 192.168.5.1\n")
    let dhcpID = ServiceIPv4Config.parse(service: "X", output: "DHCP Configuration\nClient ID: mbp\n")
    let parserOK = manual.isCableConfig && manual.router == nil && dhcp.mode == .dhcp && dhcp.clientID == nil
        && dhcpID.clientID == "mbp" && mr.router == "192.168.5.1" && !mr.isCableConfig
    print("Parser: \(parserOK ? "OK" : "FEHLER")")
    ok = ok && parserOK
    print(ok ? "SELBSTTEST OK" : "SELBSTTEST FEHLGESCHLAGEN")
    return ok ? 0 : 1
}
