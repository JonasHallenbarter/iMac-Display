import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Views

struct StatusIcon: View {
    let state: CheckState
    var size: CGFloat = 18
    var body: some View {
        let (name, color): (String, Color) = {
            switch state {
            case .ok: return ("checkmark.circle.fill", .green)
            case .warning: return ("exclamationmark.triangle.fill", .orange)
            case .error: return ("xmark.octagon.fill", .red)
            case .inactive: return ("minus.circle", .gray)
            case .info: return ("info.circle.fill", .blue)
            }
        }()
        Image(systemName: name).foregroundColor(color).font(.system(size: size)).frame(width: size + 6)
    }
}

struct CheckRowView: View {
    let row: CheckRow
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(state: row.state).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline)
                Text(row.detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let hint = row.hint {
                    (Text("Was tun? ").bold() + Text(hint))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if !row.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(row.actions) { act in
                            if act.prominent {
                                Button(act.title) { act.run() }.buttonStyle(.borderedProminent).controlSize(.small)
                            } else {
                                Button(act.title) { act.run() }.controlSize(.small)
                            }
                        }
                    }.padding(.top, 2)
                }
                if let t = row.disclosureTitle, let text = row.disclosureText {
                    DisclosureGroup(t) {
                        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(Color.secondary.opacity(0.08)).cornerRadius(6)
                    }.font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    /// Previews: expand all "Was wird geändert?" sections is not possible with DisclosureGroup state, so ignore.
    var body: some View {
        let summary = model.summary
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "display").font(.system(size: 30)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iMac Display – Einrichtung & Status").font(.title3).bold()
                    HStack(spacing: 4) {
                        StatusIcon(state: summary.0, size: 12)
                        Text(summary.1).font(.callout).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            if model.app.dryRun {
                Text("Testmodus (Dry-Run): Änderungen am System werden nur protokolliert, nicht ausgeführt.")
                    .font(.caption).frame(maxWidth: .infinity).padding(6).background(Color.yellow.opacity(0.35))
            }
            if let m = model.message {
                Text(m).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1)).textSelection(.enabled)
            }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    let rows = model.rows
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        CheckRowView(row: r)
                        if i < rows.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 4)
            }
            Divider()
            BottomBar(model: model).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 600, idealHeight: 820)
        .sheet(isPresented: $model.showUninstall) { UninstallView(model: model) }
    }
}

struct BottomBar: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                Toggle("Übertragung aktiv", isOn: Binding(get: { model.app.transmissionEnabled },
                                                          set: { model.actions?.setTransmission($0) }))
                    .toggleStyle(.switch)
                Toggle("Bei Anmeldung starten", isOn: Binding(get: { model.app.loginStatus == .enabled },
                                                              set: { model.actions?.setLoginItem($0) }))
                    .toggleStyle(.switch)
                    .disabled(!model.app.inApplications && !model.app.dryRun && model.app.loginStatus != .enabled)
                Spacer()
            }
            HStack {
                Text(loginText).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.app.loginStatus == .requiresApproval {
                    Button("Bestätigen …") { model.actions?.openSettings(SettingsURL.loginItems) }.controlSize(.small)
                }
                Spacer()
                Button("Protokoll anzeigen") { model.actions?.showLog() }
                Button("Deinstallieren …") { model.openUninstall() }
            }
        }
    }

    private var loginText: String {
        switch model.app.loginStatus {
        case .enabled: return "Startet automatisch bei der Anmeldung."
        case .requiresApproval: return "Start bei Anmeldung wartet auf deine Bestätigung in den Systemeinstellungen."
        case _ where !model.app.inApplications:
            return "Automatischer Start geht erst, wenn die App im Ordner „Programme“ liegt."
        default: return "Startet nicht automatisch – einschalten, damit der iMac nach jedem Neustart gleich Bild bekommt."
        }
    }
}

struct UninstallView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        let backups = model.networkBackups
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 26)).foregroundColor(.red)
                Text("iMac Display deinstallieren").font(.title3).bold()
            }
            Text("Die angehakten Punkte werden rückgängig gemacht bzw. entfernt. Danach beendet sich iMac Display.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                item($model.uninstall.loginItem, "Automatischen Start abmelden", "„Bei Anmeldung starten“ wird ausgeschaltet.")
                item($model.uninstall.screenCapture, "Erlaubnis „Bildschirmaufnahme“ entfernen",
                     "Nur der Eintrag dieser App, kein Passwort nötig (tccutil reset ScreenCapture de.local.imac-display).")
                if !backups.isEmpty {
                    item($model.uninstall.network,
                         backups.count == 1 ? "Netzwerkeinstellung von „\(backups[0])“ zurücksetzen" : "Netzwerkeinstellungen zurücksetzen",
                         backups.map { "„\($0)“ zurück auf: \(NetworkSetup.restoreDescription(service: $0))" }.joined(separator: "\n")
                            + "\nFragt nach dem Administrator-Passwort.")
                } else {
                    notChanged("Netzwerkeinstellung", "Wurde von der App nicht geändert – bleibt, wie sie ist.")
                }
                if model.firewallEntry {
                    item($model.uninstall.firewall, "Firewall-Eintrag entfernen",
                         "Den Eintrag „iMac Display“ in der Firewall-Liste – fragt nach dem Administrator-Passwort.")
                }
                item($model.uninstall.prefsAndLog, "Einstellungen und Protokoll löschen",
                     "Einstellungen (de.local.imac-display) und ~/Library/Logs/iMacDisplay.log")
                item($model.uninstall.app, "Die App in den Papierkorb legen", model.app.bundlePath)
            }
            .padding(12).background(Color.secondary.opacity(0.07)).cornerRadius(8)
            if model.app.dryRun {
                Text("Testmodus (Dry-Run): es wird nichts entfernt, nur protokolliert.").font(.caption).foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { model.showUninstall = false }.keyboardShortcut(.cancelAction)
                Button("Entfernen und beenden") {
                    model.showUninstall = false
                    let o = model.uninstall
                    DispatchQueue.main.async { model.actions?.performUninstall(o) }
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func notChanged(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "minus.circle").foregroundColor(.gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.secondary)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func item(_ b: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: b) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Window

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    let model: SetupModel
    private var window: NSWindow?

    init(model: SetupModel) { self.model = model }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "iMac Display – Einrichtung & Status"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(model: model))
            w.setContentSize(NSSize(width: 660, height: 820))
            w.center()
            w.delegate = self
            w.setFrameAutosaveName("SetupWindow")
            window = w
        }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

// MARK: - Preview rendering (development: --render-setup-preview <dir>)

@MainActor
final class NoopActions: SetupActions {
    func moveToApplications() {}
    func requestScreenCapture() {}
    func revokeScreenCapture() {}
    func resetScreenCaptureEntry() {}
    func relaunchApp() {}
    func configureNetwork(service: String) {}
    func restoreNetwork(service: String) {}
    func openSettings(_ url: String) {}
    func setTransmission(_ on: Bool) {}
    func setLoginItem(_ on: Bool) {}
    func showLog() {}
    func performUninstall(_ o: UninstallOptions) {}
}

enum SetupPreview {
    @MainActor
    static func render(to dir: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let actions = NoopActions()
        func usb(active: Bool, addr: Bool) -> WiredInterface {
            WiredInterface(device: "en11", portName: "USB 10/100/1000 LAN", serviceName: "USB 10/100/1000 LAN",
                           linkActive: active, media: active ? "1000baseT <full-duplex>" : "none",
                           ipv4: addr && active ? [NetworkSetup.macIP] : [])
        }
        func cfg(_ manual: Bool) -> ServiceIPv4Config {
            manual ? ServiceIPv4Config(service: "USB 10/100/1000 LAN", mode: .manual, ip: NetworkSetup.macIP,
                                       subnet: NetworkSetup.netmask, router: nil, raw: "")
                : ServiceIPv4Config(service: "USB 10/100/1000 LAN", mode: .dhcp, ip: nil, subnet: nil, router: nil, raw: "")
        }
        var base = AppStatus()
        base.bundlePath = "/Applications/iMac Display.app"
        base.inApplications = true
        base.screenCaptureGranted = true
        base.serverRunning = true
        base.loginStatus = .enabled

        var states: [(String, AppStatus, ProbeResult)] = []

        // 1) Normal: everything running
        var a = base
        a.clients = 1; a.clientIP = "10.77.0.2"; a.displayActive = true; a.capturing = true; a.fps = 60; a.mbit = 48
        a.clientStats = ["fps": 59.9, "hw": "prefer-hardware", "dropped": 0, "decodeMs": 4.1]
        var p = ProbeResult(); p.wired = [usb(active: true, addr: true)]; p.chosen = p.wired.first
        p.chosenConfig = cfg(true); p.pingOK = true; p.firewallOn = true; p.firewallBlockAll = false
        states.append(("1-normal", a, p))

        // 2) Missing Screen Recording permission, app still in Downloads, iMac reachable but not connected
        a = base; a.screenCaptureGranted = false; a.inApplications = false
        a.bundlePath = NSHomeDirectory() + "/Downloads/iMac Display.app"; a.loginStatus = .notFound
        p.pingOK = true
        states.append(("2-keine-berechtigung", a, p))

        // 3) No cable, address not set yet
        a = base
        p = ProbeResult(); p.wired = [usb(active: false, addr: false)]; p.chosen = p.wired.first
        p.chosenConfig = cfg(false); p.firewallOn = false; p.firewallBlockAll = false
        states.append(("3-kein-kabel", a, p))

        // 4) Cable plugged in, address missing (error), local network hint, dry run
        a = base; a.dryRun = true; a.loginStatus = .requiresApproval
        p = ProbeResult(); p.wired = [usb(active: true, addr: false)]; p.chosen = p.wired.first
        p.chosenConfig = cfg(false); p.firewallOn = true; p.firewallBlockAll = false
        states.append(("4-adresse-fehlt", a, p))

        // 5) Transmission off
        a = base; a.transmissionEnabled = false; a.serverRunning = false
        p = ProbeResult(); p.wired = [usb(active: true, addr: true)]; p.chosen = p.wired.first
        p.chosenConfig = cfg(true); p.pingOK = true; p.firewallOn = false; p.firewallBlockAll = false
        states.append(("5-uebertragung-aus", a, p))

        var ok = true
        for (name, app, probe) in states {
            let m = SetupModel(actions: actions)
            m.update(app: app, probe: probe)
            ok = write(NSHostingView(rootView: SetupView(model: m)), size: NSSize(width: 660, height: 860),
                       to: "\(dir)/setup-\(name).png") && ok
        }
        // Local network hint variant
        do {
            var a = base; a.clients = 0
            var p = ProbeResult(); p.wired = [usb(active: true, addr: true)]; p.chosen = p.wired.first
            p.chosenConfig = cfg(true); p.pingOK = true; p.firewallOn = true; p.firewallBlockAll = false
            let m = SetupModel(actions: actions)
            m.update(app: a, probe: p)
            m.forceLocalNetworkHint = true
            ok = write(NSHostingView(rootView: SetupView(model: m)), size: NSSize(width: 660, height: 900),
                       to: "\(dir)/setup-6-lokales-netzwerk.png") && ok
        }
        // Uninstall sheet
        let m = SetupModel(actions: actions)
        m.update(app: base, probe: nil)
        m.networkBackups = ["USB 10/100/1000 LAN"]
        m.firewallEntry = true
        ok = write(NSHostingView(rootView: UninstallView(model: m)), size: NSSize(width: 520, height: 520),
                   to: "\(dir)/uninstall-sheet.png") && ok
        return ok ? 0 : 1
    }

    @MainActor
    private static func write(_ view: NSView, size: NSSize, to path: String) -> Bool {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        w.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        defer { w.orderOut(nil) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let ok = (try? png.write(to: URL(fileURLWithPath: path))) != nil
        print((ok ? "Gespeichert: " : "FEHLER: ") + path)
        return ok
    }
}
