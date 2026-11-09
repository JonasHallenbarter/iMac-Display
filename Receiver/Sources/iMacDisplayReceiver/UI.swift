import AppKit
import SwiftUI

struct UninstallOptions {
    var autostart = true
    var network = true
    var data = true
    var trashApp = true
}

final class AppModel: ObservableObject {
    @Published var checks: [CheckItem] = []
    @Published var showUninstall = false
    @Published var notice: String?          // kurze Rückmeldung unter der Kopfzeile
    @Published var busy = false
    @Published var uninstall = UninstallOptions()

    private(set) var facts = Facts()
    let monitor = MonitorController()
    let power = PowerController()
    private let reach = Reachability()
    private var reachState: ReachState = .unknown
    private var timer: Timer?
    let preview: Bool

    var onShowWindow: (() -> Void)?
    var onHideWindow: (() -> Void)?
    var windowVisible: () -> Bool = { false }
    private var testTimer: Timer?

    init(preview: Facts? = nil) {
        self.preview = preview != nil
        if let preview { facts = preview; checks = Checks.build(preview); return }
        monitor.onChange = { [weak self] in self?.refresh(quick: true) }
        monitor.onStarted = { [weak self] in self?.onHideWindow?() }
        monitor.onUserExit = { [weak self] in self?.refresh(quick: true); self?.onShowWindow?() }
    }

    var networkChangedByUs: Bool { facts.backup != nil || facts.primary?.config?.isOurs == true }

    func start() {
        DecoderProbe.start { [weak self] in self?.refresh(quick: true) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        if Config.dryRun, let dir = Config.env["IMAC_RECEIVER_TEST_DIR"] {
            testTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.pollTestCommands(dir) }
        }
    }

    /// Beim Beenden: Player schließen, alle Energie-Assertions freigeben.
    func shutdown() {
        timer?.invalidate(); testTimer?.invalidate()
        monitor.stopAndWait()
        power.releaseAll()
    }

    private var monitorActive: Bool { monitor.state == .running }

    private func updatePower() {
        var ok = false
        if case .ok = reachState { ok = true }
        let before = power.heldCount
        power.update(reachable: ok, active: monitorActive)
        if power.heldCount != before { Log.write("Energie-Assertions gehalten: \(power.heldCount)") }
    }

    func refresh(quick: Bool = false) {
        guard !preview else { return }
        facts = Facts.current(monitor: monitor.state, reach: reachState, picture: monitor.picture)
        checks = Checks.build(facts)
        updatePower()
        if quick { return }
        reach.check { [weak self] st in
            guard let self else { return }
            let was = self.reachState
            self.reachState = st
            if case .ok = st, case .ok = was {} else if st != was { Log.write("MacBook \(Config.host): \(st)") }
            self.updatePower()
            self.facts.reach = st
            self.checks = Checks.build(self.facts)
        }
    }

    func perform(_ a: CheckAction) {
        guard !preview else { return }
        Log.write("Aktion: \(a)")
        notice = nil
        switch a {
        case .openNetworkPrefs:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.network")!)
        case .revealApplications:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        case .setupNetwork:
            guard let p = facts.primary else { return }
            let r = NetworkChanger.setup(p)
            notice = r.ok ? "Netzwerk: \(r.message)" : "Netzwerk nicht geändert – \(r.message)"
        case .resetNetwork:
            // zuerst den Dienst, dessen Einstellung gesichert wurde (exakt wiederherstellen)
            guard let svc = facts.backup?.service ?? facts.primary?.service else { return }
            let r = NetworkChanger.reset(service: svc)
            notice = r.ok ? "Netzwerk zurückgesetzt. \(r.message)" : "Netzwerk nicht geändert – \(r.message)"
        case .startMonitor:
            monitor.start()
        case .stopMonitor:
            monitor.stop()
        case .enableAutostart, .repairAutostart:
            do { try Autostart.enable(); notice = "Autostart ist an. Ab der nächsten Anmeldung startet der Monitor-Modus von selbst." }
            catch { notice = "Autostart konnte nicht eingeschaltet werden: \(error.localizedDescription)" }
        case .disableAutostart:
            Autostart.disable()
            notice = "Autostart ist aus. Die Datei wurde gelöscht."
        case .showLog:
            showLog()
        case .removeLegacyAutostart:
            notice = "Alte Skript-Installation: " + Autostart.removeLegacy()
        }
        refresh()
    }

    func showLog() {
        Log.write("Protokoll geöffnet")
        Log.flush()
        if !FileManager.default.fileExists(atPath: Config.logFile.path) {
            FileManager.default.createFile(atPath: Config.logFile.path, contents: Data())
        }
        if !NSWorkspace.shared.open(Config.logFile) {
            NSWorkspace.shared.activateFileViewerSelecting([Config.logFile])
        }
    }

    /// Führt die gewählten Deinstallations-Schritte aus. Rückgabe: Protokollzeilen.
    @discardableResult
    func runUninstall(_ o: UninstallOptions) -> [String] {
        var out: [String] = []
        func note(_ s: String) { out.append(s); Log.write("Deinstallation: \(s)") }
        monitor.stopAndWait()
        let fm = FileManager.default
        if o.autostart {
            if fm.fileExists(atPath: Config.agentPlist.path) { Autostart.disable(); note("Autostart entfernt") }
            else { note("Autostart war nicht eingerichtet") }
            if Autostart.legacyInstalled { note("Alte Skript-Installation: " + Autostart.removeLegacy()) }
        }
        if o.network && networkChangedByUs, let svc = facts.backup?.service ?? facts.primary?.service {
            let r = NetworkChanger.reset(service: svc)
            note(r.ok ? "Netzwerk „\(svc)“ zurückgesetzt" : "Netzwerk NICHT zurückgesetzt: \(r.message)")
        }
        if o.data {
            // Kiosk-Chrome einer alten Installation darf nicht mehr laufen, wenn sein Profil gelöscht wird
            Autostart.killChromeUsingOldProfile()
            Log.write("Deinstallation: lösche Einstellungen, Protokoll (und ein altes Chrome-Profil)")
            Log.flush()
            Log.enabled = false
            // Netzwerk-Sicherung behalten, solange das Netzwerk nicht zurückgesetzt ist – sonst ginge die
            // alte Einstellung verloren. Alles andere im Ordner wird gelöscht.
            let keepBackup = NetworkBackup.load() != nil
            var targets = [Config.logFile, Config.savedState]
            if keepBackup {
                let items = (try? fm.contentsOfDirectory(at: Config.supportDir, includingPropertiesForKeys: nil)) ?? []
                targets += items.filter { $0.lastPathComponent != Config.networkBackupFile.lastPathComponent }
            } else {
                targets.append(Config.supportDir)
            }
            for u in targets where fm.fileExists(atPath: u.path) {
                do { try fm.removeItem(at: u); out.append("Gelöscht: \(u.path)") }
                catch { out.append("Nicht gelöscht: \(u.path) (\(error.localizedDescription))") }
            }
            if keepBackup {
                out.append("Behalten: \(Config.networkBackupFile.path) (Netzwerk ist noch nicht zurückgesetzt; "
                           + "damit kann es später wiederhergestellt werden)")
            }
            UserDefaults.standard.removePersistentDomain(forName: Config.bundleID)
        }
        if o.trashApp {
            let app = Bundle.main.bundleURL
            if !Config.isAppBundle {
                out.append("App nicht in den Papierkorb (läuft nicht als .app)")
            } else if Config.dryRun {
                out.append("[Testmodus] würde in den Papierkorb legen: \(app.path)")
                if Log.enabled { Log.write(out.last!) }
            } else {
                do { try fm.trashItem(at: app, resultingItemURL: nil); out.append("App in den Papierkorb gelegt") }
                catch { out.append("App nicht in den Papierkorb gelegt: \(error.localizedDescription)") }
            }
        }
        FileHandle.standardError.write((out.joined(separator: "\n") + "\n").data(using: .utf8)!)
        return out
    }
}

// MARK: - Testkanal (nur IMAC_RECEIVER_DRY_RUN=1 + IMAC_RECEIVER_TEST_DIR)
//
// <dir>/cmd: eine Zeile pro Befehl – Name einer CheckAction (genau der Weg der Buttons), "dump",
// "uninstall [autostart] [network] [data] [trashApp]", "closeWindow", "player" (Player-Zustand als JSON),
// "key <zeichen|esc> [cmd]" (Tastendruck wie von der Tastatur, z. B. „key q cmd“ = Cmd+Q), "showWindow", "quit".
// Ergebnisse werden an <dir>/out.txt angehängt.

extension AppModel {
    func pollTestCommands(_ dir: String) {
        let cmdURL = URL(fileURLWithPath: dir).appendingPathComponent("cmd")
        guard let text = try? String(contentsOf: cmdURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: cmdURL)
        var out = ""
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            let parts = line.split(separator: " ").map(String.init)
            out += "> \(line)\n"
            if let a = CheckAction(rawValue: parts[0]) {
                perform(a)
                if let n = notice { out += "notice: \(n)\n" }
            } else if parts[0] == "dump" {
                refresh(quick: true)
                out += Checks.text(checks) + "\n"
                out += "monitor=\(monitor.state) picture=\(monitor.picture) window=\(windowVisible() ? "sichtbar" : "versteckt") "
                    + "assertions: display=\(power.displayHeld) system=\(power.systemHeld) activity=\(power.activityHeld) "
                    + String(format: "mem=%.1fMB", Double(memoryFootprint()) / 1_048_576) + "\n"
            } else if parts[0] == "uninstall" {
                var o = UninstallOptions(autostart: false, network: false, data: false, trashApp: false)
                o.autostart = parts.contains("autostart"); o.network = parts.contains("network")
                o.data = parts.contains("data"); o.trashApp = parts.contains("trashApp")
                out += runUninstall(o).joined(separator: "\n") + "\n"
            } else if parts[0] == "player" {
                if let p = monitor.player, let d = try? JSONSerialization.data(withJSONObject: p.testSnapshot, options: [.sortedKeys]) {
                    out += String(decoding: d, as: UTF8.self) + "\n"
                } else {
                    out += "player=aus\n"
                }
            } else if parts[0] == "key", parts.count >= 2 {
                let chars = parts[1] == "esc" ? "\u{1b}" : parts[1]
                let cmd = parts.contains("cmd")
                let code: UInt16 = parts[1] == "esc" ? 53 : (parts[1] == "q" ? 12 : (parts[1] == "s" ? 1 : 0))
                let target = NSApp.keyWindow
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: cmd ? [.command] : [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target?.windowNumber ?? 0,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(e)
                }
                out += "keyWindow=\(target?.title ?? "-") monitor=\(monitor.state) window=\(windowVisible() ? "sichtbar" : "versteckt")\n"
            } else if parts[0] == "showWindow" {
                onShowWindow?()
                out += "window=\(windowVisible() ? "sichtbar" : "versteckt")\n"
            } else if parts[0] == "closeWindow" {
                NSApp.windows.first { $0.title == "iMac Display – Empfänger" }?.performClose(nil)   // wie roter Knopf
                out += "window=\(windowVisible() ? "sichtbar" : "versteckt")\n"
            } else if parts[0] == "quit" {
                out += "quit\n"
                append(out, dir)
                NSApp.terminate(nil)
                return
            } else {
                out += "unbekannter Befehl\n"
            }
        }
        append(out, dir)
    }

    private func append(_ s: String, _ dir: String) {
        let u = URL(fileURLWithPath: dir).appendingPathComponent("out.txt")
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close() }
        else { try? s.data(using: .utf8)!.write(to: u) }
    }
}

// MARK: - Views

extension CheckStatus {
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .neutral: return "circle.dashed"
        }
    }
    var color: Color {
        switch self {
        case .ok: return Color(nsColor: .systemGreen)
        case .warn: return Color(nsColor: .systemOrange)
        case .error: return Color(nsColor: .systemRed)
        case .neutral: return Color(nsColor: .systemGray)
        }
    }
}

struct CheckRow: View {
    let item: CheckItem
    let perform: (CheckAction) -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(item.status.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(item.detail).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let hint = item.hint {
                    (Text("Was tun? ").bold() + Text(hint))
                        .font(.callout).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                if !item.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(item.actions) { b in
                            if b.prominent {
                                Button(b.title) { perform(b.action) }.buttonStyle(.borderedProminent).disabled(!b.enabled)
                            } else {
                                Button(b.title) { perform(b.action) }.disabled(!b.enabled)
                            }
                        }
                    }.padding(.top, 4)
                }
                if let dt = item.disclosureTitle, let text = item.disclosureText {
                    DisclosureGroup(dt, isExpanded: $expanded) {
                        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    }.font(.callout).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

struct ChecklistView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "display").font(.system(size: 34)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iMac Display – Empfänger").font(.title2.bold())
                    Text("Zeigt das Bild des MacBooks auf diesem iMac (Kabel-Verbindung zu \(Config.hostIP)).")
                        .foregroundColor(.secondary)
                }
                Spacer()
                if Config.dryRun { Text("TESTMODUS").font(.caption.bold()).foregroundColor(.orange) }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            if let n = model.notice {
                Text(n).font(.callout).padding(.horizontal, 20).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.checks.enumerated()), id: \.element.id) { idx, item in
                    CheckRow(item: item, perform: model.perform)
                    if idx < model.checks.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 20)
            Divider()
            HStack {
                Button("Protokoll anzeigen") { model.showLog() }
                Button("Deinstallieren …") { model.showUninstall = true }
                Spacer()
                Text("Prüft alle 2 Sekunden").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $model.showUninstall) { UninstallSheet(model: model) }
    }
}

struct UninstallSheet: View {
    @ObservedObject var model: AppModel
    @State private var result: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iMac Display Empfänger entfernen").font(.title3.bold())
            if let result {
                ForEach(result, id: \.self) { Text("• " + $0).font(.callout) }
                HStack { Spacer(); Button("Beenden") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Wähle aus, was entfernt werden soll:").foregroundColor(.secondary)
                Toggle("Autostart entfernen (~/Library/LaunchAgents/\(Config.agentLabel).plist)", isOn: $model.uninstall.autostart)
                Toggle(model.networkChangedByUs ? "Netzwerk zurücksetzen (Ethernet-Einstellung von vorher wiederherstellen)"
                                                : "Netzwerk zurücksetzen (nicht nötig – wurde nicht von dieser App geändert)",
                       isOn: $model.uninstall.network).disabled(!model.networkChangedByUs)
                Toggle("Einstellungen und Protokoll löschen (auch ein Chrome-Profil früherer Versionen)", isOn: $model.uninstall.data)
                Toggle("App in den Papierkorb legen", isOn: $model.uninstall.trashApp)
                Text("Andere Programme und Einstellungen bleiben unberührt.").font(.caption).foregroundColor(.secondary)
                HStack {
                    Spacer()
                    Button("Abbrechen") { model.showUninstall = false }.keyboardShortcut(.cancelAction)
                    Button("Entfernen") { result = model.runUninstall(model.uninstall) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - App-Delegate / Fenster

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = AppModel()
    var window: NSWindow!
    let monitorAtLaunch: Bool
    static let startMonitorNotification = Notification.Name("de.local.imac-display-receiver.startMonitor")

    init(monitorAtLaunch: Bool) { self.monitorAtLaunch = monitorAtLaunch }

    func applicationDidFinishLaunching(_ note: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Config.bundleID)
            .filter { $0.processIdentifier != getpid() }
        if Config.isAppBundle, let other = others.first {
            Log.write("App läuft bereits (PID \(other.processIdentifier)) – aktiviere sie und beende diese Kopie"
                      + (monitorAtLaunch ? " (Monitor-Modus wird dort gestartet)" : ""))
            if monitorAtLaunch {
                // Autostart kam zu spät (macOS hatte die App schon geöffnet): dort den Monitor-Modus starten.
                DistributedNotificationCenter.default().postNotificationName(
                    AppDelegate.startMonitorNotification, object: nil, userInfo: nil, deliverImmediately: true)
            }
            other.activate(options: [.activateIgnoringOtherApps])
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: AppDelegate.startMonitorNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.model.monitor.state != .running else { return }
            Log.write("Monitor-Modus auf Anforderung des Autostarts")
            self.model.perform(.startMonitor)
        }
        Log.write("Gestartet\(monitorAtLaunch ? " (--monitor)" : "") – \(Config.executablePath), Ziel \(Config.host)\(Config.dryRun ? ", TESTMODUS" : "")")
        buildMenu()
        let host = NSHostingView(rootView: ChecklistView(model: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "iMac Display – Empfänger"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        model.onShowWindow = { [weak self] in self?.showWindow() }
        model.windowVisible = { [weak self] in self?.window.isVisible ?? false }
        model.onHideWindow = { [weak self] in
            self?.window.orderOut(nil)
            Log.write("Fenster ausgeblendet (Monitor-Modus läuft)")
        }
        model.start()
        if monitorAtLaunch {
            model.perform(.startMonitor)
            if model.monitor.state != .running { showWindow() }   // Problem → sofort sichtbar
        } else {
            showWindow()
        }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.write("Fenster angezeigt")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.monitor.state == .running {
            sender.orderOut(nil)       // Monitor-Modus läuft weiter
            model.monitor.player?.bringToFront()
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    /// Cmd+Q / „Beenden“: im Monitor-Modus nur den Monitor-Modus beenden (Fenster erscheint wieder) –
    /// genau wie früher Cmd+Q im Chrome-Vollbild. Sonst die App beenden (Exit 0 → Autostart startet sie nicht neu).
    @objc func quitPressed(_ sender: Any?) {
        if model.monitor.state == .running {
            model.monitor.userQuit()
        } else {
            NSApp.terminate(sender)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(quitPressed(_:)) {
            item.title = model.monitor.state == .running ? "Monitor-Modus beenden" : "\(Config.appName) beenden"
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        Log.write("Beendet")
        Log.flush()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Über \(Config.appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "\(Config.appName) ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quit = NSMenuItem(title: "\(Config.appName) beenden", action: #selector(quitPressed(_:)), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Fenster")
        win.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimieren", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

// MARK: - Vorschaubilder (--render-preview <Ordner>), ohne ImageRenderer (macOS 13+)

enum PreviewRenderer {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ok = WiredInterface(bsd: "en0", name: "Ethernet", linkActive: true, ipv4: [Config.myIP], service: "Ethernet",
                                config: IPv4Config(method: "Manual", addresses: [Config.myIP], masks: [Config.netmask]))
        var all = Facts(); all.decoder = .hardware(ms: 14); all.wired = [ok]; all.reach = .ok(200); all.monitor = .off; all.autostart = .on
        all.backup = NetworkBackup(service: "Ethernet", previous: IPv4Config(method: "DHCP"), savedAt: Date()); all.autoLogin = "imac"

        var running = all; running.monitor = .running
        running.picture = .playing(fps: 52, width: 4096, height: 2304, hardware: true)

        var waiting = running; waiting.picture = .waiting(connected: false); waiting.reach = .fail("Zeitüberschreitung")

        var software = all; software.decoder = .software(ms: 230)

        var unreachable = all; unreachable.reach = .fail("Zeitüberschreitung")

        var firstRun = Facts(); firstRun.decoder = .hardware(ms: 14); firstRun.reach = .fail("x")
        firstRun.wired = [WiredInterface(bsd: "en0", name: "Ethernet", linkActive: true, ipv4: ["169.254.12.7"], service: "Ethernet",
                                         config: IPv4Config(method: "DHCP"))]

        var noCable = firstRun
        noCable.wired = [WiredInterface(bsd: "en0", name: "Ethernet", linkActive: false, ipv4: [], service: "Ethernet", config: IPv4Config(method: "DHCP"))]

        var failing = running; failing.decoder = .failed("Decoder nicht verfügbar (-12906)")
        failing.picture = .failing("Dekodierfehler: Vorgang konnte nicht abgeschlossen werden (-12909)")

        var legacy = all; legacy.legacyAgent = true

        let states: [(String, Facts)] = [("1-alles-ok", all), ("2-monitor-laeuft", running), ("3-kein-signal", waiting),
                                         ("4-software-dekodierung", software), ("5-macbook-nicht-erreichbar", unreachable),
                                         ("6-erster-start", firstRun), ("7-kein-kabel", noCable), ("8-bildfehler", failing),
                                         ("9-alte-installation", legacy)]
        for (name, f) in states {
            let model = AppModel(preview: f)
            write(AnyView(ChecklistView(model: model)), to: dir.appendingPathComponent("\(name).png"))
        }
        let m = AppModel(preview: all)
        write(AnyView(UninstallSheet(model: m).background(Color(nsColor: .windowBackgroundColor))), to: dir.appendingPathComponent("10-deinstallieren.png"))
        renderIdle(to: dir.appendingPathComponent("11-ruhebild-2048x1152pt.png"))
    }

    /// Ruhebild des Players in iMac-Größe (2048×1152 pt, @2x)
    private static func renderIdle(to url: URL) {
        let size = NSSize(width: 2048, height: 1152)
        let v = PlayerRootView(frame: NSRect(origin: .zero, size: size), videoLayer: CALayer(), hideCursor: false)
        v.setIdleSubtitle("Warte auf MacBook \(Config.hostIP) …")
        v.shiftIdleText(animated: false)
        let win = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = v
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("geschrieben: \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh) px, Versatz \(Int(v.idleOffset.x)),\(Int(v.idleOffset.y)) pt)")
        }
    }

    private static func write(_ view: AnyView, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("geschrieben: \(url.path) (\(Int(size.width))x\(Int(size.height)) pt)")
        }
    }
}
