import Foundation

/// Feste Werte und Umgebungs-Overrides (die IMAC_RECEIVER_*-Variablen sind nur zum Testen gedacht).
enum Config {
    static let env = ProcessInfo.processInfo.environment

    static let bundleID = "de.local.imac-display-receiver"
    static let agentLabel = "de.local.imac-display-receiver"
    static let appName = "iMac Display Empfänger"
    /// App-Version (build-dmg.sh liest sie von hier für CFBundleShortVersionString)
    static let version = "1.3"
    /// Link für QR-Code und Ruhebild
    static let projectURL = "https://github.com/JonasHallenbarter/iMac-Display"

    /// Ziel (MacBook-Server). Zum Testen: --host 127.0.0.1:18095 oder IMAC_RECEIVER_HOST
    static let host: String = {
        var h = env["IMAC_RECEIVER_HOST"] ?? "10.77.0.1:8080"
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--host"), i + 1 < a.count { h = a[i + 1] }
        for p in ["ws://", "wss://", "http://", "https://"] where h.lowercased().hasPrefix(p) { h = String(h.dropFirst(p.count)) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if !h.contains(":") { h += ":8080" }
        return h
    }()
    static var hostIP: String { String(host.split(separator: ":").first ?? "10.77.0.1") }
    static let myIP = "10.77.0.2"
    static let netmask = "255.255.255.0"

    /// Testmodus: Netzwerk-Änderungen und „App in den Papierkorb“ werden nur protokolliert.
    static let dryRun = env["IMAC_RECEIVER_DRY_RUN"] == "1"

    /// Automatisch ausschalten: so lange ohne Bild und ohne Eingabe (Sekunden), dann so lange Countdown.
    /// Nur zum Testen verkürzbar: IMAC_RECEIVER_SHUTDOWN_IDLE=20, IMAC_RECEIVER_SHUTDOWN_COUNTDOWN=5
    static let shutdownIdle: Double = max(5, Double(env["IMAC_RECEIVER_SHUTDOWN_IDLE"] ?? "") ?? 600)
    static let shutdownCountdown: Double = max(3, Double(env["IMAC_RECEIVER_SHUTDOWN_COUNTDOWN"] ?? "") ?? 60)

    static let home: URL = URL(fileURLWithPath: env["IMAC_RECEIVER_HOME"] ?? NSHomeDirectory(), isDirectory: true)
    static var supportDir: URL { home.appendingPathComponent("Library/Application Support/iMacDisplay", isDirectory: true) }
    /// Chrome-Profil früherer Versionen (Chrome-Kiosk) – wird nur noch beim Aufräumen/Deinstallieren gelöscht
    static var profileDir: URL { supportDir.appendingPathComponent("chrome-profile", isDirectory: true) }
    static var networkBackupFile: URL { supportDir.appendingPathComponent("network-backup.plist") }
    static var logFile: URL { home.appendingPathComponent("Library/Logs/iMacDisplayReceiver.log") }
    static var agentPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist") }
    static var savedState: URL { home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState") }

    static let launchctl = env["IMAC_RECEIVER_LAUNCHCTL"] ?? "/bin/launchctl"
    static let networksetup = "/usr/sbin/networksetup"
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}

/// Protokoll nach ~/Library/Logs/iMacDisplayReceiver.log (+ stderr).
enum Log {
    static var enabled = true
    private static let queue = DispatchQueue(label: "log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) [\(getpid())] \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        guard enabled else { return }
        queue.async {
            let url = Config.logFile
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int, size > 2_000_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(200_000).write(to: url)          // klein halten
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
    static func flush() { queue.sync {} }
}

/// Startet ein Hilfsprogramm und liefert Status + Ausgabe.
@discardableResult
func runTool(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
