import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox
import IOSurface

// Nur für Tests/Entwicklung – im normalen Betrieb inaktiv.
//   IMAC_RECEIVER_TEST_STATS=<datei>  Player-Zustand jede Sekunde als JSON schreiben
//   IMAC_RECEIVER_TEST_VERIFY=1       (macOS 14.4+, Layer-Renderer) angezeigtes Bild mit einer zweiten, unabhängigen
//                                     VideoToolbox-Dekodierung vergleichen: Latenz Empfang → angezeigt, Bit-Gleichheit,
//                                     kein Bild mehr nach dem Leeren. Braucht das Testbild des MacBooks (--test-pattern).

protocol StoppableHook: AnyObject { func stopHook() }
protocol FrameObservingHook: AnyObject { func enqueued(_ sample: CMSampleBuffer, receivedAt: Double) }
protocol TickingHook: AnyObject {
    func tick(_ p: PlayerController)
    func second(_ p: PlayerController)
    func addSnapshot(_ d: inout [String: Any])
}

func installVerifierIfRequested(_ p: PlayerController) {
    let path = Config.env["IMAC_RECEIVER_TEST_STATS"]
    let verify = Config.env["IMAC_RECEIVER_TEST_VERIFY"] == "1"
    guard path != nil || verify else { return }
    p.verifier = TestMonitor(player: p, statsPath: path, verify: verify)
}

final class TestMonitor: TickingHook, FrameObservingHook, StoppableHook {
    let statsPath: String?
    private var verifier: AnyObject?
    private var idleSince: Double?
    private var idleTicksWithImage = 0
    private var idleTicks = 0

    init(player: PlayerController, statsPath: String?, verify: Bool) {
        self.statsPath = statsPath
        if verify {
            if #available(macOS 14.4, *), let lr = player.renderer as? LayerRenderer {
                verifier = DisplayVerifier(layer: lr.display)
            } else {
                Log.write("Testprüfung nicht möglich (braucht macOS 14.4+ und den Layer-Renderer)")
            }
        }
    }

    func enqueued(_ sample: CMSampleBuffer, receivedAt: Double) {
        if #available(macOS 14.4, *) { (verifier as? DisplayVerifier)?.enqueued(sample, receivedAt: receivedAt) }
    }

    func tick(_ p: PlayerController) {
        second(p)                            // Zustand 4× pro Sekunde (für Zeitmessungen der Übergänge)
        guard #available(macOS 14.4, *), let v = verifier as? DisplayVerifier else { return }
        if p.showingVideo { idleSince = nil; return }
        let now = CACurrentMediaTime()
        if idleSince == nil { idleSince = now }
        if now - idleSince! > 0.5 {          // nach dem Umschalten auf das Ruhebild darf kein Videobild mehr da sein
            idleTicks += 1
            if v.displayedNonNil { idleTicksWithImage += 1 }
        }
    }

    func second(_ p: PlayerController) {
        guard let statsPath else { return }
        var d = p.testSnapshot
        d["t"] = CACurrentMediaTime()
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: statsPath), options: .atomic)
        }
    }

    func addSnapshot(_ d: inout [String: Any]) {
        d["idleTicks"] = idleTicks
        d["idleTicksWithImage"] = idleTicksWithImage
        if #available(macOS 14.4, *), let v = verifier as? DisplayVerifier { v.addSnapshot(&d) }
    }

    func stopHook() {
        if #available(macOS 14.4, *) { (verifier as? DisplayVerifier)?.stop() }
    }
}

@available(macOS 14.4, *)
final class DisplayVerifier {
    private struct Rec { var pts: Int64; var recv: Double; var sig: Double?; var pb: CVPixelBuffer? }
    private let renderer: AVSampleBufferVideoRenderer
    private let decoder = VTDecoder(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    private let lock = NSLock()
    private var recs: [Rec] = []
    private var lastShownID: UInt32 = 0           // IOSurface-ID des zuletzt gesehenen Bildes
    private var pending: (pb: CVPixelBuffer, t: Double, sig: Double)?
    private var running = true
    private var transfer: VTPixelTransferSession?
    private var transferOut: [CVPixelBuffer?] = [nil, nil]
    private var transferIndex = 0
    private var latency = LatencyStats()
    private var changes = 0, matched = 0, unmatched = 0, compared = 0, identical = 0, differing = 0
    private var maxDiff = 0, diffBytes = 0
    private var diffLog: [String] = []
    private var shownFormat = "", shownSize = ""
    private(set) var displayedNonNil = false

    init(layer: AVSampleBufferDisplayLayer) {
        renderer = layer.sampleBufferRenderer
        decoder.onOutput = { [weak self] st, pb, pts in
            guard let self, st == noErr, let pb else { return }
            let s = self.signature(pb)
            self.lock.lock()
            if let i = self.recs.lastIndex(where: { $0.pts == pts.value }) { self.recs[i].sig = s; self.recs[i].pb = pb }
            self.lock.unlock()
        }
        let t = Thread { [weak self] in self?.poll() }
        t.qualityOfService = .userInteractive
        t.start()
        Log.write("Testprüfung aktiv (copyDisplayedPixelBuffer + zweite VT-Dekodierung)")
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    func enqueued(_ sample: CMSampleBuffer, receivedAt: Double) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).value
        lock.lock()
        recs.append(Rec(pts: pts, recv: receivedAt, sig: nil, pb: nil))
        if recs.count > 16 { recs.removeFirst(recs.count - 16) }
        lock.unlock()
        decoder.decode(sample)
    }

    private func poll() {
        while true {
            lock.lock(); let go = running; lock.unlock()
            if !go { break }
            autoreleasepool {
                let pb = renderer.displayedPixelBuffer()
                let t = CACurrentMediaTime()
                lock.lock()
                displayedNonNil = pb != nil
                // dieselbe Anzeige kann als neues CVPixelBuffer-Objekt kommen → über die IOSurface erkennen
                let sid = pb.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }.map { IOSurfaceGetID($0) } ?? 0
                let isNew = pb != nil && sid != lastShownID
                lastShownID = sid
                lock.unlock()
                if isNew, let pb {
                    let readable = cpuReadable(pb)
                    let s = signature(readable)
                    lock.lock()
                    changes += 1
                    shownFormat = fourCC(CVPixelBufferGetPixelFormatType(pb))
                    shownSize = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
                    if pending != nil { unmatched += 1 }
                    pending = (readable, t, s)
                    lock.unlock()
                }
                tryMatch(now: t)
            }
            usleep(1000)
        }
        decoder.invalidate()
    }

    private func tryMatch(now: Double) {
        lock.lock()
        guard let p = pending else { lock.unlock(); return }
        // jüngstes Bild mit passender Signatur, das vor der Anzeige empfangen wurde (Signatur wiederholt sich alle 8 Bilder)
        if let i = recs.lastIndex(where: { $0.sig != nil && abs($0.sig! - p.sig) < 3 && $0.recv <= p.t && p.t - $0.recv < 0.12 }) {
            let r = recs[i]
            pending = nil
            matched += 1
            latency.add((p.t - r.recv) * 1000)
            let doCompare = matched % 15 == 1
            lock.unlock()
            if doCompare, let ref = r.pb { compare(p.pb, ref) }
            return
        }
        if now - p.t > 0.1 { pending = nil; unmatched += 1 }
        lock.unlock()
    }

    /// Kompressionsformate (Apple Silicon) für den CPU-Vergleich in 420v umwandeln
    private func cpuReadable(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        let f = CVPixelBufferGetPixelFormatType(pb)
        if f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { return pb }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        transferIndex ^= 1                    // zwei feste Zielpuffer abwechselnd (kein Neuanlegen pro Bild)
        if transferOut[transferIndex].map({ CVPixelBufferGetWidth($0) != w || CVPixelBufferGetHeight($0) != h }) ?? true {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
            transferOut[transferIndex] = out
        }
        guard let t = transfer, let out = transferOut[transferIndex], VTPixelTransferSessionTransferImage(t, from: pb, to: out) == noErr else { return pb }
        return out
    }

    /// Median der Helligkeit in Zeile 2 (Testbild: Streifenwert wechselt mit jedem Bild)
    private func signature(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return -100 }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let row = base.assumingMemoryBound(to: UInt8.self) + 2 * stride
        var v: [UInt8] = []
        for k in 0..<64 { v.append(row[(k * w) / 64 + 7]) }
        v.sort()
        return Double(v[32])
    }

    private func compare(_ a: CVPixelBuffer, _ b: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b),
              CVPixelBufferGetPlaneCount(a) == CVPixelBufferGetPlaneCount(b) else {
            lock.lock(); compared += 1; differing += 1; lock.unlock(); return
        }
        var diff = 0, mx = 0
        for plane in 0..<CVPixelBufferGetPlaneCount(a) {
            guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane), let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane) else { continue }
            let h = CVPixelBufferGetHeightOfPlane(a, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(a, plane) * (plane == 0 ? 1 : 2)
            let sa = CVPixelBufferGetBytesPerRowOfPlane(a, plane), sb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            for y in 0..<h {
                let ra = pa + y * sa, rb = pb + y * sb
                if memcmp(ra, rb, rowBytes) == 0 { continue }
                let ua = ra.assumingMemoryBound(to: UInt8.self), ub = rb.assumingMemoryBound(to: UInt8.self)
                for x in 0..<rowBytes where ua[x] != ub[x] {
                    diff += 1; mx = max(mx, abs(Int(ua[x]) - Int(ub[x])))
                }
            }
        }
        lock.lock()
        compared += 1
        if diff == 0 { identical += 1 } else {
            differing += 1; diffBytes += diff; maxDiff = max(maxDiff, mx)
            diffLog.append("Vergleich \(compared) (Bild \(matched)): \(diff) Bytes, max \(mx)")
        }
        lock.unlock()
    }

    func addSnapshot(_ d: inout [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        d["vChanges"] = changes; d["vMatched"] = matched; d["vUnmatched"] = unmatched
        d["vCompared"] = compared; d["vIdentical"] = identical; d["vDiffering"] = differing
        d["vMaxDiff"] = maxDiff; d["vDiffBytes"] = diffBytes; d["vDiffLog"] = diffLog
        d["vLatMean"] = latency.mean; d["vLatP50"] = latency.p50; d["vLatP95"] = latency.p95; d["vLatMax"] = latency.max
        d["vLatCount"] = latency.count; d["vShownFormat"] = shownFormat; d["vShownSize"] = shownSize
        d["vDisplayedNonNil"] = displayedNonNil
    }
}

func fourCC(_ f: OSType) -> String {
    let c = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((f >> UInt32($0)) & 0xff))) }
    return String(c)
}
