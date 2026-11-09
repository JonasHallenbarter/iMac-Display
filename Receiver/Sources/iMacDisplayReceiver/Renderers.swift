import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox

/// Zeigt H.264-Samples an. Alle Methoden auf dem Main-Thread.
protocol VideoRenderer: AnyObject {
    var layer: CALayer { get }
    var name: String { get }
    /// true: `onShown` meldet jedes wirklich dekodierte Bild (VT). false: nur „eingereiht“ bekannt (Layer).
    var reportsShownFrames: Bool { get }
    /// Dekodier-/Anzeigefehler (asynchron, Main-Thread)
    var onFailure: ((String) -> Void)? { get set }
    /// Bild ist dekodiert und angezeigt: (pts) – nur bei reportsShownFrames
    var onShown: ((CMTime) -> Void)? { get set }
    var usingHardware: Bool? { get }
    /// false = nicht eingereiht (Renderer muss erst geleert werden / wartet auf Keyframe)
    func enqueue(_ sample: CMSampleBuffer) -> Bool
    /// Alles verwerfen; removeImage: auch das zuletzt gezeigte Bild entfernen (kein „eingefrorenes“ Bild)
    func flush(removeImage: Bool)
    /// Fehlerzustand, der beim nächsten Timer-Tick behandelt werden soll
    func healthProblem() -> String?
    func setExactPixelMapping(_ exact: Bool)
}

/// Standard: AVSampleBufferDisplayLayer (Hardware-Dekodierung über VideoToolbox, Darstellung direkt durch
/// den Compositor in YUV – keine Umwandlung, keine Kopie).
final class LayerRenderer: VideoRenderer {
    let display = AVSampleBufferDisplayLayer()
    var layer: CALayer { display }
    let name = "AVSampleBufferDisplayLayer"
    let reportsShownFrames = false
    var onFailure: ((String) -> Void)?
    var onShown: ((CMTime) -> Void)?
    var usingHardware: Bool? { nil }
    private var observer: NSObjectProtocol?

    init() {
        display.videoGravity = .resizeAspect
        display.backgroundColor = CGColor(gray: 0, alpha: 1)
        display.isOpaque = true
        display.preventsDisplaySleepDuringVideoPlayback = false   // das regelt PowerController
        observer = NotificationCenter.default.addObserver(forName: .AVSampleBufferDisplayLayerFailedToDecode,
                                                          object: display, queue: .main) { [weak self] n in
            let e = n.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError
            self?.onFailure?("Dekodierfehler: " + (e.map { "\($0.localizedDescription) (\($0.code))" } ?? "unbekannt"))
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if display.status == .failed || display.requiresFlushToResumeDecoding { return false }
        display.enqueue(sample)
        return true
    }

    func flush(removeImage: Bool) {
        if removeImage { display.flushAndRemoveImage() } else { display.flush() }
    }

    func healthProblem() -> String? {
        if display.status == .failed {
            let e = display.error as NSError?
            return "Anzeige-Fehler: " + (e.map { "\($0.localizedDescription) (\($0.code))" } ?? "unbekannt")
        }
        if display.requiresFlushToResumeDecoding { return "Decoder muss neu starten (z. B. nach Ruhezustand)" }
        return nil
    }

    func setExactPixelMapping(_ exact: Bool) {
        // Kein Filter einstellbar; bei Layer-Größe in Pixeln == Videogröße bildet der Compositor 1:1 ab.
    }
}

/// Ersatz (defaults write de.local.imac-display-receiver renderer vt): VTDecompressionSession → NV12-IOSurface
/// als CALayer.contents. Meldet jedes angezeigte Bild (genaue Bildrate/Latenz auch auf macOS 12).
final class VTRenderer: VideoRenderer {
    let content = CALayer()
    var layer: CALayer { content }
    let name = "VTDecompressionSession"
    let reportsShownFrames = true
    var onFailure: ((String) -> Void)?
    var onShown: ((CMTime) -> Void)?
    var usingHardware: Bool? { decoder.usingHardware }
    private let decoder = VTDecoder(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    private var generation = 0
    private var recent: [CVPixelBuffer] = []      // gezeigte Puffer kurz festhalten (nicht zu früh wiederverwenden)
    private var failed: String?

    init() {
        content.backgroundColor = CGColor(gray: 0, alpha: 1)
        content.isOpaque = true
        content.contentsGravity = .resizeAspect
        decoder.onOutput = { [weak self] st, pb, pts in
            guard let self else { return }
            let g = self.currentGeneration
            DispatchQueue.main.async { if g == self.currentGeneration { self.output(st, pb, pts) } }
        }
    }

    private let genLock = NSLock()
    private var currentGeneration: Int { genLock.lock(); defer { genLock.unlock() }; return generation }

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if failed != nil { return false }
        let st = decoder.decode(sample)
        if st != noErr { failed = "Dekodierfehler \(st)"; return false }
        return true
    }

    private func output(_ st: OSStatus, _ pb: CVPixelBuffer?, _ pts: CMTime) {
        if st != noErr {
            if failed == nil { failed = "Dekodierfehler \(st)"; onFailure?(failed!) }
            return
        }
        guard failed == nil, let pb, let surf = CVPixelBufferGetIOSurface(pb) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = surf.takeUnretainedValue()
        CATransaction.commit()
        recent.append(pb)
        if recent.count > 3 { recent.removeFirst() }
        onShown?(pts)
    }

    func flush(removeImage: Bool) {
        decoder.invalidate()              // wartet auf laufende Bilder …
        genLock.lock(); generation += 1; genLock.unlock()   // … deren Ausgaben dann verworfen werden
        failed = nil
        if removeImage {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            content.contents = nil
            CATransaction.commit()
            recent.removeAll()
        }
    }

    func healthProblem() -> String? { failed }

    func setExactPixelMapping(_ exact: Bool) {
        content.magnificationFilter = exact ? .nearest : .linear
        content.minificationFilter = exact ? .nearest : .linear
    }
}
