import AppKit
import CoreGraphics
import CoreMedia
import ServiceManagement

/// Owns server, encoder and the on-demand virtual display + capture. Used in both modes:
/// CLI (stdout logs, Ctrl+C) and menu bar app (NSStatusItem, setup window, login item).
///
/// Lifecycle of the virtual display (unless --always-on / --test-pattern):
///   first WebSocket client → create display, start capture, force keyframe
///   no client for `idleTimeout` seconds → stop capture, destroy display.
/// All state lives on the main thread. Callbacks from other threads are delivered with
/// `onMainRunLoop` (CFRunLoopPerformBlock) instead of DispatchQueue.main: display creation and modal
/// alerts spin nested run loops, and the GCD main queue is not drained inside a running main-queue block.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, SetupActions {
    private var opts: CLIOptions
    private let appMode: Bool
    private let server: StreamServer
    private let encoder: H264Encoder

    // display / capture
    private var display: VirtualDisplay?
    private var capture: ScreenCapture?
    private var capturing = false
    private var generation = 0            // bumps on every activate/deactivate; stale async results are dropped
    private var transitioning = false     // guards against re-entrance while display creation spins the run loop
    private var lastClientSeen = Date.distantPast
    private var lastClientCount = 0
    private var nextActivationAttempt = Date.distantPast
    private var captureRetries = 0
    private var permissionMissing = false
    private var displaysCreated = 0

    // server / transmission
    private var transmissionEnabled = true
    private var serverRunning = false
    private var serverError: String?
    private var clientIP: String?
    private var clientStats: [String: Any]?

    // demo window
    private var demoWanted: Bool
    private var demo: DemoWindowController?

    // test pattern
    private var patternTimer: DispatchSourceTimer?
    private var patternFrames: [CVPixelBuffer] = []

    // stats
    private var curFPS = 0.0
    private var curMbit = 0.0
    private var logAcc = (frames: 0, bytes: 0, keys: 0, secs: 0.0)

    // setup window / probes
    private lazy var setupModel = SetupModel(actions: self)
    private var setupWindow: SetupWindowController?
    private var probe: ProbeResult?
    private var probing = false
    private var lastProbe = Date.distantPast
    private var shownErrorIDs: Set<String> = []
    private var hasErrorCheck = false

    // UI (app mode)
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Warte auf iMac …", action: nil, keyEquivalent: "")
    private let demoItem = NSMenuItem(title: "Testbild auf iMac anzeigen", action: nil, keyEquivalent: "")
    private let transmissionItem = NSMenuItem(title: "Übertragung aktiv", action: nil, keyEquivalent: "")

    private var timers: [Timer] = []
    private var sigSources: [DispatchSourceSignal] = []
    private var shuttingDown = false

    private var usesSetupUI: Bool { appMode || opts.setupWindow }

    init(options: CLIOptions, appMode: Bool, indexHTML: Data) {
        self.opts = options
        self.appMode = appMode
        self.demoWanted = options.demoWindow
        self.server = StreamServer(options: .init(port: options.port, allowAnyNetwork: options.allowAnyNetwork),
                                   indexHTML: indexHTML)
        self.encoder = H264Encoder(settings: .init(fps: options.fps, bitrateMbit: options.bitrate))
        super.init()
        if appMode {
            UserDefaults.standard.register(defaults: ["transmissionEnabled": true])
            transmissionEnabled = UserDefaults.standard.bool(forKey: "transmissionEnabled")
        }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if appMode {
            DistributedNotificationCenter.default().addObserver(forName: showSetupNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { logLine("Zweiter Start erkannt – öffne „Einrichtung & Status“"); self?.showSetup(nil) }
            }
        }
        if DryRun.isOn { logLine("Dry-Run aktiv: Systemänderungen werden nur protokolliert.") }

        let server = self.server, encoder = self.encoder
        encoder.onConfig = { server.setConfig($0) }
        encoder.onFrame = { data, key, ts in server.broadcastVideo(data, isKeyframe: key, timestampUs: ts) }
        server.onClientConnected = { [weak self] in
            encoder.requestKeyframe()
            onMainRunLoop { self?.clientConnected() }
        }
        server.onKeyframeRequested = { encoder.requestKeyframe() }
        server.onClientStats = { [weak self] ip, stats in
            onMainRunLoop {
                self?.clientIP = ip
                self?.clientStats = stats
            }
        }

        if appMode { setUpStatusItem() }
        installSignalHandlers()

        if transmissionEnabled {
            startServer()
            if let e = serverError, !appMode { fail("Server konnte nicht starten (Port \(opts.port)): \(e)", code: 1) }
        } else {
            logLine("Übertragung ist ausgeschaltet (Menü „Übertragung aktiv“).")
        }

        if opts.testPattern {
            if transmissionEnabled { startTestPattern() }
        } else {
            print(opts.alwaysOn
                  ? "Virtuelles Display: dauerhaft (--always-on)"
                  : "Virtuelles Display wird angelegt, sobald der iMac verbunden ist (und \(Int(opts.idleTimeout)) s nach dem Trennen entfernt).")
            if !opts.noCapture && !CGPreflightScreenCaptureAccess() {
                permissionMissing = true
                // App mode: no system prompt on its own – the setup window opens (red check) and the
                // request happens only when the user clicks "Erlauben …".
                if !appMode {
                    print("Hinweis: Bildschirmaufnahme scheint nicht erlaubt zu sein – es wird beim ersten Client trotzdem versucht.")
                }
            }
        }
        printURLs(port: opts.port)

        addTimer(0.5) { $0.tick() }
        addTimer(2.0) { $0.sampleStats() }
        tick()
        let firstRun = appMode && !UserDefaults.standard.bool(forKey: "setupShown")
        if firstRun || opts.setupWindow { showSetup(nil) }
        refreshSetup()
        if usesSetupUI { runProbe() }
        if !appMode { print("Läuft. Beenden mit Ctrl+C.") }
        if opts.testActions {
            onMainRunLoop(after: 3) { [weak self] in self?.runActionTest() }
        } else if opts.testUninstall {
            onMainRunLoop(after: 3) { [weak self] in self?.performUninstall(UninstallOptions()) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanUp()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Double-clicking the (already running) app in Finder opens the setup window.
        if appMode { showSetup(nil) }
        return false
    }

    // MARK: - Server on/off

    private func startServer() {
        guard !serverRunning else { return }
        do {
            try server.start()
            serverRunning = true
            serverError = nil
        } catch {
            serverRunning = false
            serverError = "\(error)"
            logLine("Server konnte nicht starten (Port \(opts.port)): \(error)")
        }
    }

    func setTransmission(_ on: Bool) { applyTransmission(on, persist: true) }

    /// Main switch. `persist: false` (uninstall) stops everything without remembering "off" for later starts.
    private func applyTransmission(_ on: Bool, persist: Bool) {
        if on {
            transmissionEnabled = true
            startServer()
            if opts.testPattern && patternTimer == nil { startTestPattern() }
            nextActivationAttempt = .distantPast
            logLine("Übertragung eingeschaltet" + (serverError != nil ? " – Server-Fehler: \(serverError!)" : ""))
        } else {
            transmissionEnabled = false
            deactivate(reason: "Übertragung ausgeschaltet")
            patternTimer?.cancel(); patternTimer = nil
            if serverRunning { server.stop() }
            serverRunning = false
            serverError = nil
            clientIP = nil; clientStats = nil
            logLine("Übertragung ausgeschaltet (Server gestoppt, kein virtuelles Display)")
        }
        if appMode && persist { UserDefaults.standard.set(transmissionEnabled, forKey: "transmissionEnabled") }
        refreshSetup()
    }

    @objc private func toggleTransmission(_ sender: Any?) {
        setTransmission(!transmissionEnabled)
    }

    // MARK: - Client polling / display lifecycle

    private func clientConnected() {
        // A (re)connecting iMac is the trigger to retry after an earlier failure (e.g. missing permission).
        nextActivationAttempt = .distantPast
        tick()
    }

    private func tick() {
        guard !shuttingDown else { return }
        let n = serverRunning ? server.clientCount : 0
        if n > 0 { lastClientSeen = Date() }
        if n != lastClientCount {
            lastClientCount = n
            if n == 0 { clientIP = nil; clientStats = nil }
            refreshSetup()
        }
        guard !transitioning else { return }
        if !transmissionEnabled {
            if display != nil { deactivate(reason: "Übertragung ausgeschaltet") } // e.g. switched off during creation
            return
        }
        guard !opts.testPattern else { return }

        if display == nil {
            if (n > 0 || opts.alwaysOn) && Date() >= nextActivationAttempt { activate() }
        } else if !opts.alwaysOn && n == 0 && Date().timeIntervalSince(lastClientSeen) >= opts.idleTimeout {
            deactivate(reason: "seit \(Int(opts.idleTimeout)) s kein iMac verbunden")
        }
    }

    private func activate() {
        if appMode && !opts.noCapture && !CGPreflightScreenCaptureAccess() {
            // No phantom display without permission; re-check every few seconds (cheap) and on every connect.
            if !permissionMissing {
                permissionMissing = true
                logLine("Keine Berechtigung für Bildschirmaufnahme – virtuelles Display wird nicht angelegt.")
                refreshSetup()
            }
            nextActivationAttempt = Date().addingTimeInterval(5)
            return
        }
        transitioning = true
        defer { transitioning = false }
        generation += 1
        let d: VirtualDisplay
        do {
            d = try VirtualDisplay(name: opts.name, pixelWidth: opts.width, pixelHeight: opts.height,
                                   fps: Double(opts.fps), hiDPI: opts.hiDPI)
        } catch {
            logLine("Virtuelles Display konnte nicht erstellt werden: \(error) – neuer Versuch in 5 s")
            nextActivationAttempt = Date().addingTimeInterval(5)
            return
        }
        if !transmissionEnabled || shuttingDown {
            // Switched off (or quitting) while the display was being created (nested run loop).
            _ = d.destroy()
            return
        }
        displaysCreated += 1
        display = d
        logLine("Virtuelles Display \"\(opts.name)\" erstellt (#\(displaysCreated)): \(d.currentModeDescription())")
        if !d.hasWantedMode { fixMode(generation: generation, attempt: 1) }

        if opts.noCapture {
            logLine("--no-capture: keine Bildschirmaufnahme")
            if demoWanted { showDemo() }
            refreshSetup()
            return
        }
        let encoder = self.encoder
        let cap = ScreenCapture(displayID: d.displayID, width: opts.width, height: opts.height, fps: opts.fps,
                                queue: encoder.queue) { pb, pts in
            encoder.encode(pb, pts: pts)
        }
        let gen = generation
        cap.onStopWithError = { [weak self] error in
            onMainRunLoop { self?.captureStopped(generation: gen, error: error) }
        }
        capture = cap
        captureRetries = 0
        encoder.startIdleRefresh()
        startCapture(generation: gen)
        if demoWanted { showDemo() }
        refreshSetup()
    }

    /// Retries setting the HiDPI mode until the display is online with the wanted mode (max ~10 s).
    private func fixMode(generation gen: Int, attempt: Int) {
        onMainRunLoop(after: 0.5) { [weak self] in
            guard let self, gen == self.generation, let d = self.display else { return }
            if d.ensureMode(timeout: 0, quiet: attempt < 20) {
                logLine("Displaymodus gesetzt: \(d.currentModeDescription())")
                self.encoder.requestKeyframe()
            } else if attempt < 20 {
                self.fixMode(generation: gen, attempt: attempt + 1)
            }
        }
    }

    private func startCapture(generation gen: Int) {
        guard gen == generation, let cap = capture else { return }
        Task { @MainActor [weak self] in
            do {
                try await cap.start()
                guard let self, gen == self.generation, self.capture === cap else {
                    cap.stop() // display was removed meanwhile
                    return
                }
                self.capturing = true
                self.captureRetries = 0
                self.permissionMissing = false
                self.encoder.requestKeyframe()
                self.refreshSetup()
            } catch {
                self?.captureFailed(generation: gen, error: error)
            }
        }
    }

    private func captureFailed(generation gen: Int, error: Error) {
        guard gen == generation, !shuttingDown else { return }
        capturing = false
        if case ScreenCaptureError.permissionDenied = error {
            permissionDenied()
            return
        }
        logLine("Bildschirmaufnahme konnte nicht gestartet werden: \(error)")
        captureRetries += 1
        if captureRetries <= 5 {
            onMainRunLoop(after: 1) { [weak self] in self?.startCapture(generation: gen) }
        } else {
            deactivate(reason: "Aufnahme schlägt wiederholt fehl")
            nextActivationAttempt = Date().addingTimeInterval(10)
        }
        refreshSetup()
    }

    private func captureStopped(generation gen: Int, error: Error) {
        guard gen == generation, !shuttingDown, let cap = capture else { return }
        capturing = false
        if ScreenCapture.isPermissionError(error) {
            permissionDenied()
            return
        }
        cap.stop()
        onMainRunLoop(after: 1) { [weak self] in self?.startCapture(generation: gen) }
        refreshSetup()
    }

    private let permissionMessage = """

    FEHLER: Keine Berechtigung für Bildschirmaufnahme.
    Bitte in Systemeinstellungen > Datenschutz & Sicherheit > Bildschirm- & Systemaudioaufnahme
    das Programm erlauben, aus dem imac-display gestartet wird (z. B. Terminal, iTerm oder Xcode).
    Danach das Programm (Terminal) komplett beenden, neu öffnen und imac-display erneut starten.

    """

    private func permissionDenied() {
        if !appMode {
            FileHandle.standardError.write(permissionMessage.data(using: .utf8)!)
            shutdown(3)
        }
        logLine("Keine Berechtigung für Bildschirmaufnahme – virtuelles Display wird wieder entfernt.")
        permissionMissing = true
        deactivate(reason: "keine Berechtigung")
        nextActivationAttempt = Date().addingTimeInterval(5)
        refreshSetup()
    }

    private func deactivate(reason: String) {
        guard display != nil || capture != nil else { return }
        transitioning = true
        defer { transitioning = false }
        generation += 1
        demo?.close()
        demo = nil
        capture?.stop()
        capture = nil
        capturing = false
        encoder.stop() // idle refresh off, session + cached frame released
        if let d = display {
            let gone = d.destroy()
            logLine("Virtuelles Display entfernt (\(reason))" + (gone ? "" : " – meldet sich noch als online"))
        }
        display = nil
        refreshSetup()
    }

    // MARK: - Test pattern

    private func startTestPattern() {
        print("Testbild-Modus: \(opts.width)x\(opts.height) @ \(opts.fps) fps (kein virtuelles Display, keine Aufnahme)")
        if patternFrames.isEmpty {
            patternFrames = (0..<8).map { makeNV12Buffer(width: opts.width, height: opts.height, frame: $0) }
        }
        let frames = patternFrames
        let encoder = self.encoder
        var idx = 0
        let t = DispatchSource.makeTimerSource(queue: encoder.queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(opts.fps), leeway: .microseconds(500))
        t.setEventHandler {
            encoder.encode(frames[idx % frames.count], pts: CMClockGetTime(CMClockGetHostTimeClock()))
            idx += 1
        }
        t.resume()
        patternTimer = t
    }

    // MARK: - Demo window

    private func showDemo() {
        guard let d = display else { return }
        if let demo, demo.displayID == d.displayID { demo.show(); return }
        demo?.close()
        let c = DemoWindowController(displayID: d.displayID)
        c.onUserClose = { [weak self] in
            guard let self else { return }
            self.demoWanted = false
            self.demo = nil
            self.updateStatus()
        }
        demo = c
        c.show()
    }

    @objc private func toggleDemo(_ sender: Any?) {
        demoWanted.toggle()
        if demoWanted {
            if display != nil { showDemo() }
        } else {
            demo?.close()
            demo = nil
        }
        updateStatus()
    }

    // MARK: - Stats / status

    private func sampleStats() {
        let s = encoder.takeStats()
        curFPS = Double(s.frames) / 2
        curMbit = Double(s.bytes) * 8 / 2 / 1_000_000
        logAcc.frames += s.frames; logAcc.bytes += s.bytes; logAcc.keys += s.keyframes; logAcc.secs += 2
        if logAcc.secs >= 10 {
            let n = serverRunning ? server.clientCount : 0
            if n > 0 || display != nil || logAcc.frames > 0 {
                logLine(String(format: "%.1f fps kodiert, %.1f Mbit/s, %d Keyframes, %d Client(s)%@",
                               Double(logAcc.frames) / logAcc.secs, Double(logAcc.bytes) * 8 / logAcc.secs / 1_000_000,
                               logAcc.keys, n, display != nil ? ", Display aktiv" : ""))
            }
            logAcc = (0, 0, 0, 0)
        }
        refreshSetup()
        if usesSetupUI {
            let interval: TimeInterval = setupWindow?.isVisible == true ? 2 : 10
            if Date().timeIntervalSince(lastProbe) >= interval { runProbe() }
        }
    }

    private func statusText() -> String {
        if !transmissionEnabled { return "Übertragung ausgeschaltet" }
        if serverError != nil { return "Fehler: Server startet nicht (Port \(opts.port))" }
        let n = server.clientCount
        if n == 0 {
            if permissionMissing && !opts.testPattern { return "Warte auf iMac … (Bildschirmaufnahme nicht erlaubt)" }
            return "Warte auf iMac …"
        }
        let who = n == 1 ? "iMac verbunden" : "iMac verbunden (\(n) Clients)"
        if opts.testPattern || capturing {
            let prefix = opts.testPattern ? "Testbild-Modus · " : ""
            return prefix + who + String(format: " · %.0f fps · %.0f Mbit/s", curFPS, curMbit)
        }
        if permissionMissing { return who + " · Bildschirmaufnahme nicht erlaubt" }
        return who + " · Starte Aufnahme …"
    }

    private func currentAppStatus() -> AppStatus {
        var a = AppStatus()
        a.bundlePath = Bundle.main.bundlePath
        a.inApplications = isInstalledInApplications
        a.onDiskImage = Bundle.main.bundlePath.hasPrefix("/Volumes/")
        a.screenCaptureGranted = opts.noCapture || capturing || CGPreflightScreenCaptureAccess()
        a.transmissionEnabled = transmissionEnabled
        a.serverRunning = serverRunning
        a.serverError = serverError
        a.port = opts.port
        a.clients = serverRunning ? server.clientCount : 0
        a.clientIP = clientIP
        a.clientStats = clientStats
        a.displayActive = display != nil
        a.pixelSize = "\(opts.width)×\(opts.height)"
        a.pointSize = opts.hiDPI ? "\(opts.width / 2)×\(opts.height / 2)" : "\(opts.width)×\(opts.height)"
        a.capturing = capturing
        a.fps = curFPS
        a.mbit = curMbit
        a.testPattern = opts.testPattern
        a.loginStatus = SMAppService.mainApp.status
        a.dryRun = DryRun.isOn
        return a
    }

    /// Recomputes the setup checklist and the menu bar state. Cheap; called often.
    private func refreshSetup() {
        if usesSetupUI {
            setupModel.update(app: currentAppStatus(), probe: probe)
            let errors = setupModel.errorRowIDs
            hasErrorCheck = !errors.isEmpty
            // Open the window whenever a check turns red (once per check until it is fixed again).
            let new = errors.subtracting(shownErrorIDs)
            shownErrorIDs.formIntersection(errors)
            if !new.isEmpty && appMode && !shuttingDown {
                shownErrorIDs.formUnion(new)
                logLine("Einrichtung: Problem bei \(new.sorted().joined(separator: ", ")) – Fenster wird geöffnet")
                showSetup(nil)
            }
        }
        updateStatus()
    }

    private func runProbe() {
        guard !probing else { return }
        probing = true
        lastProbe = Date()
        DispatchQueue.global(qos: .utility).async {
            let r = SystemProbe.probe()
            onMainRunLoop { [weak self] in
                guard let self else { return }
                self.probing = false
                self.probe = r
                self.lastProbe = Date()
                self.refreshSetup()
            }
        }
    }

    private func updateStatus() {
        guard appMode, let item = statusItem else { return }
        statusLine.title = statusText()
        demoItem.state = demoWanted ? .on : .off
        transmissionItem.state = transmissionEnabled ? .on : .off
        let connected = serverRunning && server.clientCount > 0
        let bad = hasErrorCheck || serverError != nil
        let symbol = bad ? "display.trianglebadge.exclamationmark" : "display"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "iMac Display")
            ?? NSImage(systemSymbolName: bad ? "exclamationmark.triangle" : "display", accessibilityDescription: "iMac Display")
        if let img {
            img.isTemplate = true
            item.button?.image = img
            item.button?.title = ""
        } else {
            item.button?.title = bad ? "iMac !" : "iMac"
        }
        item.button?.appearsDisabled = !connected && !bad
        item.button?.toolTip = "iMac Display – " + statusLine.title
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let setup = NSMenuItem(title: "Einrichtung & Status …", action: #selector(showSetup(_:)), keyEquivalent: ",")
        setup.target = self
        menu.addItem(setup)

        demoItem.target = self
        demoItem.action = #selector(toggleDemo(_:))
        menu.addItem(demoItem)

        transmissionItem.target = self
        transmissionItem.action = #selector(toggleTransmission(_:))
        menu.addItem(transmissionItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Beenden", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        updateStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
    }

    @objc func showSetup(_ sender: Any?) {
        if setupWindow == nil { setupWindow = SetupWindowController(model: setupModel) }
        if appMode { UserDefaults.standard.set(true, forKey: "setupShown") }
        setupModel.update(app: currentAppStatus(), probe: probe)
        setupWindow?.show()
        if Date().timeIntervalSince(lastProbe) > 1 { runProbe() }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - SetupActions

    func openSettings(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    func showLog() {
        let url = URL(fileURLWithPath: AppLog.path ?? AppLog.defaultPath)
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: console.path) {
            NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            setupModel.message = "Noch kein Protokoll vorhanden (\(url.path))."
        }
    }

    func requestScreenCapture() {
        if DryRun.isOn {
            logLine("[Dry-Run] würde CGRequestScreenCaptureAccess() aufrufen und die Systemeinstellungen öffnen")
            setupModel.message = "Dry-Run: Anfrage „Bildschirmaufnahme“ + Systemeinstellungen öffnen"
            return
        }
        // Puts "iMac Display" into the list in System Settings (switched off) – the user decides there.
        let granted = CGRequestScreenCaptureAccess()
        logLine("Bildschirmaufnahme angefragt (bereits erlaubt: \(granted))")
        if !granted { openSettings(SettingsURL.screenCapture) }
        setupModel.message = granted ? "Bildschirmaufnahme ist erlaubt."
            : "Systemeinstellungen geöffnet: „iMac Display“ einschalten. Fragt macOS danach, „Beenden & erneut öffnen“ wählen – oder hier „Neu starten“."
        refreshSetup()
    }

    /// For a stale entry (switch shows "on" but does not work, typically after an update of the
    /// ad-hoc signed app): removes only this app's entry so that "Erlauben …" can add it again.
    func resetScreenCaptureEntry() {
        let a = NSAlert()
        a.messageText = "Eintrag „Bildschirmaufnahme“ zurücksetzen?"
        a.informativeText = "Entfernt nur den Eintrag von „iMac Display“ aus der Liste in den Systemeinstellungen. "
            + "Danach „Erlauben …“ klicken und den Schalter neu einschalten.\n\n"
            + "Ausgeführt wird: /usr/bin/tccutil \(Self.tccResetArguments(bundleID: bundleID).joined(separator: " "))"
        a.addButton(withTitle: "Zurücksetzen")
        a.addButton(withTitle: "Abbrechen")
        guard runAlert(a) == .alertFirstButtonReturn else { return }
        setupModel.message = resetScreenCapturePermission()
        refreshSetup()
    }

    func relaunchApp() {
        if DryRun.isOn {
            logLine("[Dry-Run] würde neu starten: \(Bundle.main.bundlePath)")
            setupModel.message = "Dry-Run: App würde neu starten."
            return
        }
        relaunch(at: Bundle.main.bundleURL)
    }

    func revokeScreenCapture() {
        let a = NSAlert()
        a.messageText = "Berechtigung „Bildschirmaufnahme“ entziehen?"
        a.informativeText = "iMac Display kann danach den virtuellen Bildschirm nicht mehr übertragen und startet neu.\n\n"
            + "Ausgeführt wird: tccutil reset ScreenCapture \(bundleID)"
        a.addButton(withTitle: "Entziehen und neu starten")
        a.addButton(withTitle: "Abbrechen")
        guard runAlert(a) == .alertFirstButtonReturn else { return }
        setupModel.message = resetScreenCapturePermission()
        if !DryRun.isOn { relaunch(at: Bundle.main.bundleURL) }
    }

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "de.local.imac-display" }

    static func tccResetArguments(bundleID: String) -> [String] { ["reset", "ScreenCapture", bundleID] }

    /// `tccutil reset ScreenCapture <bundle id>` – only this app's entry; runs as the user (no sudo).
    private func resetScreenCapturePermission() -> String {
        let args = Self.tccResetArguments(bundleID: bundleID)
        if DryRun.isOn {
            logLine("[Dry-Run] würde ausführen: /usr/bin/tccutil \(args.joined(separator: " "))")
            return "Dry-Run: /usr/bin/tccutil \(args.joined(separator: " "))"
        }
        let r = Shell.run("/usr/bin/tccutil", args)
        logLine("tccutil \(args.joined(separator: " ")) → \(r.status): \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return r.status == 0 ? "Berechtigung „Bildschirmaufnahme“ entzogen." : "tccutil fehlgeschlagen (\(r.status)): \(r.output)"
    }

    func configureNetwork(service: String) {
        switch NetworkSetup.configure(service: service) {
        case .done(let s): setupModel.message = DryRun.isOn ? s : "„\(service)“ hat jetzt die Adresse \(NetworkSetup.macIP)."
        case .cancelled: setupModel.message = "Abgebrochen – nichts geändert."
        case .failed(let e): setupModel.message = "Fehler beim Einrichten: \(e)"
        }
        onMainRunLoop(after: 1) { [weak self] in self?.runProbe() }
    }

    func restoreNetwork(service: String) {
        switch NetworkSetup.restore(service: service) {
        case .done(let s): setupModel.message = DryRun.isOn ? s : "„\(service)“ wurde zurückgesetzt."
        case .cancelled: setupModel.message = "Abgebrochen – nichts geändert."
        case .failed(let e): setupModel.message = "Fehler beim Zurücksetzen: \(e)"
        }
        onMainRunLoop(after: 1) { [weak self] in self?.runProbe() }
    }

    func moveToApplications() {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        var dir = URL(fileURLWithPath: "/Applications")
        if !fm.isWritableFile(atPath: dir.path) {
            dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        }
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        if DryRun.isOn {
            logLine("[Dry-Run] würde kopieren: \(src.path) → \(dest.path) und von dort neu starten")
            setupModel.message = "Dry-Run: \(src.path) → \(dest.path)"
            return
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: src, to: dest)
            logLine("App kopiert nach \(dest.path) – starte von dort neu")
            relaunch(at: dest)
        } catch {
            logLine("Kopieren nach \(dest.path) fehlgeschlagen: \(error)")
            alert(title: "Verschieben fehlgeschlagen",
                  text: "\(error.localizedDescription)\n\nAlternativ „iMac Display“ im Finder in den Ordner „Programme“ ziehen.")
        }
    }

    /// Quits and starts the app at `url` again – only after this process is really gone (single-instance check).
    private func relaunch(at url: URL) {
        logLine("Neustart: \(url.path)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "i=0; while /bin/kill -0 \(getpid()) 2>/dev/null && [ $i -lt 100 ]; do /bin/sleep 0.1; i=$((i+1)); done; "
                       + "/usr/bin/open \(Shell.quote(url.path))"]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Login item

    private var isInstalledInApplications: Bool {
        let p = Bundle.main.bundleURL.deletingLastPathComponent().path
        return p == "/Applications" || p == (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
    }

    func setLoginItem(_ on: Bool) {
        let svc = SMAppService.mainApp
        if on && !isInstalledInApplications && !DryRun.isOn {
            // A login item pointing to the disk image or a download folder would break later.
            setupModel.message = "„Bei Anmeldung starten“ geht erst, wenn die App im Ordner „Programme“ liegt."
            refreshSetup()
            return
        }
        if DryRun.isOn {
            logLine("[Dry-Run] würde Anmeldeobjekt \(on ? "registrieren" : "entfernen")")
            setupModel.message = "Dry-Run: Anmeldeobjekt \(on ? "registrieren" : "entfernen")"
            return
        }
        do {
            if on { try svc.register() } else { try svc.unregister() }
            logLine("Anmeldeobjekt \(on ? "registriert" : "entfernt") (Status \(svc.status.rawValue))")
            setupModel.message = nil
        } catch {
            logLine("Anmeldeobjekt: \(error.localizedDescription)")
            if svc.status != .requiresApproval {
                setupModel.message = "„Bei Anmeldung starten“ konnte nicht geändert werden: \(error.localizedDescription)"
                    + (isInstalledInApplications ? "" : " – zuerst die App in „Programme“ verschieben.")
            }
        }
        if svc.status == .requiresApproval {
            setupModel.message = "macOS verlangt eine Bestätigung: Systemeinstellungen → Allgemein → Anmeldeobjekte → „iMac Display“ einschalten."
        }
        refreshSetup()
    }

    // MARK: - Uninstall

    func performUninstall(_ o: UninstallOptions) {
        let dry = DryRun.isOn
        var done: [String] = []
        var problems: [String] = []
        let backups = NetworkSetup.backups.keys.sorted()
        let appPath = Bundle.main.bundlePath
        logLine("Deinstallation\(dry ? " (Dry-Run)" : ""): Anmeldeobjekt=\(o.loginItem) Bildschirmaufnahme=\(o.screenCapture) "
                + "Netzwerk=\(o.network) \(backups) Firewall=\(o.firewall) Einstellungen/Protokoll=\(o.prefsAndLog) App=\(o.app)")

        // 1) Steps with an administrator dialog first: cancelling the first one stops everything (nothing removed).
        var adminSteps: [(label: String, run: () -> NetworkSetup.Outcome)] = []
        if o.network {
            for svc in backups {
                let desc = NetworkSetup.restoreDescription(service: svc)
                adminSteps.append(("Netzwerk „\(svc)“ zurückgesetzt (\(desc))", { NetworkSetup.restore(service: svc) }))
            }
        }
        if o.firewall && SystemProbe.firewallListsApp(appPath) {
            adminSteps.append(("Firewall-Eintrag entfernt", { Firewall.removeApp(appPath) }))
        }
        for (i, step) in adminSteps.enumerated() {
            switch step.run() {
            case .done: done.append(step.label)
            case .cancelled:
                if i == 0 {
                    setupModel.message = "Deinstallation abgebrochen – nichts entfernt."
                    return
                }
                problems.append("\(step.label.components(separatedBy: " ").first ?? "Schritt"): abgebrochen")
            case .failed(let e): problems.append("\(step.label): \(e)")
            }
        }
        applyTransmission(false, persist: false)

        // 2) Login item
        if o.loginItem {
            if dry { logLine("[Dry-Run] würde Anmeldeobjekt entfernen (SMAppService.mainApp.unregister)"); done.append("Anmeldeobjekt entfernt") }
            else {
                let st = SMAppService.mainApp.status
                if st == .notRegistered || st == .notFound { done.append("Anmeldeobjekt (war nicht registriert)") }
                else {
                    do { try SMAppService.mainApp.unregister(); done.append("Anmeldeobjekt entfernt") }
                    catch { problems.append("Anmeldeobjekt: \(error.localizedDescription)") }
                }
            }
        }
        // 3) Screen Recording permission
        if o.screenCapture {
            let r = resetScreenCapturePermission()
            if r.hasPrefix("tccutil fehlgeschlagen") { problems.append(r) } else { done.append("Berechtigung „Bildschirmaufnahme“ entfernt") }
        }
        // 4) Preferences + log
        if o.prefsAndLog {
            let logPath = AppLog.path ?? AppLog.defaultPath
            if dry {
                logLine("[Dry-Run] würde Einstellungen (\(bundleID)) und \(logPath) löschen")
            } else {
                setupWindow?.close() // no window-frame autosave after the domain is gone
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
                try? FileManager.default.removeItem(atPath: logPath)
            }
            done.append("Einstellungen und Protokoll gelöscht")
        }
        // 5) The app itself
        if o.app {
            let url = Bundle.main.bundleURL
            if dry {
                logLine("[Dry-Run] würde in den Papierkorb legen: \(url.path)")
                done.append("App in den Papierkorb gelegt")
            } else {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); done.append("App in den Papierkorb gelegt") }
                catch { problems.append("App: \(error.localizedDescription) – bitte selbst in den Papierkorb ziehen") }
            }
        }
        logLine("Deinstallation\(dry ? " (Dry-Run)" : "") fertig: \(done.joined(separator: "; "))"
                + (problems.isEmpty ? "" : " | Probleme: \(problems.joined(separator: "; "))"))

        if opts.testUninstall { // automated dry-run test: no modal alert
            if dry { applyTransmission(true, persist: false) } else { NSApp.terminate(nil) }
            return
        }
        let a = NSAlert()
        a.messageText = dry ? "Dry-Run: Deinstallation simuliert" : "iMac Display wurde entfernt"
        a.informativeText = (done.isEmpty ? "" : "Erledigt:\n• " + done.joined(separator: "\n• "))
            + (problems.isEmpty ? "" : "\n\nNicht möglich:\n• " + problems.joined(separator: "\n• "))
            + (dry ? "\n\nEs wurde nichts geändert; die App läuft weiter." : "")
        a.addButton(withTitle: dry ? "OK" : "Beenden")
        _ = runAlert(a)
        if dry { applyTransmission(true, persist: false) } else { NSApp.terminate(nil) }
    }

    // MARK: - Automated dry-run test of every button path (--test-actions-dry-run)

    private func runActionTest() {
        precondition(DryRun.isOn)
        func step(_ name: String, _ body: () -> Void) {
            setupModel.message = nil
            body()
            logLine("TEST \(name) → \(setupModel.message ?? "-")")
        }
        logLine("TEST Menü: " + (statusItem?.menu?.items.map { $0.isSeparatorItem ? "—" : "\($0.title)\($0.state == .on ? " ✓" : "")" }
                                    .joined(separator: " | ") ?? "kein Menü"))
        showSetup(nil)
        logLine("TEST Fenster sichtbar: \(setupWindow?.isVisible == true); Zeilen: "
                + setupModel.rows.map { "\($0.id)=\($0.state)" }.joined(separator: ", "))
        let svc = ProcessInfo.processInfo.environment["IMAC_DISPLAY_TEST_SERVICE"] ?? probe?.chosen?.serviceName
        if let svc {
            step("Einrichten(\(svc))") { configureNetwork(service: svc) }
            logLine("TEST Sicherung: \(NetworkSetup.backup(for: svc).map { "\($0.mode.rawValue) \($0.ip ?? "")" } ?? "keine")"
                    + " → Zurücksetzen: \(NetworkSetup.restoreCommand(service: svc))")
            step("Zurücksetzen(\(svc))") { restoreNetwork(service: svc) }
            logLine("TEST Sicherung danach: \(NetworkSetup.backup(for: svc) == nil ? "gelöscht" : "noch da")")
            step("Einrichten erneut (für Deinstallation)") { configureNetwork(service: svc) }
        } else {
            logLine("TEST Netzwerk übersprungen (kein Dienst, IMAC_DISPLAY_TEST_SERVICE setzen)")
        }
        step("Bei Anmeldung starten EIN") { setLoginItem(true) }
        step("Bei Anmeldung starten AUS") { setLoginItem(false) }
        step("Erlauben …") { requestScreenCapture() }
        step("In Programme verschieben") { moveToApplications() }
        step("Neu starten") { relaunchApp() }
        step("Entziehen/Eintrag zurücksetzen (ohne Rückfrage)") { setupModel.message = resetScreenCapturePermission() }
        step("Übertragung AUS") { setTransmission(false) }
        logLine("TEST Server läuft: \(serverRunning), Display: \(display != nil), Status: \(statusText())")
        step("Übertragung EIN") { setTransmission(true) }
        logLine("TEST Server läuft: \(serverRunning), Status: \(statusText())")
        step("Testbild EIN") { toggleDemo(nil) }
        step("Testbild AUS") { toggleDemo(nil) }
        logLine("TEST Deinstallation (alle Haken) …")
        opts.testUninstall = true
        performUninstall(UninstallOptions())
        logLine("TEST Server nach Deinstallation (Dry-Run → wieder an): \(serverRunning); Netzwerk-Sicherungen: \(NetworkSetup.backups.keys.sorted())")
        logLine("TEST fertig")
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func alert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        _ = runAlert(a)
    }

    private func runAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        return a.runModal()
    }

    // MARK: - Timers, signals, shutdown

    private func addTimer(_ interval: TimeInterval, _ body: @escaping @MainActor (AppController) -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        RunLoop.main.add(t, forMode: .common) // keeps running while the menu is open / an alert is shown
        timers.append(t)
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sigSources = [SIGINT, SIGTERM].map { sig in
            // Not the main queue: GCD's main queue is not drained while an NSAlert runs modally.
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                onMainRunLoop {
                    guard let self else { exit(0) }
                    self.shutdown(0)
                }
            }
            src.resume()
            return src
        }
        // Test hook: `kill -USR1 <pid>` toggles the main switch "Übertragung aktiv" (like the menu item).
        signal(SIGUSR1, SIG_IGN)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        usr1.setEventHandler { [weak self] in
            onMainRunLoop {
                guard let self else { return }
                logLine("SIGUSR1: Übertragung \(self.transmissionEnabled ? "aus" : "ein")")
                self.setTransmission(!self.transmissionEnabled)
            }
        }
        usr1.resume()
        sigSources.append(usr1)
    }

    private func cleanUp(exitCode: Int32 = 0) {
        guard !shuttingDown else { return }
        shuttingDown = true
        logLine("Beende ...")
        // Watchdog: never hang on shutdown (the display disappears with the process anyway).
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(exitCode) }
        timers.forEach { $0.invalidate() }
        patternTimer?.cancel()
        demo?.close()
        capture?.stop()
        encoder.stop()
        if serverRunning { server.stop() }
        _ = display?.destroy(waitTimeout: 1)
        display = nil
        fflush(stdout)
    }

    private func shutdown(_ code: Int32) -> Never {
        cleanUp(exitCode: code)
        exit(code)
    }
}

/// Posted by a second start (see main.swift): the running instance opens its setup window.
let showSetupNotification = Notification.Name("de.local.imac-display.showSetup")

/// Runs `block` on the main run loop in common modes (also inside nested run loops / modal alerts).
func onMainRunLoop(_ block: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated { block() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

func onMainRunLoop(after seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) {
    let t = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { block() } }
    CFRunLoopAddTimer(CFRunLoopGetMain(), t, .commonModes)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
