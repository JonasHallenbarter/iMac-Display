import AppKit

/// Global dry-run switch for everything that changes the system (network, TCC, login item, uninstall,
/// moving the app). Enable with `IMAC_DISPLAY_DRY_RUN=1` (e.g. `open --env IMAC_DISPLAY_DRY_RUN=1 "iMac Display.app"`)
/// or the `--dry-run` flag. Changes are then only logged.
enum DryRun {
    static var forced = false
    static var isOn: Bool {
        if forced { return true }
        let v = ProcessInfo.processInfo.environment["IMAC_DISPLAY_DRY_RUN"] ?? ""
        return !v.isEmpty && v != "0"
    }
}

/// Changes the IPv4 setting of exactly ONE network service (the cable adapter) to 10.77.0.1/24 without
/// router, via the standard macOS administrator dialog. The previous setting is saved and can be restored.
enum NetworkSetup {
    static let macIP = "10.77.0.1"
    static let iMacIP = "10.77.0.2"
    static let netmask = "255.255.255.0"
    static let networksetup = "/usr/sbin/networksetup"
    /// Dry-run uses its own key so tests never leave a "real" backup behind.
    private static var backupKey: String { DryRun.isOn ? "networkBackupsDryRun" : "networkBackups" }
    /// Single-service backup of earlier development builds (migrated on read).
    private static var legacyBackupKey: String { DryRun.isOn ? "networkBackupDryRun" : "networkBackup" }

    // MARK: backup (one entry per network service that the app changed)

    /// Previous IPv4 settings, keyed by network service name. An entry exists only for services the app
    /// changed itself; it is written BEFORE the change and removed after a successful reset.
    static var backups: [String: ServiceIPv4Config] {
        var all: [String: ServiceIPv4Config] = [:]
        if let d = UserDefaults.standard.data(forKey: backupKey),
           let m = try? JSONDecoder().decode([String: ServiceIPv4Config].self, from: d) { all = m }
        if let d = UserDefaults.standard.data(forKey: legacyBackupKey),
           let c = try? JSONDecoder().decode(ServiceIPv4Config.self, from: d), all[c.service] == nil {
            all[c.service] = c
        }
        return all
    }

    static func backup(for service: String) -> ServiceIPv4Config? { backups[service] }

    private static func storeBackups(_ m: [String: ServiceIPv4Config]) {
        UserDefaults.standard.removeObject(forKey: legacyBackupKey)
        if m.isEmpty { UserDefaults.standard.removeObject(forKey: backupKey); return }
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: backupKey) }
    }

    private static func saveBackup(_ c: ServiceIPv4Config) {
        var m = backups
        m[c.service] = c
        storeBackups(m)
    }

    static func clearBackup(service: String) {
        var m = backups
        m[service] = nil
        storeBackups(m)
    }

    // MARK: commands (shown 1:1 in the UI)

    /// No router argument → no gateway, no default route over the cable; Wi-Fi stays the default route.
    static func setupCommand(service: String) -> String {
        "\(networksetup) -setmanual \(Shell.quote(service)) \(macIP) \(netmask)"
    }

    /// Restores the saved previous setting of `service` exactly (or DHCP if nothing was saved, i.e. the
    /// app did not change this service, or the saved setting already was 10.77.0.1).
    static func restoreCommand(service: String) -> String {
        restoreCommand(service: service, backup: backup(for: service))
    }

    static func restoreCommand(service: String, backup: ServiceIPv4Config?) -> String {
        let q = Shell.quote(service)
        let dhcp = "\(networksetup) -setdhcp \(q)"
        guard let b = backup, !b.isCableConfig else { return dhcp }
        switch b.mode {
        case .manual:
            guard let ip = b.ip, let mask = b.subnet else { return dhcp }
            return "\(networksetup) -setmanual \(q) \(ip) \(mask)" + (b.router.map { " \($0)" } ?? "")
        case .manualWithDHCPRouter:
            guard let ip = b.ip else { return dhcp }
            return "\(networksetup) -setmanualwithdhcprouter \(q) \(ip)"
        case .bootp: return "\(networksetup) -setbootp \(q)"
        case .off: return "\(networksetup) -setv4off \(q)"
        case .dhcp: return dhcp + (b.clientID.map { " \(Shell.quote($0))" } ?? "")
        case .unknown: return dhcp
        }
    }

    static func restoreDescription(service: String) -> String {
        guard let b = backup(for: service), !b.isCableConfig else { return "automatisch (DHCP)" }
        switch b.mode {
        case .manual: return "manuell \(b.ip ?? "?")" + (b.router.map { ", Router \($0)" } ?? ", ohne Router")
        case .manualWithDHCPRouter: return "manuell \(b.ip ?? "?") mit DHCP-Router"
        case .bootp: return "BOOTP"
        case .off: return "IPv4 aus"
        case .dhcp: return "automatisch (DHCP)" + (b.clientID.map { ", Client-ID \($0)" } ?? "")
        case .unknown: return "automatisch (DHCP)"
        }
    }

    // MARK: actions

    enum Outcome { case done(String), cancelled, failed(String) }

    /// Sets 10.77.0.1 on `service`. Reads and saves the current setting first; if it cannot be read,
    /// nothing is changed (so "Zurücksetzen" can always restore exactly what was there before).
    /// An existing backup is never overwritten (pressing it twice keeps the real original).
    @MainActor
    static func configure(service: String) -> Outcome {
        guard let cur = SystemProbe.serviceConfig(service) else {
            logLine("Netzwerk: Einstellung von \"\(service)\" nicht lesbar – nichts geändert")
            return .failed("Die bisherige Einstellung von „\(service)“ ließ sich nicht lesen – es wurde nichts geändert.")
        }
        if cur.isCableConfig && cur.router == nil {
            return .done("„\(service)“ hat die Adresse \(macIP) bereits.")
        }
        if backup(for: service) == nil {
            saveBackup(cur)
            logLine("Netzwerk: bisherige Einstellung von \"\(service)\" gesichert: \(restoreDescription(service: service))")
        }
        let r = runAdmin(setupCommand(service: service),
                         prompt: "iMac Display möchte dem Netzwerkdienst „\(service)“ die Adresse \(macIP) geben. WLAN und Internet bleiben unverändert.")
        switch r {
        case .done: verifyAfterSetup(service: service)
        case .cancelled, .failed:
            // Nothing was changed: drop a backup that was only just written for this attempt.
            if backup(for: service) == cur, SystemProbe.serviceConfig(service) == cur { clearBackup(service: service) }
        }
        return r
    }

    @MainActor
    static func restore(service: String) -> Outcome {
        let r = runAdmin(restoreCommand(service: service),
                         prompt: "iMac Display möchte den Netzwerkdienst „\(service)“ auf die vorherige Einstellung zurücksetzen.")
        if case .done = r { clearBackup(service: service) }
        return r
    }

    /// Post-check: router must be empty and the default route must not go over the cable.
    private static func verifyAfterSetup(service: String) {
        guard !DryRun.isOn else { return }
        DispatchQueue.global().async {
            let cfg = SystemProbe.serviceConfig(service)
            let def = SystemProbe.defaultRouteInterface() ?? "?"
            let dev = SystemProbe.wiredInterfaces().first(where: { $0.serviceName == service })?.device
            logLine("Netzwerk: \"\(service)\" jetzt \(cfg?.mode.rawValue ?? "?") \(cfg?.ip ?? "-"), Router \(cfg?.router ?? "keiner"), "
                    + "Standardroute über \(def)" + (dev != nil && dev == def ? " – WARNUNG: über das Kabel!" : ""))
        }
    }

    /// Runs a shell command as root via the standard admin password dialog (NSAppleScript).
    @MainActor
    static func runAdmin(_ command: String, prompt: String) -> Outcome {
        if DryRun.isOn {
            logLine("[Dry-Run] würde mit Administratorrechten ausführen: \(command)")
            return .done("Dry-Run: \(command)")
        }
        logLine("Führe mit Administratorrechten aus: \(command)")
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let src = "do shell script \"\(esc(command))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { logLine("Abgebrochen (Administrator-Dialog)"); return .cancelled }
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)"
            logLine("Fehlgeschlagen: \(msg)")
            return .failed(msg)
        }
        return .done(out?.stringValue ?? "")
    }
}

/// Application firewall: the app never adds entries itself (macOS asks the user on the first incoming
/// connection). Uninstall can remove the entry that answer created.
enum Firewall {
    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    static func removeCommand(appPath: String) -> String { "\(tool) --remove \(Shell.quote(appPath))" }

    @MainActor
    static func removeApp(_ appPath: String) -> NetworkSetup.Outcome {
        NetworkSetup.runAdmin(removeCommand(appPath: appPath),
                              prompt: "iMac Display möchte seinen Eintrag aus der Firewall-Liste entfernen.")
    }
}
