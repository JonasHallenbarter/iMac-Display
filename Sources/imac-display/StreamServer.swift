import Foundation
import Network
import CryptoKit

/// HTTP + WebSocket-Server auf einem Port (Network.framework, handgeschriebenes HTTP/1.1 + RFC 6455).
/// API siehe docs/PROTOCOL.md (fix).
final class StreamServer {
    struct Options {
        var port: UInt16 = 8080
        var allowAnyNetwork = false
    }

    /// Wird aufgerufen, wenn ein neuer WebSocket-Client verbunden ist (beliebiger Thread).
    var onClientConnected: (() -> Void)? {
        get { callbackLock.withLock { _onClientConnected } }
        set { callbackLock.withLock { _onClientConnected = newValue } }
    }
    /// Client hat {"type":"keyframe"} geschickt oder Server hat wegen Rückstau Frames verworfen (beliebiger Thread).
    var onKeyframeRequested: (() -> Void)? {
        get { callbackLock.withLock { _onKeyframeRequested } }
        set { callbackLock.withLock { _onKeyframeRequested = newValue } }
    }

    /// Client hat {"type":"stats",...} geschickt: (Remote-IP, geparstes JSON). Beliebiger Thread.
    var onClientStats: ((String, [String: Any]) -> Void)? {
        get { callbackLock.withLock { _onClientStats } }
        set { callbackLock.withLock { _onClientStats = newValue } }
    }

    // MARK: - Private state

    private let options: Options
    private let indexHTML: Data
    /// Serielle Queue für den gesamten Zustand und alle NWConnection-Handler.
    private let queue = DispatchQueue(label: "imac-display.StreamServer")
    /// Callbacks laufen auf eigener serieller Queue → kein Deadlock, wenn der Aufrufer synchron zurückruft.
    private let callbackQueue = DispatchQueue(label: "imac-display.StreamServer.callbacks")
    private let callbackLock = NSLock()
    private var _onClientConnected: (() -> Void)?
    private var _onKeyframeRequested: (() -> Void)?
    private var _onClientStats: ((String, [String: Any]) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private var config: Data?
    private var rejectedIPsLogged: Set<String> = []
    private var lastBackpressureKeyframeRequest: Date = .distantPast

    private let countLock = NSLock()
    private var wsClientCount = 0

    /// Rückstaugrenze pro Client (unbestätigte Bytes).
    fileprivate static let backpressureLimit = 16 * 1024 * 1024
    /// Harte Grenze: darüber werden auch Keyframes verworfen.
    fileprivate static let hardLimit = 48 * 1024 * 1024
    fileprivate static let maxClientMessage = 1 * 1024 * 1024
    fileprivate static let maxHTTPHeader = 16 * 1024

    init(options: Options, indexHTML: Data) {
        self.options = options
        self.indexHTML = indexHTML
    }

    deinit {
        listener?.cancel()
    }

    func start() throws {
        // A port that was just released (main switch off → on) can stay busy for a moment: retry briefly.
        var attempt = 0
        while true {
            do {
                try startOnce()
                return
            } catch StreamServerError.listenFailed(let port, let underlying)
                where attempt < 10 && "\(underlying)".contains("Address already in use") {
                attempt += 1
                log("Port \(port) noch belegt – neuer Versuch (\(attempt)/10)")
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    private func startOnce() throws {
        guard let port = NWEndpoint.Port(rawValue: options.port) else {
            throw StreamServerError.invalidPort(options.port)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true            // Nagle aus (wichtig für WebSocket-Latenz)
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = false

        let listener = try NWListener(using: params, on: port)
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        var signalled = false

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !signalled { signalled = true; ready.signal() }
            case .failed(let error):
                if !signalled { startError = error; signalled = true; ready.signal() }
                else { self?.log("Listener-Fehler: \(error)") }
            case .waiting(let error):
                if !signalled { startError = error; signalled = true; ready.signal() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            queue.sync { self.listener = nil }
            throw StreamServerError.startTimeout
        }
        let err: Error? = queue.sync { startError }
        if let err {
            listener.cancel()
            queue.sync { self.listener = nil }
            throw StreamServerError.listenFailed(port: options.port, underlying: err)
        }
        log("Server läuft auf Port \(options.port)"
            + (options.allowAnyNetwork ? " (alle Netze erlaubt)" : " (nur Loopback, 10.77.0.0/24, Link-Local)"))
    }

    func stop() {
        // Wait until the listener is really cancelled, so an immediate start() can bind the port again.
        let cancelled = DispatchSemaphore(value: 0)
        var hadListener = false
        queue.sync {
            if let l = listener {
                hadListener = true
                l.newConnectionHandler = nil
                l.stateUpdateHandler = { state in
                    if case .cancelled = state { cancelled.signal() }
                }
                l.cancel()
            }
            listener = nil
            for c in connections.values { c.close(sendCloseFrame: true) }
            connections.removeAll()
            updateCount()
        }
        if hadListener { _ = cancelled.wait(timeout: .now() + 2) }
    }

    /// JSON-Objekt (UTF-8) des Stream-Configs. Wird gespeichert, an alle aktuellen Clients gesendet
    /// und jedem neuen Client direkt nach dem Verbinden zuerst geschickt. Thread-safe.
    func setConfig(_ json: Data) {
        queue.async {
            self.config = json
            let frame = Self.makeBinaryFrame(prefix: [0x01], payload: json)
            for c in self.connections.values where c.isOpen {
                c.send(frame)
                // Nach Config-Wechsel braucht der Decoder einen frischen Keyframe.
                c.markNeedsKeyframe()
            }
        }
    }

    /// Eine kodierte Access Unit (H.264 Annex B, bei Keyframes inkl. SPS/PPS). Thread-safe.
    func broadcastVideo(_ annexB: Data, isKeyframe: Bool, timestampUs: UInt64) {
        queue.async {
            let clients = self.connections.values.filter { $0.isOpen }
            guard !clients.isEmpty else { return }
            var header = [UInt8](repeating: 0, count: 10)
            header[0] = 0x02
            header[1] = isKeyframe ? 0x01 : 0x00
            for i in 0..<8 { header[2 + i] = UInt8((timestampUs >> (56 - 8 * UInt64(i))) & 0xFF) }
            var frame: Data?   // lazily, einmal für alle Clients
            var wantKeyframe = false
            let now = Date()

            for c in clients {
                if c.queuedBytes > Self.backpressureLimit {
                    if !isKeyframe || c.queuedBytes > Self.hardLimit {
                        if now.timeIntervalSince(c.lastBackpressureLog) >= 5 {
                            c.lastBackpressureLog = now
                            self.log("Rückstau bei \(c.ip) (\(c.queuedBytes / (1024 * 1024)) MB unbestätigt) – verwerfe Frames bis zum nächsten Keyframe")
                        }
                        c.markNeedsKeyframe()
                        wantKeyframe = true
                        continue
                    }
                }
                if c.needsKeyframe && !isKeyframe {
                    // Wartet schon länger als 1 s auf einen Keyframe → nachfordern.
                    if now.timeIntervalSince(c.needsKeyframeSince) >= 1 { wantKeyframe = true }
                    continue
                }
                if frame == nil { frame = Self.makeBinaryFrame(prefix: header, payload: annexB) }
                c.send(frame!)
                if isKeyframe { c.needsKeyframe = false }
            }

            if wantKeyframe, now.timeIntervalSince(self.lastBackpressureKeyframeRequest) >= 1 {
                self.lastBackpressureKeyframeRequest = now
                self.fireKeyframeRequested()
            }
        }
    }

    var clientCount: Int {
        countLock.withLock { wsClientCount }
    }

    // MARK: - Connections

    private func accept(_ conn: NWConnection) {
        let ip = Self.ipString(conn.endpoint)
        if !options.allowAnyNetwork && !Self.isAllowed(conn.endpoint) {
            if rejectedIPsLogged.insert(ip).inserted {
                log("Verbindung von \(ip) abgelehnt (nicht über Ethernet-Direktverbindung). --allow-any-network erlaubt das.")
            }
            conn.cancel()
            return
        }
        let client = ClientConnection(connection: conn, ip: ip, server: self)
        connections[ObjectIdentifier(client)] = client
        conn.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed:
                client.connection.cancel()
                self.connectionEnded(client)
            case .cancelled:
                self.connectionEnded(client)
            default:
                break
            }
        }
        conn.start(queue: queue)
        client.receiveLoop()
    }

    fileprivate func connectionEnded(_ client: ClientConnection) {
        guard connections.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.closed = true
        if client.isWebSocket {
            updateCount()
            log("WebSocket-Client \(client.ip) getrennt (\(clientCount) verbunden)")
        }
    }

    fileprivate func webSocketOpened(_ client: ClientConnection) {
        if let config {
            client.send(Self.makeBinaryFrame(prefix: [0x01], payload: config))
        }
        client.markNeedsKeyframe()
        updateCount()
        log("WebSocket-Client \(client.ip) verbunden (\(clientCount) verbunden)")
        let cb = onClientConnected
        if let cb { callbackQueue.async { cb() } }
    }

    fileprivate func handleText(_ text: String, from client: ClientConnection) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }
        switch type {
        case "keyframe":
            fireKeyframeRequested()
        case "stats":
            if let cb = onClientStats {
                let ip = client.ip
                callbackQueue.async { cb(ip, obj) }
            }
            let now = Date()
            if now.timeIntervalSince(client.lastStatsLog) >= 5 {
                client.lastStatsLog = now
                var parts: [String] = []
                for key in obj.keys.sorted() where key != "type" {
                    parts.append("\(key)=\(obj[key]!)")
                }
                log("Stats von \(client.ip): " + parts.joined(separator: " "))
            }
        default:
            break
        }
    }

    fileprivate func fireKeyframeRequested() {
        let cb = onKeyframeRequested
        if let cb { callbackQueue.async { cb() } }
    }

    fileprivate var indexHTMLData: Data { indexHTML }

    private func updateCount() {
        let n = connections.values.filter { $0.isWebSocket && !$0.closed }.count
        countLock.withLock { wsClientCount = n }
    }

    fileprivate func log(_ message: String) {
        print("[Server] \(message)")
        fflush(stdout)
    }

    // MARK: - Framing

    /// Unmaskierter Server→Client-Frame (FIN + opcode) mit Payload = prefix + payload. Ein einziger Kopiervorgang.
    fileprivate static func makeBinaryFrame(prefix: [UInt8], payload: Data, opcode: UInt8 = 0x2) -> Data {
        let len = prefix.count + payload.count
        var frame = Data(capacity: len + 10)
        frame.append(0x80 | opcode)
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(len >> 8))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            let l = UInt64(len)
            for i in 0..<8 { frame.append(UInt8((l >> (56 - 8 * UInt64(i))) & 0xFF)) }
        }
        frame.append(contentsOf: prefix)
        frame.append(payload)
        return frame
    }

    // MARK: - Network filter

    private static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return isAllowedV4([UInt8](a.rawValue))
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }          // ::1
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                     // fe80::/10
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {      // ::ffff:a.b.c.d
                return isAllowedV4(Array(b[12..<16]))
            }
            return false
        default:
            return false
        }
    }

    private static func isAllowedV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        if b[0] == 127 { return true }                                   // 127.0.0.0/8
        if b[0] == 10 && b[1] == 77 && b[2] == 0 { return true }         // 10.77.0.0/24
        if b[0] == 169 && b[1] == 254 { return true }                    // 169.254.0.0/16
        return false
    }

    private static func ipString(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        switch host {
        case .ipv4(let a):
            return "\(a)"
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            if b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {
                return "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
            }
            return "\(a)"
        case .name(let n, _):
            return n
        @unknown default:
            return "\(host)"
        }
    }
}

enum StreamServerError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case startTimeout
    case listenFailed(port: UInt16, underlying: Error)

    var description: String {
        switch self {
        case .invalidPort(let p): return "Ungültiger Port \(p)"
        case .startTimeout: return "Server-Start: Zeitüberschreitung"
        case .listenFailed(let p, let e): return "Port \(p) kann nicht geöffnet werden (belegt?): \(e)"
        }
    }
}

// MARK: - Per-connection state machine (nur auf der Server-Queue benutzt)

private final class ClientConnection {
    let connection: NWConnection
    let ip: String
    unowned let server: StreamServer

    var isWebSocket = false
    var closed = false
    var closing = false
    var queuedBytes = 0
    var needsKeyframe = true
    var needsKeyframeSince = Date()
    var lastStatsLog = Date.distantPast
    var lastBackpressureLog = Date.distantPast
    var isOpen: Bool { isWebSocket && !closed && !closing }

    private var buffer: [UInt8] = []
    private var fragmentOpcode: UInt8 = 0
    private var fragmentData: [UInt8] = []

    init(connection: NWConnection, ip: String, server: StreamServer) {
        self.connection = connection
        self.ip = ip
        self.server = server
    }

    func markNeedsKeyframe() {
        if !needsKeyframe {
            needsKeyframe = true
            needsKeyframeSince = Date()
        }
    }

    func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                if self.isWebSocket { self.processFrames() } else { self.processHTTP() }
            }
            if isComplete || error != nil {
                self.close(sendCloseFrame: false)
                return
            }
            if !self.closed && !self.closing { self.receiveLoop() }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        let count = data.count
        queuedBytes += count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queuedBytes -= count
            if error != nil { self.close(sendCloseFrame: false) }
        })
    }

    /// Sendet optional einen Close-Frame und beendet danach die Verbindung.
    func close(sendCloseFrame: Bool, code: UInt16 = 1000) {
        guard !closed, !closing else { return }
        if sendCloseFrame && isWebSocket {
            closing = true
            let payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
            let frame = StreamServer.makeBinaryFrame(prefix: [], payload: payload, opcode: 0x8)
            connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            // Sicherheitsnetz, falls der Send nie fertig wird
            let conn = connection
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { conn.cancel() }
        } else {
            connection.cancel()
        }
    }

    // MARK: HTTP

    private func processHTTP() {
        guard let end = findHeaderEnd() else {
            if buffer.count > StreamServer.maxHTTPHeader {
                respond(status: "431 Request Header Fields Too Large", body: Data("Header zu groß\n".utf8))
            }
            return
        }
        let headerBytes = buffer[0..<end]
        buffer.removeFirst(end + 4)
        guard let head = String(bytes: headerBytes, encoding: .utf8) ?? String(bytes: headerBytes, encoding: .isoLatin1) else {
            respond(status: "400 Bad Request", body: Data("Bad Request\n".utf8)); return
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else {
            respond(status: "400 Bad Request", body: Data("Bad Request\n".utf8)); return
        }
        let method = String(requestLine[0]).uppercased()
        var path = String(requestLine[1])
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        guard method == "GET" || method == "HEAD" else {
            respond(status: "405 Method Not Allowed", body: Data("Method Not Allowed\n".utf8), extra: ["Allow: GET"])
            return
        }
        switch path {
        case "/", "/index.html":
            respond(status: "200 OK", body: server.indexHTMLData,
                    contentType: "text/html; charset=utf-8", headOnly: method == "HEAD")
        case "/ws":
            let upgrade = headers["upgrade"]?.lowercased() ?? ""
            let connHeader = headers["connection"]?.lowercased() ?? ""
            guard method == "GET", upgrade.contains("websocket"), connHeader.contains("upgrade"),
                  let key = headers["sec-websocket-key"], !key.isEmpty else {
                respond(status: "400 Bad Request", body: Data("WebSocket-Upgrade erwartet\n".utf8))
                return
            }
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let accept = Data(digest).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            send(Data(response.utf8))
            isWebSocket = true
            server.webSocketOpened(self)
            if !buffer.isEmpty { processFrames() }
        default:
            respond(status: "404 Not Found", body: Data("Not Found\n".utf8))
        }
    }

    private func findHeaderEnd() -> Int? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4) where buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            return i
        }
        return nil
    }

    private func respond(status: String, body: Data, contentType: String = "text/plain; charset=utf-8",
                         headOnly: Bool = false, extra: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
        for e in extra { head += e + "\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if !headOnly { data.append(body) }
        closing = true
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: WebSocket (Client → Server)

    private func processFrames() {
        while !closed && !closing {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[0], b1 = buffer[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var len = UInt64(b1 & 0x7F)
            var offset = 2
            if len == 126 {
                guard buffer.count >= 4 else { return }
                len = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
                offset = 4
            } else if len == 127 {
                guard buffer.count >= 10 else { return }
                len = 0
                for i in 0..<8 { len = len << 8 | UInt64(buffer[2 + i]) }
                offset = 10
            }
            if (b0 & 0x70) != 0 || !masked { close(sendCloseFrame: true, code: 1002); return }   // RSV / unmaskiert
            if len > UInt64(StreamServer.maxClientMessage) { close(sendCloseFrame: true, code: 1009); return }
            let total = offset + 4 + Int(len)
            guard buffer.count >= total else { return }
            let mask = Array(buffer[offset..<(offset + 4)])
            var payload = Array(buffer[(offset + 4)..<total])
            for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            buffer.removeFirst(total)
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x0: // Continuation
            guard fragmentOpcode != 0 else { close(sendCloseFrame: true, code: 1002); return }
            fragmentData.append(contentsOf: payload)
            if fragmentData.count > StreamServer.maxClientMessage { close(sendCloseFrame: true, code: 1009); return }
            if fin {
                let op = fragmentOpcode, data = fragmentData
                fragmentOpcode = 0; fragmentData = []
                deliver(opcode: op, payload: data)
            }
        case 0x1, 0x2:
            guard fragmentOpcode == 0 else { close(sendCloseFrame: true, code: 1002); return }
            if fin { deliver(opcode: opcode, payload: payload) }
            else { fragmentOpcode = opcode; fragmentData = payload }
        case 0x8: // Close
            var code: UInt16 = 1000
            if payload.count >= 2 { code = UInt16(payload[0]) << 8 | UInt16(payload[1]) }
            if code == 1005 || code == 1006 || code == 1015 || code < 1000 { code = 1000 }
            close(sendCloseFrame: true, code: code)
        case 0x9: // Ping → Pong
            guard fin, payload.count <= 125 else { close(sendCloseFrame: true, code: 1002); return }
            send(StreamServer.makeBinaryFrame(prefix: payload, payload: Data(), opcode: 0xA))
        case 0xA: // Pong
            break
        default:
            close(sendCloseFrame: true, code: 1002)
        }
    }

    private func deliver(opcode: UInt8, payload: [UInt8]) {
        guard opcode == 0x1 else { return }   // Binary vom Client wird ignoriert
        guard let text = String(bytes: payload, encoding: .utf8) else {
            close(sendCloseFrame: true, code: 1007); return
        }
        server.handleText(text, from: self)
    }
}
