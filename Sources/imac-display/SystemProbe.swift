import Foundation

/// Read-only system probes for the setup window (no admin rights, no changes).
/// All functions block (they run small command line tools) → call them off the main thread.
enum Shell {
    struct Result { var status: Int32; var output: String }

    /// Runs an executable with arguments (no shell), returns exit status + stdout/stderr (merged).
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        p.environment = env
        do { try p.run() } catch { return Result(status: -1, output: "\(error)") }
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }

    /// Single-quote a string for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A wired (Ethernet) network interface candidate for the direct cable.
struct WiredInterface: Equatable {
    var device: String          // en11
    var portName: String        // "USB 10/100/1000 LAN" (hardware port)
    var serviceName: String?    // network service in System Settings, may differ ("USB 10/100/1000 LAN 2")
    var linkActive: Bool        // ifconfig "status: active"
    var media: String?          // "1000baseT <full-duplex>"
    var ipv4: [String]

    var displayName: String { "\(serviceName ?? portName) (\(device))" }

    /// "1 Gbit/s", "100 Mbit/s" from the media line, if known.
    var speedText: String? {
        guard let m = media?.lowercased() else { return nil }
        if m.contains("10gbase") { return "10 Gbit/s" }
        if m.contains("5gbase") { return "5 Gbit/s" }
        if m.contains("2500base") { return "2,5 Gbit/s" }
        if m.contains("1000base") { return "1 Gbit/s" }
        if m.contains("100base") { return "100 Mbit/s" }
        if m.contains("10base") { return "10 Mbit/s" }
        return nil
    }
}

/// IPv4 settings of one network service as reported by `networksetup -getinfo`.
struct ServiceIPv4Config: Codable, Equatable {
    enum Mode: String, Codable { case dhcp, manual, manualWithDHCPRouter, bootp, off, unknown }
    var service: String
    var mode: Mode
    var ip: String?
    var subnet: String?
    var router: String?
    var raw: String
    /// DHCP client ID (restored with `-setdhcp <service> <id>`).
    var clientID: String? = nil

    static func parse(service: String, output: String) -> ServiceIPv4Config {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let first = lines.first?.lowercased() ?? ""
        var mode: Mode = .unknown
        if first.hasPrefix("dhcp configuration") { mode = .dhcp }
        else if first.hasPrefix("manually using dhcp router") { mode = .manualWithDHCPRouter }
        else if first.hasPrefix("manual configuration") { mode = .manual }
        else if first.hasPrefix("bootp configuration") { mode = .bootp }
        func value(_ key: String) -> String? {
            guard let l = lines.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
            let v = l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return v.isEmpty || v == "none" ? nil : v
        }
        let ip = value("IP address")
        if mode == .unknown && ip == nil && !lines.contains(where: { $0.hasPrefix("IP address:") }) && !output.isEmpty {
            mode = .off
        }
        return ServiceIPv4Config(service: service, mode: mode, ip: ip, subnet: value("Subnet mask"),
                                 router: value("Router"), raw: output,
                                 clientID: mode == .dhcp ? value("Client ID") : nil)
    }

    var isCableConfig: Bool { mode == .manual && ip == NetworkSetup.macIP }
}

/// Snapshot of everything the setup window shows about the system (network, firewall, iMac reachability).
struct ProbeResult {
    var wired: [WiredInterface] = []
    var chosen: WiredInterface?
    var chosenConfig: ServiceIPv4Config?
    /// Service (other than `chosen`) that already carries 10.77.0.1.
    var addressOnOtherService: String?
    var pingOK: Bool?                // nil = not tried (no link / no address)
    var firewallOn: Bool?
    var firewallBlockAll: Bool?
    var defaultRouteInterface: String?
    var probedAt = Date()
}

enum SystemProbe {
    private static var portCache: (date: Date, ports: [(port: String, device: String)], services: [String: String])?
    private static let cacheLock = NSLock()

    static let excludedPortWords = ["wi-fi", "wlan", "airport", "bluetooth", "thunderbolt", "bridge", "iphone", "ipad", "vpn"]
    static let excludedDevicePrefixes = ["bridge", "awdl", "llw", "utun", "lo", "gif", "stf", "ap", "anpi", "ipsec", "ppp", "vlan"]

    /// Hardware ports (port name ↔ device) and network services (device → service name). Cached for 20 s.
    private static func portsAndServices() -> (ports: [(port: String, device: String)], services: [String: String]) {
        cacheLock.lock()
        if let c = portCache, Date().timeIntervalSince(c.date) < 20 { cacheLock.unlock(); return (c.ports, c.services) }
        cacheLock.unlock()

        var ports: [(String, String)] = []
        let hw = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]).output
        var curPort: String?
        for line in hw.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { curPort = String(line.dropFirst("Hardware Port: ".count)) }
            else if line.hasPrefix("Device: "), let p = curPort {
                ports.append((p, String(line.dropFirst("Device: ".count)).trimmingCharacters(in: .whitespaces)))
                curPort = nil
            }
        }
        // "(3) USB 10/100/1000 LAN\n(Hardware Port: USB 10/100/1000 LAN, Device: en11)"
        var services: [String: String] = [:]
        let order = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).output
        var curService: String?
        for raw in order.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("("), !line.hasPrefix("(Hardware Port"), let close = line.firstIndex(of: ")") {
                var name = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("*") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) } // disabled
                curService = name
            } else if line.hasPrefix("(Hardware Port"), let r = line.range(of: "Device: "), let s = curService {
                let dev = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                if !dev.isEmpty && services[dev] == nil { services[dev] = s }
                curService = nil
            }
        }
        cacheLock.lock(); portCache = (Date(), ports, services); cacheLock.unlock()
        return (ports, services)
    }

    /// Parses `ifconfig` output into device → (active, media, ipv4 addresses).
    static func parseIfconfig(_ out: String) -> [String: (active: Bool, media: String?, ipv4: [String])] {
        var result: [String: (Bool, String?, [String])] = [:]
        var cur: String?
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let c = line.first, !c.isWhitespace, let colon = line.firstIndex(of: ":") {
                cur = String(line[..<colon])
                result[cur!] = (false, nil, [])
                continue
            }
            guard let d = cur, var e = result[d] else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("status: ") { e.0 = t.hasSuffix("active") && !t.hasSuffix("inactive") }
            else if t.hasPrefix("media: ") {
                // "media: autoselect (1000baseT <full-duplex>)"
                if let o = t.firstIndex(of: "("), let c = t.lastIndex(of: ")"), o < c {
                    e.1 = String(t[t.index(after: o)..<c])
                } else { e.1 = String(t.dropFirst(7)) }
            } else if t.hasPrefix("inet ") {
                let parts = t.split(separator: " ")
                if parts.count > 1 { e.2.append(String(parts[1])) }
            }
            result[d] = e
        }
        return result.mapValues { (active: $0.0, media: $0.1, ipv4: $0.2) }
    }

    static func isExcluded(port: String, device: String) -> Bool {
        let p = port.lowercased()
        if excludedPortWords.contains(where: { p.contains($0) }) { return true }
        return excludedDevicePrefixes.contains(where: { device.hasPrefix($0) })
    }

    static func wiredInterfaces() -> [WiredInterface] {
        let (ports, services) = portsAndServices()
        let ifc = parseIfconfig(Shell.run("/sbin/ifconfig", []).output)
        var list: [WiredInterface] = []
        for (port, dev) in ports where !isExcluded(port: port, device: dev) {
            guard let i = ifc[dev] else { continue } // not present right now
            // Without a network service and without link it can be neither configured nor used
            // (e.g. the internal "Ethernet Adapter (en4…6)" entries on Apple-silicon Macs).
            if services[dev] == nil && !i.active { continue }
            list.append(WiredInterface(device: dev, portName: port, serviceName: services[dev],
                                       linkActive: i.active, media: i.media, ipv4: i.ipv4))
        }
        return list
    }

    /// Preferred cable interface: the one carrying 10.77.0.1, else one with link, else one with a
    /// network service, else the first one.
    static func choose(_ list: [WiredInterface]) -> WiredInterface? {
        list.first(where: { $0.ipv4.contains(NetworkSetup.macIP) })
            ?? list.first(where: { $0.linkActive && $0.serviceName != nil })
            ?? list.first(where: { $0.linkActive })
            ?? list.first(where: { $0.serviceName != nil })
            ?? list.first
    }

    static func serviceConfig(_ service: String) -> ServiceIPv4Config? {
        let r = Shell.run("/usr/sbin/networksetup", ["-getinfo", service])
        guard r.status == 0 else { return nil }
        return ServiceIPv4Config.parse(service: service, output: r.output)
    }

    /// Ping bound to the cable interface (otherwise 10.77.0.2 could be routed via Wi-Fi to a foreign host).
    static func ping(_ ip: String, via device: String) -> Bool {
        Shell.run("/sbin/ping", ["-c", "1", "-t", "1", "-q", "-b", device, ip], timeout: 3).status == 0
    }

    static func firewall() -> (on: Bool?, blockAll: Bool?) {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        let g = Shell.run(fw, ["--getglobalstate"]).output.lowercased()
        let b = Shell.run(fw, ["--getblockall"]).output.lowercased()
        let on: Bool? = g.contains("enabled") ? true : (g.contains("disabled") ? false : nil)
        // "Firewall has block all state set to disabled." / "... enabled." (older: "Block all DISABLED!")
        let blockAll: Bool? = b.contains("enabled") ? true : (b.contains("disabled") ? false : nil)
        return (on, blockAll)
    }

    /// Whether the application firewall lists `appPath` (an entry is created when the user answers the
    /// system's "accept incoming connections?" prompt). Read-only, no admin rights needed.
    static func firewallListsApp(_ appPath: String) -> Bool {
        let out = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--listapps"]).output
        return out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix(appPath) }
    }

    static func defaultRouteInterface() -> String? {
        let out = Shell.run("/sbin/route", ["-n", "get", "default"]).output
        return out.split(separator: "\n").first(where: { $0.contains("interface:") })
            .map { $0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces) }
    }

    /// Full probe (blocking, ~0–1 s; the ping is the slow part).
    static func probe(doPing: Bool = true) -> ProbeResult {
        var r = ProbeResult()
        r.wired = wiredInterfaces()
        r.chosen = choose(r.wired)
        if let svc = r.chosen?.serviceName { r.chosenConfig = serviceConfig(svc) }
        if r.chosenConfig?.isCableConfig != true {
            // 10.77.0.1 configured on another wired service (e.g. a second adapter)?
            for w in r.wired where w.device != r.chosen?.device {
                if w.ipv4.contains(NetworkSetup.macIP) { r.addressOnOtherService = w.displayName; break }
            }
        }
        if doPing, let c = r.chosen, c.linkActive, c.ipv4.contains(NetworkSetup.macIP) {
            r.pingOK = ping(NetworkSetup.iMacIP, via: c.device)
        }
        let fw = firewall()
        r.firewallOn = fw.on
        r.firewallBlockAll = fw.blockAll
        r.defaultRouteInterface = defaultRouteInterface()
        r.probedAt = Date()
        return r
    }
}
