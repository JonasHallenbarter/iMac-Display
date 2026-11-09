import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics

// MARK: - Helligkeit des eingebauten Bildschirms

/// Helligkeit des EINGEBAUTEN Bildschirms lesen/setzen (iMac-Panel; ohne eingebautes Panel: Hauptbildschirm).
///
/// Methoden in dieser Reihenfolge – die erste, die tatsächlich funktioniert, wird gemerkt:
///   1. „DisplayServices“ – privates Framework, per dlopen/dlsym geladen (kein Linken, keine Rechte nötig).
///      Gleicher Weg wie die Helligkeitstasten/Systemeinstellungen; Intel und Apple Silicon, macOS 10.12 … 26.
///   2. „IOKit“ – IODisplayGet/SetFloatParameter(kIODisplayBrightnessKey) auf dem IODisplayConnect-Dienst.
///      Klassischer Intel-Weg; auf Apple Silicon gibt es keine IODisplayConnect-Dienste (→ nicht verfügbar).
///
/// „Funktioniert“ heißt: get liefert einen Wert (und DisplayServicesCanChangeBrightness ≠ false). Das Setzen
/// wird beim ersten set() geprüft (Rücklesen); weicht der Wert deutlich ab, wird der alte Wert zurückgeschrieben
/// und die nächste Methode genommen. Beim Start wird NICHTS geschrieben.
///
/// Wertebereich 0…1 (= Position des Helligkeitsreglers in den Systemeinstellungen). Werte außerhalb werden
/// auf `minimumLevel…1` begrenzt, NaN wird abgelehnt. 0 = unterste Reglerstellung: beim iMac bleibt das Panel
/// dann noch schwach beleuchtet; bei MacBooks schaltet 0 die Hintergrundbeleuchtung praktisch ab.
///
/// Thread-sicher (ein Lock, alle Aufrufe serialisiert); get() kostet ~0,1 ms und schreibt nie.
/// Hinweise: Ist „Helligkeit automatisch anpassen“ an, kann der Umgebungslichtsensor den Wert danach wieder
/// verschieben. Das System-HUD (Helligkeits-Einblendung) erscheint bei programmatischen Änderungen nicht;
/// der Regler in den Systemeinstellungen folgt (DisplayServicesBrightnessChanged, sofern vorhanden).
enum Brightness {
    /// Untergrenze für set(). 0 ist erlaubt (Panel bleibt am iMac schwach sichtbar).
    static let minimumLevel: Float = 0.0

    /// Helligkeit des eingebauten Bildschirms lesbar + setzbar
    static var isSupported: Bool { BrightnessEngine.shared.isSupported }

    /// Aktuelle Helligkeit 0…1, nil wenn nicht lesbar
    static func get() -> Float? { BrightnessEngine.shared.get() }

    /// Helligkeit setzen (wird auf minimumLevel…1 begrenzt). true = gesetzt und (soweit prüfbar) übernommen.
    @discardableResult
    static func set(_ value: Float) -> Bool { BrightnessEngine.shared.set(value) }

    /// „DisplayServices“, „IOKit“ oder „nicht verfügbar“
    static var methodDescription: String { BrightnessEngine.shared.methodDescription }

    /// Wert auf den erlaubten Bereich begrenzen; nil bei NaN
    static func clamp(_ value: Float) -> Float? {
        guard !value.isNaN else { return nil }
        return min(max(value, minimumLevel), 1)
    }

    /// Ziel-Bildschirm: eingebauter Bildschirm unter den Online-Bildschirmen, sonst Hauptbildschirm
    static func targetDisplay() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return CGMainDisplayID()
    }
}

// MARK: - Methoden (intern; auch vom Test-Harness einzeln aufrufbar)

protocol BrightnessBackend: AnyObject {
    var name: String { get }
    /// Symbole/Framework vorhanden
    var isAvailable: Bool { get }
    /// nil = unbekannt (Methode kann es nicht sagen)
    func canChange(_ display: CGDirectDisplayID) -> Bool?
    func get(_ display: CGDirectDisplayID) -> Float?
    func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool
}

/// Gelesenen Wert prüfen und auf 0…1 begrenzen
private func sanitize(_ v: Float) -> Float? {
    guard v.isFinite, v >= -0.01, v <= 1.01 else { return nil }
    return min(max(v, 0), 1)
}

/// Privates DisplayServices-Framework (per dlopen – kein Linken nötig)
final class DisplayServicesBrightnessBackend: BrightnessBackend {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private let getFn: GetFn?
    private let setFn: SetFn?
    private let canFn: CanFn?          // optional
    private let changedFn: ChangedFn?  // optional (fehlt z. B. ab macOS 26)

    let name = "DisplayServices"

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                            RTLD_LAZY | RTLD_LOCAL)   // wird nie geschlossen
        func sym<T>(_ n: String, _: T.Type) -> T? {
            guard let h = handle, let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        getFn = sym("DisplayServicesGetBrightness", GetFn.self)
        setFn = sym("DisplayServicesSetBrightness", SetFn.self)
        canFn = sym("DisplayServicesCanChangeBrightness", CanFn.self)
        changedFn = sym("DisplayServicesBrightnessChanged", ChangedFn.self)
    }

    var isAvailable: Bool { getFn != nil && setFn != nil }

    func canChange(_ display: CGDirectDisplayID) -> Bool? { canFn.map { $0(display) } }

    func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var v: Float = -1
        guard getFn(display, &v) == 0 else { return nil }
        return sanitize(v)
    }

    func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setFn, setFn(display, value) == 0 else { return false }
        changedFn?(display, Double(value))   // Systemeinstellungen/Regler benachrichtigen
        return true
    }
}

/// IOKit: IODisplayConnect + kIODisplayBrightnessKey (klassischer Intel-Weg)
final class IOKitBrightnessBackend: BrightnessBackend {
    let name = "IOKit"
    var isAvailable: Bool { true }   // gehört zum öffentlichen IOKit; ob ein Dienst existiert, zeigt get()

    private var service: io_service_t = 0
    private var serviceDisplay: CGDirectDisplayID = 0
    private let key = kIODisplayBrightnessKey as CFString

    deinit { if service != 0 { IOObjectRelease(service) } }

    func canChange(_ display: CGDirectDisplayID) -> Bool? { nil }

    func get(_ display: CGDirectDisplayID) -> Float? {
        guard let s = service(for: display) else { return nil }
        var v: Float = -1
        guard IODisplayGetFloatParameter(s, 0, key, &v) == kIOReturnSuccess else { dropService(); return nil }
        return sanitize(v)
    }

    func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let s = service(for: display) else { return false }
        guard IODisplaySetFloatParameter(s, 0, key, value) == kIOReturnSuccess else { dropService(); return false }
        return true
    }

    private func dropService() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
        serviceDisplay = 0
    }

    /// Passenden IODisplayConnect-Dienst finden (Hersteller/Modell wie der CG-Bildschirm; sonst der erste
    /// mit lesbarer Helligkeit) und merken.
    private func service(for display: CGDirectDisplayID) -> io_service_t? {
        if service != 0 && serviceDisplay == display { return service }
        dropService()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
                == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        let vendor = CGDisplayVendorNumber(display), model = CGDisplayModelNumber(display)
        var fallback: io_service_t = 0
        var match: io_service_t = 0
        while case let s = IOIteratorNext(iterator), s != 0 {
            var v: Float = 0
            guard match == 0, IODisplayGetFloatParameter(s, 0, key, &v) == kIOReturnSuccess else {
                IOObjectRelease(s); continue
            }
            if Self.matches(s, vendor: vendor, model: model) {
                match = s
            } else if fallback == 0 {
                fallback = s
            } else {
                IOObjectRelease(s)
            }
        }
        let chosen: io_service_t
        if match != 0 {
            chosen = match
            if fallback != 0 { IOObjectRelease(fallback) }
        } else {
            chosen = fallback
        }
        guard chosen != 0 else { return nil }
        service = chosen
        serviceDisplay = display
        return chosen
    }

    private static func matches(_ s: io_service_t, vendor: UInt32, model: UInt32) -> Bool {
        guard let info = IODisplayCreateInfoDictionary(s, IOOptionBits(kIODisplayOnlyPreferredName))?
                .takeRetainedValue() as? [String: Any] else { return false }
        let v = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
        let p = (info[kDisplayProductID] as? NSNumber)?.uint32Value
        return v == vendor && p == model
    }
}

// MARK: - Auswahl + Zustand (Lock)

final class BrightnessEngine: @unchecked Sendable {
    static let shared = BrightnessEngine(backends: [DisplayServicesBrightnessBackend(), IOKitBrightnessBackend()])

    private let lock = NSLock()
    private let backends: [BrightnessBackend]
    private var chosen: Int?              // gemerkte Methode
    private var setBroken = Set<Int>()    // Setzen ohne Wirkung → nicht mehr verwenden
    private var lastFailure: UInt64 = 0   // nichts gefunden (Uptime ns) – kurz nicht erneut suchen
    private let retryAfterNs: UInt64 = 5_000_000_000

    init(backends: [BrightnessBackend]) { self.backends = backends }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isSupported: Bool { locked { resolve(Brightness.targetDisplay()) != nil } }

    var methodDescription: String {
        locked { resolve(Brightness.targetDisplay()).map { backends[$0].name } ?? "nicht verfügbar" }
    }

    func get() -> Float? {
        locked {
            let display = Brightness.targetDisplay()
            guard let i = resolve(display) else { return nil }
            if let v = backends[i].get(display) { return v }
            chosen = nil                                   // gewählte Methode liefert nichts mehr → neu suchen
            guard let j = resolve(display) else { return nil }
            return backends[j].get(display)
        }
    }

    func set(_ value: Float) -> Bool {
        guard let target = Brightness.clamp(value) else { return false }
        return locked {
            let display = Brightness.targetDisplay()
            guard let first = resolve(display) else { return false }
            let order = [first] + backends.indices.filter { $0 != first && !setBroken.contains($0) }
            for i in order {
                let b = backends[i]
                guard b.isAvailable, b.canChange(display) != false, let before = b.get(display) else { continue }
                guard b.set(display, target) else { continue }
                guard let after = b.get(display) else { chosen = i; return true }
                if Self.accepted(before: before, after: after, target: target) { chosen = i; return true }
                // Setzen ohne Wirkung: alten Wert zurück, Methode nicht mehr verwenden
                _ = b.set(display, before)
                setBroken.insert(i)
                if chosen == i { chosen = nil }
            }
            return false
        }
    }

    /// Rücklesen nach dem Setzen. Großzügig wegen Stufen/Grenzen der Hardware: übernommen, wenn nahe am Ziel
    /// oder deutlich in Richtung Ziel bewegt, oder wenn das Ziel am Rand liegt (Hardware-Minimum/-Maximum).
    private static func accepted(before: Float, after: Float, target: Float) -> Bool {
        if abs(after - target) <= 0.03 { return true }
        if abs(after - target) < abs(before - target) - 0.005 { return true }
        return target < 0.1 || target > 0.9
    }

    /// Erste funktionierende Methode (get liefert Wert, CanChange ≠ false); Ergebnis wird gemerkt.
    /// Nur innerhalb des Locks aufrufen.
    private func resolve(_ display: CGDirectDisplayID) -> Int? {
        if let c = chosen { return c }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastFailure != 0 && now &- lastFailure < retryAfterNs { return nil }
        for (i, b) in backends.enumerated() where b.isAvailable && !setBroken.contains(i) {
            if b.canChange(display) == false { continue }
            if b.get(display) != nil {
                chosen = i
                lastFailure = 0
                return i
            }
        }
        lastFailure = max(now, 1)
        return nil
    }
}
