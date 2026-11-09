import AppKit
import Foundation
import IOKit.pwr_mgt
import SystemConfiguration

// MARK: - Netzwerk

struct IPv4Config: Codable, Equatable {
    var method: String            // DHCP, Manual, BOOTP, INFORM, …
    var addresses: [String] = []
    var masks: [String] = []
    var router: String?

    init(method: String, addresses: [String] = [], masks: [String] = [], router: String? = nil) {
        self.method = method; self.addresses = addresses; self.masks = masks; self.router = router
    }
    /// tolerant: fehlende Felder → leer (Sicherung bleibt lesbar)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(String.self, forKey: .method)
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        masks = try c.decodeIfPresent([String].self, forKey: .masks) ?? []
        router = try c.decodeIfPresent(String.self, forKey: .router)
    }

    var isOurs: Bool { method == "Manual" && addresses.first == Config.myIP }
    var summary: String {
        switch method {
        case "DHCP": return "automatisch (DHCP)"
        case "Manual":
            return "manuell \(addresses.first ?? "?") / \(masks.first ?? "?")" + (router.map { ", Router \($0)" } ?? ", ohne Router")
        case "INFORM": return "DHCP mit manueller Adresse \(addresses.first ?? "?")"
        case "BOOTP": return "BOOTP"
        case "Off": return "IPv4 aus"
        default: return method
        }
    }
}

struct WiredInterface: Equatable {
    var bsd: String
    var name: String
    var linkActive: Bool
    var ipv4: [String]
    var service: String?
    var config: IPv4Config?
    var hasOurIP: Bool { ipv4.contains(Config.myIP) }
}

enum Network {
    private static let excluded = ["Wi-Fi", "WLAN", "AirPort", "Bluetooth", "Thunderbolt", "iPhone", "iPad", "VPN", "Tailscale"]

    static func wiredInterfaces() -> [WiredInterface] {
        if let fake = Config.env["IMAC_RECEIVER_FAKE_NET"] { return fakeInterfaces(fake) }
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        let store = SCDynamicStoreCreate(nil, "iMacDisplayReceiver" as CFString, nil, nil)
        let services = serviceInfo()
        let addrs = ipv4Addresses()
        var result: [WiredInterface] = []
        for i in all {
            guard let type = SCNetworkInterfaceGetInterfaceType(i) as String?, type == (kSCNetworkInterfaceTypeEthernet as String),
                  let bsd = SCNetworkInterfaceGetBSDName(i) as String?, bsd.hasPrefix("en") else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            if excluded.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
            var active = false
            if let store, let d = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bsd)/Link" as CFString) as? [String: Any] {
                active = (d["Active"] as? Bool) ?? false
            }
            let svc = services[bsd]
            result.append(WiredInterface(bsd: bsd, name: name, linkActive: active, ipv4: addrs[bsd] ?? [],
                                         service: svc?.name, config: svc?.config))
        }
        return result.sorted { ($0.linkActive ? 0 : 1, $0.bsd) < ($1.linkActive ? 0 : 1, $1.bsd) }
    }

    /// Test: IMAC_RECEIVER_FAKE_NET="en5:USB LAN:up:10.77.0.2:Manual" (mehrere mit ;), "none" = keine
    private static func fakeInterfaces(_ s: String) -> [WiredInterface] {
        if s == "none" { return [] }
        return s.split(separator: ";").map { part in
            let f = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let ip = f.count > 3 ? f[3] : ""
            let method = f.count > 4 ? f[4] : "DHCP"
            return WiredInterface(bsd: f[0], name: f.count > 1 ? f[1] : f[0], linkActive: f.count > 2 && f[2] == "up",
                                  ipv4: ip.isEmpty ? [] : [ip], service: f.count > 1 ? f[1] : f[0],
                                  config: IPv4Config(method: method, addresses: method == "Manual" ? [ip] : [],
                                                     masks: method == "Manual" ? [Config.netmask] : []))
        }
    }

    private static func serviceInfo() -> [String: (name: String, config: IPv4Config?)] {
        guard let prefs = SCPreferencesCreate(nil, "iMacDisplayReceiver" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [:] }
        var res: [String: (name: String, config: IPv4Config?)] = [:]
        for s in services {
            guard let iface = SCNetworkServiceGetInterface(s), let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            let name = (SCNetworkServiceGetName(s) as String?) ?? bsd
            var cfg: IPv4Config?
            if let proto = SCNetworkServiceCopyProtocol(s, kSCNetworkProtocolTypeIPv4) {
                if let d = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] {
                    cfg = IPv4Config(method: (d[kSCPropNetIPv4ConfigMethod as String] as? String) ?? "?",
                                     addresses: (d[kSCPropNetIPv4Addresses as String] as? [String]) ?? [],
                                     masks: (d[kSCPropNetIPv4SubnetMasks as String] as? [String]) ?? [],
                                     router: d[kSCPropNetIPv4Router as String] as? String)
                } else {
                    cfg = IPv4Config(method: "Off")
                }
            }
            // mehrere Dienste auf einem Gerät: den aktivierten bevorzugen
            if res[bsd] == nil || SCNetworkServiceGetEnabled(s) { res[bsd] = (name, cfg) }
        }
        return res
    }

    static func ipv4Addresses() -> [String: [String]] {
        var res: [String: [String]] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return res }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            res[String(cString: ifa.ifa_name), default: []].append(String(cString: buf))
        }
        return res
    }
}

/// Vorherige Einstellung des Dienstes, gespeichert vor „Einrichten“, benutzt von „Zurücksetzen“.
struct NetworkBackup: Codable, Equatable {
    var service: String
    var previous: IPv4Config
    var savedAt: Date

    static func load() -> NetworkBackup? {
        guard let d = try? Data(contentsOf: Config.networkBackupFile) else { return nil }
        return try? PropertyListDecoder().decode(NetworkBackup.self, from: d)
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
        let enc = PropertyListEncoder(); enc.outputFormat = .xml
        try enc.encode(self).write(to: Config.networkBackupFile)
    }
    static func remove() { try? FileManager.default.removeItem(at: Config.networkBackupFile) }
}

enum NetworkChanger {
    static func setupCommand(service: String) -> String {
        "\(Config.networksetup) -setmanual \(shellQuote(service)) \(Config.myIP) \(Config.netmask)"
    }
    static func restoreCommand(service: String, previous: IPv4Config?) -> String {
        let s = shellQuote(service)
        guard let p = previous else { return "\(Config.networksetup) -setdhcp \(s)" }
        switch p.method {
        case "Manual" where !p.addresses.isEmpty && !p.isOurs:
            var c = "\(Config.networksetup) -setmanual \(s) \(p.addresses[0]) \(p.masks.first ?? "255.255.255.0")"
            if let r = p.router, !r.isEmpty { c += " \(r)" }
            return c
        case "INFORM" where !p.addresses.isEmpty:
            return "\(Config.networksetup) -setmanualwithdhcprouter \(s) \(p.addresses[0])"
        case "BOOTP": return "\(Config.networksetup) -setbootp \(s)"
        case "Off": return "\(Config.networksetup) -setv4off \(s)"
        default: return "\(Config.networksetup) -setdhcp \(s)"
        }
    }

    /// Ethernet-Dienst auf 10.77.0.2 stellen (vorher bisherige Einstellung sichern).
    static func setup(_ iface: WiredInterface) -> (ok: Bool, message: String) {
        guard let svc = iface.service else { return (false, "Kein Netzwerkdienst für \(iface.name) gefunden.") }
        var freshBackup = false
        if let cfg = iface.config, !cfg.isOurs, NetworkBackup.load()?.service != svc {
            do { try NetworkBackup(service: svc, previous: cfg, savedAt: Date()).save(); freshBackup = true }
            catch { return (false, "Bisherige Einstellung konnte nicht gesichert werden: \(error.localizedDescription)") }
            Log.write("Netzwerk: bisherige Einstellung von „\(svc)“ gesichert: \(cfg.summary)")
        }
        let r = Privileged.run(setupCommand(service: svc),
                               prompt: "„\(Config.appName)“ möchte die Adresse des Ethernet-Anschlusses „\(svc)“ auf \(Config.myIP) stellen. WLAN und Internet bleiben unverändert.")
        if !r.ok && freshBackup {
            NetworkBackup.remove()        // nichts geändert → keine Sicherung vortäuschen
            Log.write("Netzwerk: nicht geändert – Sicherung wieder verworfen")
        }
        return r
    }

    static func reset(service: String) -> (ok: Bool, message: String) {
        let backup = NetworkBackup.load()
        let prev = (backup?.service == service) ? backup?.previous : nil
        let r = Privileged.run(restoreCommand(service: service, previous: prev),
                               prompt: "„\(Config.appName)“ möchte die Einstellung des Ethernet-Anschlusses „\(service)“ zurücksetzen.")
        if r.ok { NetworkBackup.remove() }
        return r
    }
}

/// Befehle mit Administratorrechten über den normalen macOS-Passwortdialog.
enum Privileged {
    static func run(_ command: String, prompt: String) -> (ok: Bool, message: String) {
        if Config.dryRun {
            if Config.env["IMAC_RECEIVER_TEST_PRIV"] == "cancel" {
                Log.write("[Testmodus] Admin-Dialog abgebrochen (simuliert): \(command)")
                return (false, "Abgebrochen – nichts geändert.")
            }
            Log.write("[Testmodus] würde mit Admin-Rechten ausführen: \(command)")
            return (true, "Testmodus – nichts geändert:\n\(command)")
        }
        Log.write("Admin-Befehl: \(command)")
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let src = "do shell script \"\(esc(command))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { return (false, "Interner Fehler (AppleScript)") }
        _ = script.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            let msg = err[NSAppleScript.errorMessage] as? String ?? "unbekannter Fehler"
            Log.write("Admin-Befehl fehlgeschlagen (\(code)): \(msg)")
            return (false, code == -128 ? "Abgebrochen – nichts geändert." : "Fehler: \(msg)")
        }
        Log.write("Admin-Befehl erfolgreich.")
        return (true, "Erledigt.")
    }
}

// MARK: - MacBook erreichbar?

enum ReachState: Equatable { case unknown, ok(Int), fail(String) }

final class Reachability {
    private let session: URLSession
    private var inFlight = false
    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1
        c.timeoutIntervalForResource = 1.5
        c.connectionProxyDictionary = [:]
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }
    /// completion läuft auf dem Main-Thread
    func check(_ completion: @escaping (ReachState) -> Void) {
        if inFlight { return }
        inFlight = true
        var req = URLRequest(url: URL(string: "http://\(Config.host)/")!)
        req.timeoutInterval = 1
        session.dataTask(with: req) { [weak self] _, resp, err in
            let state: ReachState
            if let h = resp as? HTTPURLResponse { state = .ok(h.statusCode) }
            else { state = .fail((err as NSError?)?.localizedDescription ?? "keine Antwort") }
            DispatchQueue.main.async { self?.inFlight = false; completion(state) }
        }.resume()
    }
}

// MARK: - Autostart (LaunchAgent im Benutzerordner, kein Admin)

enum AutostartState: Equatable { case off, on, stale(String) }

enum Autostart {
    static func state() -> AutostartState {
        guard let d = NSDictionary(contentsOf: Config.agentPlist) as? [String: Any] else { return .off }
        let args = d["ProgramArguments"] as? [String] ?? []
        guard let exe = args.first, FileManager.default.isExecutableFile(atPath: exe) else { return .stale(args.first ?? "?") }
        if URL(fileURLWithPath: exe).standardizedFileURL.path != URL(fileURLWithPath: Config.executablePath).standardizedFileURL.path {
            return .stale(exe)
        }
        return .on
    }

    /// App läuft von einem Ort, an dem Autostart nicht dauerhaft funktioniert (DMG, App Translocation)
    static var badLocationReason: String? {
        let p = Config.executablePath
        if p.contains("/AppTranslocation/") { return "Die App läuft aus einem temporären Ort (macOS-Schutz). Bitte in den Ordner „Programme“ ziehen und von dort öffnen." }
        if p.hasPrefix("/Volumes/") { return "Die App läuft direkt aus dem Disk-Image. Bitte in den Ordner „Programme“ ziehen und von dort öffnen." }
        return nil
    }

    static func enable() throws {
        let plist: [String: Any] = [
            "Label": Config.agentLabel,
            "ProgramArguments": [Config.executablePath, "--monitor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],          // nach Absturz neu, nach Beenden nicht
            "ThrottleInterval": 10,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: Config.agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Config.agentPlist, options: .atomic)
        Log.write("Autostart eingeschaltet: \(Config.agentPlist.path)")
        // Bewusst KEIN 'launchctl bootstrap': RunAtLoad würde sofort eine zweite Kopie der App starten.
        // launchd lädt die Datei bei der nächsten Anmeldung von selbst.
    }

    // Alte Skript-Installation (install.command, LaunchAgent „de.local.imac-display“) – startet bei der Anmeldung
    // zusätzlich Chrome im Vollbild, das dann vor bzw. neben dem Monitor-Modus dieser App liegt.
    static let legacyLabel = "de.local.imac-display"
    static var legacyPlist: URL { Config.home.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist") }
    static var legacyFiles: [URL] {
        ["launcher.sh", "player.html", "setup-network.sh", "uninstall.command", "start.command", "start-display.command",
         "chrome-profile.launcher.pid"].map { Config.supportDir.appendingPathComponent($0) }
        + [Config.profileDir]          // Chrome-Profil (alte Skripte und frühere Versionen dieser App)
        + [Config.home.appendingPathComponent("Library/Logs/iMacDisplay.log")]
    }
    static var legacyInstalled: Bool { FileManager.default.fileExists(atPath: legacyPlist.path) }

    /// Entfernt die alte Skript-Installation (nur auf Klick) samt ihrem Chrome-Profil. Netzwerk bleibt.
    static func removeLegacy() -> String {
        let target = "gui/\(getuid())/\(legacyLabel)"
        if runTool(Config.launchctl, ["print", target]).status == 0 {
            let r = runTool(Config.launchctl, ["bootout", target])
            Log.write("launchctl bootout \(target) → \(r.status)")
        }
        killChromeUsingOldProfile()
        let fm = FileManager.default
        var removed: [String] = []
        for u in [legacyPlist] + legacyFiles where fm.fileExists(atPath: u.path) {
            if (try? fm.removeItem(at: u)) != nil { removed.append(u.lastPathComponent) }
        }
        Log.write("Alte Skript-Installation entfernt: \(removed.joined(separator: ", "))")
        return removed.isEmpty ? "Nichts zu entfernen." : "Entfernt: \(removed.joined(separator: ", "))"
    }

    /// Ein noch laufendes Kiosk-Chrome mit dem alten Profil beenden (bevor dessen Ordner gelöscht wird).
    static func killChromeUsingOldProfile() {
        let pattern = "--user-data-dir=\(Config.profileDir.path)"
        let pids = runTool("/usr/bin/pgrep", ["-f", "--", pattern]).output
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != getpid() }
        guard !pids.isEmpty else { return }
        Log.write("Altes Kiosk-Chrome mit dem alten Profil läuft noch (\(pids)) – wird beendet")
        pids.forEach { kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && pids.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        pids.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
    }

    static func disable() {
        let target = "gui/\(getuid())/\(Config.agentLabel)"
        let loaded = runTool(Config.launchctl, ["print", target]).status == 0
        // Wurde diese App selbst vom Agent gestartet, würde 'bootout' sie beenden → nur Datei entfernen.
        let startedByAgent = Config.env["XPC_SERVICE_NAME"] == Config.agentLabel || Config.env["IMAC_RECEIVER_TEST_STARTED_BY_AGENT"] == "1"
        if loaded && !startedByAgent {
            let r = runTool(Config.launchctl, ["bootout", target])
            Log.write("launchctl bootout \(target) → \(r.status)")
        }
        try? FileManager.default.removeItem(at: Config.agentPlist)
        Log.write("Autostart ausgeschaltet (Datei entfernt).")
    }
}

// MARK: - Bildschirm wach halten

/// Energie-Zusicherungen (IOKit-Assertions) – keine Systemeinstellung wird geändert.
/// Alle Assertions gehören diesem Prozess und verschwinden spätestens mit ihm.
///   • Monitor-Modus an:                    Rechner schläft nicht automatisch ein (Bildschirm darf aus),
///                                          damit der iMac das MacBook überhaupt bemerken kann.
///   • Monitor-Modus an + MacBook erreichbar: Bildschirm bleibt an; beim Übergang „nicht erreichbar → erreichbar“
///                                          wird der Bildschirm einmal aufgeweckt (wie `caffeinate -u`).
///   • MacBook weg / Monitor-Modus aus:     alles wieder freigegeben → normaler Ruhezustand.
final class PowerController {
    private var displayID: IOPMAssertionID = 0      // PreventUserIdleDisplaySleep
    private var systemID: IOPMAssertionID = 0       // PreventUserIdleSystemSleep
    private var activityID: IOPMAssertionID = 0     // DeclareUserActivity (eine ID, wird wiederverwendet)
    private var wanted = false

    var displayHeld: Bool { displayID != 0 }
    var systemHeld: Bool { systemID != 0 }
    var activityHeld: Bool { activityID != 0 }
    /// Für Tests/Protokoll: Anzahl gehaltener Assertions
    var heldCount: Int { [displayID, systemID, activityID].filter { $0 != 0 }.count }

    func update(reachable: Bool, active: Bool) {
        // 1. Rechner wach, solange der Monitor-Modus läuft
        if active && systemID == 0 {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "iMac Display: wartet auf das MacBook" as CFString, &systemID)
            if r != kIOReturnSuccess { systemID = 0 }
            Log.write("Ruhezustand des Rechners aufgeschoben (Monitor-Modus) – \(r == kIOReturnSuccess ? "ok" : "Fehler \(r)")")
        } else if !active && systemID != 0 {
            IOPMAssertionRelease(systemID); systemID = 0
            Log.write("Rechner darf wieder normal in den Ruhezustand")
        }

        // 2. Bildschirm
        let want = reachable && active
        if want && !wanted {
            // Übergang → Bildschirm aufwecken. Dieselbe ID wird wiederverwendet (kein Leck).
            let r = IOPMAssertionDeclareUserActivity("iMac Display: MacBook verbunden" as CFString, kIOPMUserActiveLocal, &activityID)
            if r != kIOReturnSuccess { activityID = 0 }
            Log.write("MacBook erreichbar – Bildschirm aufwecken (\(r == kIOReturnSuccess ? "ok" : "Fehler \(r)"))")
        }
        if want && displayID == 0 {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "iMac Display: Bild vom MacBook" as CFString, &displayID)
            if r != kIOReturnSuccess { displayID = 0 }
            Log.write("Bildschirm bleibt wach (Assertion \(r == kIOReturnSuccess ? "aktiv" : "Fehler \(r)"))")
        }
        if !want {
            if activityID != 0 { IOPMAssertionRelease(activityID); activityID = 0 }
            if displayID != 0 {
                IOPMAssertionRelease(displayID); displayID = 0
                Log.write("Bildschirm darf wieder schlafen")
            }
        }
        wanted = want
    }

    func releaseAll() { update(reachable: false, active: false) }
    deinit { releaseAll() }
}
