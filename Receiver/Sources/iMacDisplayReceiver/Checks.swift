import Foundation

enum CheckStatus { case ok, warn, error, neutral }

enum CheckAction: String, Hashable, CaseIterable {
    case openNetworkPrefs, setupNetwork, resetNetwork
    case startMonitor, stopMonitor, enableAutostart, disableAutostart, repairAutostart, showLog, revealApplications
    case removeLegacyAutostart
}

struct ActionButton: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var action: CheckAction
    var prominent = false
    var enabled = true
}

struct CheckItem: Identifiable {
    var id: String
    var status: CheckStatus
    var title: String
    var detail: String
    var hint: String? = nil                 // „Was tun?“
    var actions: [ActionButton] = []
    var disclosureTitle: String? = nil      // z. B. „Was wird geändert?“
    var disclosureText: String? = nil
}

/// Alles, was die Checkliste anzeigt (wird alle 2 s neu ermittelt; für Vorschaubilder frei setzbar).
struct Facts {
    var decoder: DecodeProbeResult = .pending
    var picture: PictureInfo = .off
    var wired: [WiredInterface] = []
    var reach: ReachState = .unknown
    var monitor: MonitorState = .off
    var autostart: AutostartState = .off
    var backup: NetworkBackup?
    var badLocation: String?
    var autoLogin: String?
    var legacyAgent = false

    var primary: WiredInterface? { wired.first(where: { $0.linkActive }) ?? wired.first }

    static func current(monitor: MonitorState, reach: ReachState, picture: PictureInfo = .off) -> Facts {
        var f = Facts()
        f.decoder = DecoderProbe.result
        f.picture = picture
        f.wired = Network.wiredInterfaces()
        f.reach = reach
        f.monitor = monitor
        f.autostart = Autostart.state()
        f.backup = NetworkBackup.load()
        f.badLocation = Autostart.badLocationReason
        f.legacyAgent = Autostart.legacyInstalled
        f.autoLogin = (NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.loginwindow.plist")?["autoLoginUser"] as? String)
        return f
    }
}

enum Checks {
    static func build(_ f: Facts) -> [CheckItem] {
        [decoder(f), cable(f), address(f), macbook(f), monitor(f), picture(f), autostart(f)]
    }

    static func decoder(_ f: Facts) -> CheckItem {
        let title = "Video-Dekodierung (H.264, \(DecoderProbe.width)×\(DecoderProbe.height))"
        switch f.decoder {
        case .pending:
            return CheckItem(id: "decoder", status: .neutral, title: title, detail: "Wird geprüft …")
        case .hardware(let ms):
            return CheckItem(id: "decoder", status: .ok, title: title,
                             detail: "Probebild in der Grafik-Hardware dekodiert (\(ms) ms). Kein Browser nötig.")
        case .software(let ms):
            return CheckItem(id: "decoder", status: .warn, title: title,
                             detail: "Kein Hardware-Decoder für diese Größe – dekodiert per Software (Probebild \(ms) ms).",
                             hint: "Funktioniert meist trotzdem, braucht aber mehr Rechenleistung und kann ruckeln. "
                                + "Die Zeile „Bild vom MacBook“ zeigt im Monitor-Modus die tatsächliche Bildrate.")
        case .failed(let why):
            return CheckItem(id: "decoder", status: .error, title: title,
                             detail: "Dieser Mac kann das Videoformat nicht dekodieren (\(why)).",
                             hint: "Der Grafikchip dieses Macs schafft das 4K-Format offenbar nicht. Details stehen im Protokoll – bitte mitschicken.",
                             actions: [ActionButton(title: "Protokoll anzeigen", action: .showLog)])
        }
    }

    /// „USB LAN (en5)“ – ohne doppeltes „(en4) (en4)“, wenn der Name das Gerät schon enthält
    static func label(_ p: WiredInterface) -> String { p.name.contains("(\(p.bsd))") ? p.name : "\(p.name) (\(p.bsd))" }

    static func cable(_ f: Facts) -> CheckItem {
        let title = "Ethernet-Kabel"
        guard let p = f.primary else {
            return CheckItem(id: "cable", status: .error, title: title, detail: "Kein Ethernet-Anschluss gefunden.",
                             hint: "Ethernet-Adapter (falls nötig) anstecken und das Kabel direkt mit dem MacBook verbinden.",
                             actions: [ActionButton(title: "Netzwerk-Einstellungen", action: .openNetworkPrefs)])
        }
        if !p.linkActive {
            return CheckItem(id: "cable", status: .warn, title: title, detail: "\(label(p)): kein Kabel / keine Verbindung.",
                             hint: "Kabel an beiden Enden fest einstecken. Das MacBook muss eingeschaltet und sein Adapter angesteckt sein.")
        }
        return CheckItem(id: "cable", status: .ok, title: title, detail: "Verbunden: \(label(p))")
    }

    static func address(_ f: Facts) -> CheckItem {
        let title = "Netzwerkadresse \(Config.myIP)"
        guard let p = f.primary, let svc = p.service else {
            return CheckItem(id: "address", status: .neutral, title: title, detail: "Wartet auf einen Ethernet-Anschluss.")
        }
        let configured = p.config?.isOurs == true
        let ours = f.backup?.service == svc
        let prev = ours ? (f.backup?.previous.summary ?? "automatisch (DHCP)") : "automatisch (DHCP)"
        let explain = "Befehl (mit Admin-Passwort):\n  sudo \(NetworkChanger.setupCommand(service: svc))\n\n"
            + "Geändert wird nur der Dienst „\(svc)“: Adresse \(Config.myIP), Maske \(Config.netmask), kein Router.\n"
            + "WLAN und Internet bleiben unverändert. Die bisherige Einstellung (\(p.config?.isOurs == true ? prev : (p.config?.summary ?? "?"))) "
            + "wird vorher gespeichert; „Zurücksetzen“ stellt sie wieder her."
        let reset = ActionButton(title: "Zurücksetzen", action: .resetNetwork)
        if p.hasOurIP {
            return CheckItem(id: "address", status: .ok, title: title, detail: "Aktiv auf \(p.name) (Dienst „\(svc)“).",
                             actions: [reset], disclosureTitle: "Was wurde geändert?", disclosureText: explain)
        }
        if configured {
            return CheckItem(id: "address", status: p.linkActive ? .warn : .neutral, title: title,
                             detail: p.linkActive ? "Eingerichtet, aber noch nicht aktiv." : "Eingerichtet – aktiv, sobald das Kabel verbunden ist.",
                             hint: p.linkActive ? "Ein paar Sekunden warten. Hilft das nicht: Kabel einmal aus- und einstecken." : nil,
                             actions: [reset], disclosureTitle: "Was wurde geändert?", disclosureText: explain)
        }
        let now = p.ipv4.first.map { "aktuell \($0)" } ?? (p.config.map { "aktuell \($0.summary)" } ?? "kein Dienst")
        return CheckItem(id: "address", status: .warn, title: title, detail: "Noch nicht eingerichtet – \(now).",
                         hint: "Einmal „Einrichten“ klicken und das Admin-Passwort eingeben. Ändert nur den Ethernet-Dienst „\(svc)“.",
                         actions: [ActionButton(title: "Einrichten …", action: .setupNetwork, prominent: true)],
                         disclosureTitle: "Was wird geändert?", disclosureText: explain)
    }

    static func macbook(_ f: Facts) -> CheckItem {
        let title = "MacBook erreichbar"
        switch f.reach {
        case .unknown:
            return CheckItem(id: "macbook", status: .neutral, title: title, detail: "Wird geprüft …")
        case .ok(let code):
            return CheckItem(id: "macbook", status: .ok, title: title, detail: "Antwortet (http://\(Config.host)/, HTTP \(code)).")
        case .fail:
            var hint: String
            if f.primary == nil || f.primary?.linkActive == false {
                hint = "Zuerst das Ethernet-Kabel verbinden (siehe oben)."
            } else if f.primary?.hasOurIP == false {
                hint = "Zuerst die Netzwerkadresse \(Config.myIP) einrichten (siehe oben)."
            } else {
                hint = "Läuft die iMac-Display-App auf dem MacBook und ist „Übertragung aktiv“ eingeschaltet? "
                    + "MacBook-Adresse muss \(Config.hostIP) sein (dort ebenfalls ohne Router)."
            }
            return CheckItem(id: "macbook", status: .warn, title: title, detail: "Keine Antwort von \(Config.host).", hint: hint)
        }
    }

    static func monitor(_ f: Facts) -> CheckItem {
        let title = "Monitor-Modus"
        switch f.monitor {
        case .running:
            return CheckItem(id: "monitor", status: .ok, title: title, detail: "Läuft – das Bild wird im Vollbild auf diesem Bildschirm gezeigt.",
                             hint: "Beenden: Cmd+Q (dann erscheint dieses Fenster wieder). Taste „s“ blendet Messwerte ein/aus.",
                             actions: [ActionButton(title: "Monitor-Modus beenden", action: .stopMonitor)])
        case .failed(let why):
            return CheckItem(id: "monitor", status: .error, title: title, detail: why,
                             hint: "Ursache siehe Zeilen oben bzw. im Protokoll. Danach erneut starten.",
                             actions: [ActionButton(title: "Erneut starten", action: .startMonitor, prominent: true),
                                       ActionButton(title: "Protokoll anzeigen", action: .showLog)])
        case .off:
            return CheckItem(id: "monitor", status: .neutral, title: title, detail: "Aus.",
                             hint: "Zeigt das Bild des MacBooks im Vollbild. Ohne Übertragung steht dort „Aktuell kein aktiver Monitor“; "
                                + "das Bild erscheint von selbst. Beenden mit Cmd+Q – dann erscheint dieses Fenster wieder.",
                             actions: [ActionButton(title: "Monitor-Modus starten", action: .startMonitor, prominent: true)])
        }
    }

    static func picture(_ f: Facts) -> CheckItem {
        let title = "Bild vom MacBook"
        switch f.picture {
        case .off:
            return CheckItem(id: "picture", status: .neutral, title: title, detail: "Erscheint, sobald der Monitor-Modus läuft.")
        case .waiting(let connected):
            if connected {
                return CheckItem(id: "picture", status: .neutral, title: title, detail: "Verbunden – warte auf Bild …",
                                 hint: "Das MacBook sendet gerade kein Bild. Dort im Menü „Übertragung aktiv“ prüfen.")
            }
            return CheckItem(id: "picture", status: .neutral, title: title,
                             detail: "Kein Signal – der Bildschirm zeigt „Aktuell kein aktiver Monitor“.",
                             hint: "Das Bild erscheint von selbst, sobald das MacBook überträgt (siehe „MacBook erreichbar“).")
        case .playing(let fps, let w, let h, let hw):
            let dec = hw == false ? " · Software-Dekodierung" : ""
            return CheckItem(id: "picture", status: .ok, title: title,
                             detail: "Läuft · \(Int(fps.rounded())) fps · \(w)×\(h)\(dec)")
        case .failing(let why):
            return CheckItem(id: "picture", status: .error, title: title, detail: "Bild kann nicht angezeigt werden: \(why)",
                             hint: "Die App fordert automatisch neue Bilder an. Bleibt es dabei: Zeile „Video-Dekodierung“ oben prüfen "
                                + "und das Protokoll ansehen.",
                             actions: [ActionButton(title: "Protokoll anzeigen", action: .showLog)])
        }
    }

    static func autostart(_ f: Facts) -> CheckItem {
        let title = "Autostart bei der Anmeldung"
        let what = "Legt nur die Datei ~/Library/LaunchAgents/\(Config.agentLabel).plist an (kein Admin-Passwort). "
            + "Sie startet diese App bei der Anmeldung im Monitor-Modus. „Ausschalten“ löscht die Datei wieder."
        let loginTip = f.autoLogin == nil
            ? "\n\nTipp: Damit der iMac nach dem Einschalten ohne Anmeldung startet: Systemeinstellungen → Benutzer & Gruppen → Anmeldeoptionen → Automatische Anmeldung."
            : ""
        if f.legacyAgent {
            return CheckItem(id: "autostart", status: .error, title: title,
                             detail: "Eine ältere Skript-Installation (install.command) ist noch eingerichtet.",
                             hint: "Sie startet bei der Anmeldung zusätzlich Chrome im Vollbild – das verdeckt bzw. stört den Monitor-Modus. "
                                + "„Alte Installation entfernen“ löscht nur deren Autostart, Dateien und Chrome-Profil; das Netzwerk bleibt.",
                             actions: [ActionButton(title: "Alte Installation entfernen", action: .removeLegacyAutostart, prominent: true)],
                             disclosureTitle: "Was wird entfernt?",
                             disclosureText: "launchctl bootout gui/<uid>/\(Autostart.legacyLabel)\n"
                                + ([Autostart.legacyPlist] + Autostart.legacyFiles).map { "  " + $0.path.replacingOccurrences(of: Config.home.path, with: "~") }.joined(separator: "\n"))
        }
        switch f.autostart {
        case .on:
            return CheckItem(id: "autostart", status: .ok, title: title,
                             detail: "An – startet bei der Anmeldung im Monitor-Modus." + (f.autoLogin.map { " (Automatische Anmeldung: \($0))" } ?? ""),
                             hint: f.autoLogin == nil ? "Optional: Automatische Anmeldung einschalten (Systemeinstellungen → Benutzer & Gruppen → Anmeldeoptionen)." : nil,
                             actions: [ActionButton(title: "Autostart ausschalten", action: .disableAutostart)],
                             disclosureTitle: "Was wurde geändert?", disclosureText: what)
        case .stale(let exe):
            return CheckItem(id: "autostart", status: .warn, title: title, detail: "Eingeschaltet, zeigt aber auf einen alten Ort der App.",
                             hint: "Die App wurde verschoben (\(exe)). „Reparieren“ trägt den aktuellen Ort ein.",
                             actions: [ActionButton(title: "Reparieren", action: .repairAutostart, prominent: true, enabled: f.badLocation == nil),
                                       ActionButton(title: "Autostart ausschalten", action: .disableAutostart)],
                             disclosureTitle: "Was wird geändert?", disclosureText: what)
        case .off:
            if let bad = f.badLocation {
                return CheckItem(id: "autostart", status: .warn, title: title, detail: "Aus.", hint: bad,
                                 actions: [ActionButton(title: "Ordner „Programme“ öffnen", action: .revealApplications)])
            }
            return CheckItem(id: "autostart", status: .neutral, title: title, detail: "Aus.",
                             hint: "Einschalten, damit der iMac nach dem Anmelden von selbst als Monitor bereitsteht." + loginTip,
                             actions: [ActionButton(title: "Autostart einschalten", action: .enableAutostart, prominent: true)],
                             disclosureTitle: "Was wird geändert?", disclosureText: what)
        }
    }

    /// Textform (für --print-status und Tests)
    static func text(_ items: [CheckItem]) -> String {
        items.map { i in
            let s: String
            switch i.status { case .ok: s = "[OK]  "; case .warn: s = "[WARN]"; case .error: s = "[ERR] "; case .neutral: s = "[--]  " }
            var line = "\(s) \(i.title): \(i.detail)"
            if let h = i.hint { line += "\n        Was tun? \(h)" }
            if !i.actions.isEmpty { line += "\n        Buttons: " + i.actions.map { $0.title + ($0.enabled ? "" : " (inaktiv)") }.joined(separator: " | ") }
            return line
        }.joined(separator: "\n")
    }
}
