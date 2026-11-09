import AppKit

enum MonitorState: Equatable {
    case off
    case running
    case failed(String)      // Start nicht möglich
}

/// Monitor-Modus = der native Player im Vollbild (Player.swift). Kein Browser nötig.
final class MonitorController {
    private(set) var state: MonitorState = .off { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// Cmd+Q im Monitor-Modus → Fenster wieder zeigen (bewusst beendet: kein Neustart)
    var onUserExit: (() -> Void)?
    /// Player läuft → Fenster ausblenden
    var onStarted: (() -> Void)?

    private(set) var player: PlayerController?

    var isRunning: Bool { player != nil }

    func start() {
        if player != nil { state = .running; player?.bringToFront(); return }
        guard !NSScreen.screens.isEmpty else {
            state = .failed("Kein Bildschirm gefunden.")
            Log.write("Monitor-Modus nicht möglich: kein Bildschirm")
            return
        }
        let p = PlayerController(host: Config.host)
        player = p
        p.start()
        state = .running
        onStarted?()
    }

    func stop() {
        guard let p = player else { state = .off; return }
        player = nil
        p.stop()
        state = .off
    }

    func stopAndWait() { stop() }

    /// Cmd+Q bzw. Menü „Beenden“ während der Player vorne ist
    func userQuit() {
        Log.write("Monitor-Modus mit Cmd+Q beendet – Fenster wird angezeigt")
        stop()
        onUserExit?()
    }

    var picture: PictureInfo { player?.picture ?? .off }
}
