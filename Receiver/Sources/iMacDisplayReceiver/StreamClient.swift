import Foundation
import QuartzCore

/// WebSocket-Client für ws://HOST/ws (URLSessionWebSocketTask, macOS 10.15+).
/// Verbindet sich für immer neu (1 → 1,5 → 2 s), bricht nach 3 s ohne Verbindungsaufbau und nach 8 s ohne
/// Nachricht ab (z. B. Kabel gezogen, MacBook eingefroren). Jede Nachricht zählt als Lebenszeichen – auch die
/// Steuer-Nachrichten (0x03, Protokoll v2: der Server wiederholt `status` alle 2 s). Alle Ereignisse laufen auf `queue`.
final class StreamClient: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case opened
        case closed(String)
        case config(Data)
        /// `data[offset...]` = Annex B; receivedAt = CACurrentMediaTime()
        case video(Data, offset: Int, key: Bool, timestampUs: UInt64, receivedAt: Double)
        /// 0x03 + JSON-Objekt mit "type" (v2: "status", "brightness"; unbekannte Typen ignoriert der Player)
        case control([String: Any])
    }

    static let connectTimeout = 3.0
    static let deadAfter = 8.0
    static let reconnectMin = 1.0, reconnectMax = 2.0

    let url: URL
    let queue = DispatchQueue(label: "imacdisplay.stream", qos: .userInteractive)
    var onEvent: ((Event) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var opened = false
    private var running = false
    private var connectStartedAt = 0.0
    private var reconnectAt: Double?
    private var backoff = StreamClient.reconnectMin
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var _lastMessageAt = 0.0
    private var _lastVideoAt = 0.0
    private var _openedAt = 0.0
    private var _controls = 0
    private var _isOpen = false
    private var _reconnects = 0
    private var _attempts = 0
    var lastMessageAt: Double { lock.lock(); defer { lock.unlock() }; return _lastMessageAt }
    /// letzte Video-Nachricht (0x02) dieser Verbindung; 0 = noch keine seit dem Verbinden
    var lastVideoAt: Double { lock.lock(); defer { lock.unlock() }; return _lastVideoAt }
    /// Zeitpunkt des Verbindungsaufbaus
    var openedAt: Double { lock.lock(); defer { lock.unlock() }; return _openedAt }
    /// Anzahl empfangener Steuer-Nachrichten (Test/Statistik)
    var controlCount: Int { lock.lock(); defer { lock.unlock() }; return _controls }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return _isOpen }
    var reconnects: Int { lock.lock(); defer { lock.unlock() }; return _reconnects }

    init(url: URL) {
        self.url = url
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]          // nie über einen System-Proxy
        c.timeoutIntervalForRequest = 30           // eigene Zeitlimits (3 s / 8 s) greifen vorher
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        let oq = OperationQueue()
        oq.underlyingQueue = queue
        oq.maxConcurrentOperationCount = 1
        session = URLSession(configuration: c, delegate: self, delegateQueue: oq)
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            self.connect()
        }
    }

    /// Endgültig beenden (die URLSession hält ihren Delegate fest → invalidieren).
    func stop() {
        queue.sync {
            running = false
            timer?.cancel(); timer = nil
            generation += 1
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            opened = false
            setOpen(false)
            session.invalidateAndCancel()
        }
    }

    /// Text-Nachricht (JSON) an den Server, nur wenn verbunden.
    func send(_ text: String) {
        queue.async {
            guard self.opened, let t = self.task else { return }
            t.send(.string(text)) { _ in }
        }
    }

    /// Sofort trennen und neu verbinden (Test/Watchdog).
    func reconnect(_ reason: String) {
        queue.async { self.closed(self.generation, reason) }
    }

    // MARK: intern (alles auf `queue`)

    private func setOpen(_ v: Bool) { lock.lock(); _isOpen = v; lock.unlock() }

    private func connect() {
        guard running else { return }
        generation += 1
        let g = generation
        opened = false
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 64 << 20             // Standard 1 MB – 4K-Keyframes sind größer
        task = t
        connectStartedAt = CACurrentMediaTime()
        lock.lock(); _attempts += 1; lock.unlock()
        t.resume()
        receive(t, g)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async { self.received(result, t, g) }   // bereits auf `queue`; async hält die Reihenfolge
        }
    }

    private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>, _ t: URLSessionWebSocketTask, _ g: Int) {
        guard g == generation, running else { return }
        switch result {
        case .failure(let e):
            closed(g, (e as NSError).localizedDescription)
        case .success(let msg):
            let now = CACurrentMediaTime()
            lock.lock(); _lastMessageAt = now; lock.unlock()
            if !opened { markOpen() }
            if case .data(let d) = msg { handle(d, now) }
            receive(t, g)
        }
    }

    private func markOpen() {
        guard !opened else { return }
        opened = true
        backoff = Self.reconnectMin
        let now = CACurrentMediaTime()
        lock.lock(); _lastMessageAt = now; _openedAt = now; _lastVideoAt = 0; lock.unlock()
        setOpen(true)
        onEvent?(.opened)
    }

    private func handle(_ d: Data, _ now: Double) {
        guard let type = d.first else { return }
        let b = d.startIndex
        switch type {
        case 0x01:
            onEvent?(.config(d.subdata(in: (b + 1)..<d.endIndex)))
        case 0x02:
            guard d.count > 10 else { return }
            let flags = d[b + 1]
            var ts: UInt64 = 0
            for i in 2..<10 { ts = ts << 8 | UInt64(d[b + i]) }      // big-endian
            lock.lock(); _lastVideoAt = now; lock.unlock()
            onEvent?(.video(d, offset: 10, key: flags & 1 == 1, timestampUs: ts, receivedAt: now))
        case 0x03:
            lock.lock(); _controls += 1; lock.unlock()
            let json = d.subdata(in: (b + 1)..<d.endIndex)
            if let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], obj["type"] is String {
                onEvent?(.control(obj))
            }
        default:
            break                                                   // unbekannter Typ: ignorieren
        }
    }

    private func closed(_ g: Int, _ reason: String) {
        guard g == generation, running, let t = task else { return }
        generation += 1
        t.cancel(with: .goingAway, reason: nil)
        task = nil
        opened = false
        setOpen(false)
        onEvent?(.closed(reason))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard running, reconnectAt == nil else { return }
        reconnectAt = CACurrentMediaTime() + backoff
        backoff = min(Self.reconnectMax, backoff * 1.5)
        lock.lock(); _reconnects += 1; lock.unlock()
    }

    private func tick() {
        guard running else { return }
        let now = CACurrentMediaTime()
        if task == nil {
            if let at = reconnectAt { if now >= at { reconnectAt = nil; connect() } } else { scheduleReconnect() }
        } else if !opened {
            if now - connectStartedAt > Self.connectTimeout { closed(generation, "Zeitüberschreitung beim Verbinden") }
        } else if now - lastMessageAt > Self.deadAfter {
            closed(generation, "seit \(Int(Self.deadAfter)) s keine Daten")
        }
    }

    // MARK: URLSessionWebSocketDelegate (auf `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        markOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        closed(generation, "vom MacBook geschlossen (\(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        closed(generation, error.map { ($0 as NSError).localizedDescription } ?? "Verbindung beendet")
    }
}
