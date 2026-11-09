import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum ScreenCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)

    var description: String {
        switch self {
        case .permissionDenied: return "Keine Berechtigung für Bildschirmaufnahme"
        case .displayNotFound(let id): return "Display \(id) taucht nicht in SCShareableContent auf"
        }
    }
}

/// Captures one display via ScreenCaptureKit as NV12 at full pixel resolution and hands complete
/// frames to a callback on `queue`.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let fps: Int
    let queue: DispatchQueue
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    var onStopWithError: ((Error) -> Void)?

    private var stream: SCStream?
    private(set) var capturedFrames = 0 // queue-owned

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, queue: DispatchQueue,
         onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.queue = queue
        self.onFrame = onFrame
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { return true }
        return false
    }

    func start() async throws {
        let preflight = CGPreflightScreenCaptureAccess()
        func denied() -> ScreenCaptureError {
            // Triggers the system prompt / adds the host app to the privacy list (once).
            if !preflight { _ = CGRequestScreenCaptureAccess() }
            return .permissionDenied
        }

        // The virtual display may take a moment to show up in ScreenCaptureKit.
        var scDisplay: SCDisplay?
        let deadline = Date().addingTimeInterval(10)
        while scDisplay == nil {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                scDisplay = content.displays.first(where: { $0.displayID == displayID })
            } catch {
                if Self.isPermissionError(error) || !preflight { throw denied() }
                logLine("SCShareableContent-Fehler: \(error.localizedDescription) – neuer Versuch")
            }
            if scDisplay == nil {
                if Date() > deadline { throw ScreenCaptureError.displayNotFound(displayID) }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        let filter = SCContentFilter(display: scDisplay!, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = true
        cfg.queueDepth = 5
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.scalesToFit = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do {
            try await s.startCapture()
        } catch {
            if Self.isPermissionError(error) { throw denied() }
            throw error
        }
        stream = s
        logLine("Bildschirmaufnahme läuft: Display \(displayID), \(width)x\(height) px, NV12, max \(fps) fps")
    }

    var isRunning: Bool { stream != nil }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        let sem = DispatchSemaphore(value: 0)
        s.stopCapture { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw),
              status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        capturedFrames += 1
        onFrame(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logLine("Bildschirmaufnahme gestoppt: \(error.localizedDescription)")
        onStopWithError?(error)
    }
}
