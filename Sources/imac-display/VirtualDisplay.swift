import Foundation
import CoreGraphics
import CGVirtualDisplayPrivate

enum VirtualDisplayError: Error, CustomStringConvertible {
    case createFailed
    case applySettingsFailed

    var description: String {
        switch self {
        case .createFailed: return "CGVirtualDisplay konnte nicht erstellt werden"
        case .applySettingsFailed: return "CGVirtualDisplay.applySettings ist fehlgeschlagen"
        }
    }
}

/// Wraps a private CGVirtualDisplay. Keep the instance alive as long as the display should exist;
/// releasing it (or calling `destroy()`) removes the display from the system.
final class VirtualDisplay {
    private var display: CGVirtualDisplay?
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
    let hiDPI: Bool

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: backing pixel size (e.g. 4096x2304).
    ///   - hiDPI: true → logical size is half the pixel size (2048x1152 points, Retina).
    ///
    /// Empirically verified (macOS 26.5, M4 Pro): with `hiDPI = 1`, the CGVirtualDisplayMode
    /// width/height are interpreted as POINTS; the system backs them with 2x pixels, which must fit
    /// into maxPixelsWide/High. So for 4096x2304 px HiDPI we pass a 2048x1152 mode.
    init(name: String, pixelWidth: Int, pixelHeight: Int, fps: Double, hiDPI: Bool) throws {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hiDPI = hiDPI

        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.global(qos: .userInteractive)
        desc.name = name
        desc.maxPixelsWide = UInt32(pixelWidth)
        desc.maxPixelsHigh = UInt32(pixelHeight)
        // 21.5" diagonal at the given aspect ratio (16:9 → ~476 x 268 mm).
        let diagMM = 21.5 * 25.4
        let aspect = Double(pixelWidth) / Double(pixelHeight)
        let hMM = diagMM / (aspect * aspect + 1).squareRoot()
        desc.sizeInMillimeters = CGSize(width: (hMM * aspect).rounded(), height: hMM.rounded())
        desc.vendorID = 0x1E6D      // arbitrary, non-Apple
        desc.productID = 0x4B21     // "iMac 4K 21.5"
        desc.serialNum = 0x0A770001 // stable → macOS remembers arrangement between runs
        desc.terminationHandler = { _, _ in
            FileHandle.standardError.write("Virtuelles Display wurde vom System beendet.\n".data(using: .utf8)!)
        }

        guard let d = CGVirtualDisplay(descriptor: desc) else { throw VirtualDisplayError.createFailed }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        let modeW = hiDPI ? pixelWidth / 2 : pixelWidth
        let modeH = hiDPI ? pixelHeight / 2 : pixelHeight
        settings.modes = [CGVirtualDisplayMode(width: UInt32(modeW), height: UInt32(modeH), refreshRate: fps)]
        guard d.apply(settings) else { throw VirtualDisplayError.applySettingsFailed }

        self.display = d
        self.displayID = d.displayID
        self.pointWidth = modeW
        self.pointHeight = modeH
        // The first virtual display of a process can take a few seconds to come online (the
        // NSApplication run loop has to process the reconfiguration) – callers retry via
        // `ensureMode(timeout: 0)` while `hasWantedMode` is false.
        ensureMode(quiet: true)
    }

    var hasWantedMode: Bool {
        guard let cur = CGDisplayCopyDisplayMode(displayID) else { return false }
        return cur.width == pointWidth && cur.pixelWidth == pixelWidth
            && cur.height == pointHeight && cur.pixelHeight == pixelHeight
    }

    let pointWidth: Int
    let pointHeight: Int

    /// macOS picks its own default mode for a new display (e.g. 1920x1080 for a 21.5" panel without
    /// HiDPI, and it remembers per serial number what was used last). Force the wanted mode.
    @discardableResult
    func ensureMode(timeout: TimeInterval = 3, quiet: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Self.onlineDisplays().contains(displayID) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if hasWantedMode { return true }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let want = modes.first(where: {
                  $0.width == pointWidth && $0.height == pointHeight
                      && $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight
              }) else {
            if quiet { return false }
            FileHandle.standardError.write("Warnung: Modus \(pointWidth)x\(pointHeight) pt / \(pixelWidth)x\(pixelHeight) px nicht gefunden.\n".data(using: .utf8)!)
            return false
        }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, want, nil)
        let err = CGCompleteDisplayConfiguration(cfg, .forSession)
        if err != .success {
            FileHandle.standardError.write("Warnung: Displaymodus setzen fehlgeschlagen (\(err.rawValue)).\n".data(using: .utf8)!)
            return false
        }
        return true
    }

    /// Removes the display from the system (releases the CGVirtualDisplay) and waits – spinning the
    /// current run loop – until CoreGraphics no longer lists it as online (bounded by `waitTimeout`).
    /// Idempotent.
    @discardableResult
    func destroy(waitTimeout: TimeInterval = 2) -> Bool {
        guard display != nil else { return true }
        display = nil
        let deadline = Date().addingTimeInterval(waitTimeout)
        while Self.onlineDisplays().contains(displayID) {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    var isAlive: Bool { display != nil }

    /// Human-readable description of the current mode as reported by CoreGraphics.
    func currentModeDescription() -> String {
        Self.describe(displayID)
    }

    static func describe(_ id: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(id) else {
            return "Display \(id): kein Modus (noch nicht online?)"
        }
        return "Display \(id): \(mode.width)x\(mode.height) Punkte, \(mode.pixelWidth)x\(mode.pixelHeight) Pixel, "
            + "\(mode.refreshRate) Hz, CGDisplayPixelsWide=\(CGDisplayPixelsWide(id)), bounds=\(CGDisplayBounds(id))"
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
