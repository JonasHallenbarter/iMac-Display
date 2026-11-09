import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// H.264 vom MacBook: Annex B (Startcodes) → AVCC (4-Byte-Längen) + CMVideoFormatDescription aus SPS/PPS
// → CMSampleBuffer. Siehe docs/PROTOCOL.md.

enum H264Error: Error, CustomStringConvertible {
    case empty
    case noFormat
    case format(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)

    var description: String {
        switch self {
        case .empty: return "keine Bilddaten in der Nachricht"
        case .noFormat: return "noch keine SPS/PPS empfangen"
        case .format(let s): return "SPS/PPS ungültig (\(s))"
        case .blockBuffer(let s): return "CMBlockBuffer (\(s))"
        case .sampleBuffer(let s): return "CMSampleBuffer (\(s))"
        }
    }
}

enum H264 {
    /// Bereiche der NAL-Einheiten (ohne Startcode, ohne angehängte Null-Bytes) in einem Annex-B-Puffer.
    static func nalRanges(_ buf: UnsafeRawBufferPointer) -> [Range<Int>] {
        let n = buf.count
        guard n >= 4, let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var codeAt: [Int] = []      // Position des Startcodes (erstes 00 des 00 00 01)
        var i = 0
        while i + 2 < n {
            let b2 = p[i + 2]
            if b2 > 1 { i += 3; continue }
            if b2 == 1 && p[i + 1] == 0 && p[i] == 0 { codeAt.append(i); i += 3 } else { i += 1 }
        }
        var res: [Range<Int>] = []
        res.reserveCapacity(codeAt.count)
        for (k, c) in codeAt.enumerated() {
            let s = c + 3
            var e = k + 1 < codeAt.count ? codeAt[k + 1] : n
            while e > s && p[e - 1] == 0 { e -= 1 }       // 4-Byte-Startcode / trailing_zero_8bits
            if e > s { res.append(s..<e) }
        }
        return res
    }

    static func makeFormat(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var fmt: CMFormatDescription?
        let st: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs: [UnsafePointer<UInt8>] = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard st == noErr, let fmt else { throw H264Error.format(st) }
        return fmt
    }

    /// CMSampleBuffer aus fertigen AVCC-Daten (für die Probedekodierung).
    static func makeSample(avcc: Data, format: CMVideoFormatDescription, pts: CMTime, sync: Bool) throws -> CMSampleBuffer {
        let bb = try makeBlockBuffer(length: avcc.count) { dst in
            avcc.withUnsafeBytes { src in dst.copyMemory(from: src.baseAddress!, byteCount: avcc.count) }
        }
        return try sample(bb, length: avcc.count, format: format, pts: pts, sync: sync)
    }

    static func makeBlockBuffer(length: Int, fill: (UnsafeMutableRawPointer) -> Void) throws -> CMBlockBuffer {
        var bb: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                    dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        guard st == noErr, let bb else { throw H264Error.blockBuffer(st) }
        var ptr: UnsafeMutablePointer<CChar>?
        st = CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &ptr)
        guard st == noErr, let ptr else { throw H264Error.blockBuffer(st) }
        fill(UnsafeMutableRawPointer(ptr))
        return bb
    }

    static func sample(_ bb: CMBlockBuffer, length: Int, format: CMVideoFormatDescription, pts: CMTime, sync: Bool) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = length
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        guard st == noErr, let sb else { throw H264Error.sampleBuffer(st) }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            func set(_ key: CFString, _ value: Bool) {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(),
                                     Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
            }
            set(kCMSampleAttachmentKey_DisplayImmediately, true)       // niedrigste Latenz: sofort zeigen
            if !sync {
                set(kCMSampleAttachmentKey_NotSync, true)
                set(kCMSampleAttachmentKey_DependsOnOthers, true)
            }
        }
        return sb
    }
}

/// Zerlegt die Video-Nachrichten. Nur von einer (seriellen) Queue benutzen.
final class H264Depacketizer {
    struct Output {
        let sample: CMSampleBuffer
        let isIDR: Bool
        let formatChanged: Bool
        let width: Int
        let height: Int
    }

    private(set) var format: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()

    func reset() { format = nil; sps = Data(); pps = Data() }

    /// `data[offset...]` = Annex-B-Access-Unit.
    func process(_ data: Data, offset: Int, timestampUs: UInt64) throws -> Output {
        try data.withUnsafeBytes { all -> Output in
            let buf = UnsafeRawBufferPointer(rebasing: all[offset...])
            let p = buf.bindMemory(to: UInt8.self)
            var newSPS: Range<Int>?, newPPS: Range<Int>?
            var slices: [Range<Int>] = []
            var idr = false
            var total = 0
            for r in H264.nalRanges(buf) {
                switch p[r.lowerBound] & 0x1f {
                case 7: newSPS = r                       // SPS (VideoToolbox: Header-Byte 0x27)
                case 8: newPPS = r                       // PPS
                case 6, 9, 10, 11, 12: break             // SEI, AUD, Ende Sequenz/Stream, Füllbytes: nicht nötig
                case let t:
                    if t == 5 { idr = true }
                    slices.append(r); total += 4 + r.count
                }
            }
            var changed = false
            if let s = newSPS, let q = newPPS {
                let sd = Data(UnsafeRawBufferPointer(rebasing: buf[s])), pd = Data(UnsafeRawBufferPointer(rebasing: buf[q]))
                if format == nil || sd != sps || pd != pps {
                    let f = try H264.makeFormat(sps: sd, pps: pd)
                    changed = format != nil
                    format = f; sps = sd; pps = pd
                }
            }
            guard let fmt = format else { throw H264Error.noFormat }
            guard !slices.isEmpty else { throw H264Error.empty }
            let bb = try H264.makeBlockBuffer(length: total) { dst in
                var o = 0
                for r in slices {
                    var len = UInt32(r.count).bigEndian
                    withUnsafeBytes(of: &len) { (dst + o).copyMemory(from: $0.baseAddress!, byteCount: 4) }
                    (dst + o + 4).copyMemory(from: buf.baseAddress! + r.lowerBound, byteCount: r.count)
                    o += 4 + r.count
                }
            }
            let pts = CMTime(value: CMTimeValue(truncatingIfNeeded: timestampUs), timescale: 1_000_000)
            let sb = try H264.sample(bb, length: total, format: fmt, pts: pts, sync: idr)
            let dim = CMVideoFormatDescriptionGetDimensions(fmt)
            return Output(sample: sb, isIDR: idr, formatChanged: changed, width: Int(dim.width), height: Int(dim.height))
        }
    }
}

// MARK: - VTDecompressionSession (Ersatz-Renderer, Probedekodierung, Testprüfung)

final class VTDecoder {
    /// Läuft auf einem VideoToolbox-Thread.
    var onOutput: ((OSStatus, CVPixelBuffer?, CMTime) -> Void)?
    let pixelFormat: OSType
    let requireHardware: Bool
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private(set) var usingHardware: Bool?
    private(set) var lastCreateStatus: OSStatus = noErr

    init(pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, requireHardware: Bool = false) {
        self.pixelFormat = pixelFormat
        self.requireHardware = requireHardware
    }
    deinit { invalidate() }

    func invalidate() {
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s) }
        session = nil; format = nil
    }

    func waitForFrames() { if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s) } }

    private func ensureSession(_ fmt: CMVideoFormatDescription) -> OSStatus {
        if let s = session, let f = format {
            if CFEqual(f, fmt) { return noErr }
            if VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fmt) { format = fmt; return noErr }
        }
        invalidate()
        let dim = CMVideoFormatDescriptionGetDimensions(fmt)
        var spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        if requireHardware { spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: Int(dim.width),
            kCVPixelBufferHeightKey: Int(dim.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
                                              decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &s)
        lastCreateStatus = st
        guard st == noErr, let s else { return st }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hw: CFTypeRef?
        if withUnsafeMutablePointer(to: &hw, { VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                                                       allocator: kCFAllocatorDefault, valueOut: $0) }) == noErr {
            usingHardware = (hw as? Bool) ?? (hw as? NSNumber)?.boolValue
        }
        session = s; format = fmt
        return noErr
    }

    @discardableResult
    func decode(_ sb: CMSampleBuffer, async: Bool = true) -> OSStatus {
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return kVTParameterErr }
        var st = ensureSession(fmt)
        guard st == noErr, let s = session else { return st }
        let handler = onOutput
        var info = VTDecodeInfoFlags()
        let flags: VTDecodeFrameFlags = async ? [._EnableAsynchronousDecompression, ._1xRealTimePlayback] : [._1xRealTimePlayback]
        st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: flags, infoFlagsOut: &info) { status, _, image, pts, _ in
            handler?(status, image.map { $0 as CVPixelBuffer }, pts)
        }
        if st == kVTInvalidSessionErr { invalidate() }     // z. B. nach Ruhezustand: beim nächsten Bild neu anlegen
        return st
    }
}

// MARK: - Probedekodierung beim Start (für die Checkliste)

enum DecodeProbeResult: Equatable {
    case pending
    case hardware(ms: Int)
    case software(ms: Int)
    case failed(String)
}

/// Dekodiert ein eingebautes, schwarzes 4096×2304-H.264-Bild (High Profile, Level 6.0 – wie der Stream bei 60 fps)
/// einmal mit VideoToolbox: zuerst nur Hardware, sonst Software. Zeigt in der Checkliste, ob dieser Mac das kann.
enum DecoderProbe {
    static let width = 4096, height = 2304
    // SPS (Header 0x27, profile 0x64 High, level_idc 0x3c = 6.0) und PPS, erzeugt mit VideoToolbox
    private static let sps = Data([0x27, 0x64, 0x00, 0x3c, 0xac, 0x56, 0x80, 0x10, 0x00, 0x12, 0x19])
    private static let pps = Data([0x28, 0xee, 0x3c, 0xb0])
    // AVCC (SEI + IDR), raw DEFLATE, base64 – 1820 Bytes entpackt
    private static let idrDeflated = "Y2BgsGZjNXIP87oT4+NsP+X9UUGbi84rGBkYmBmYmcEkE/sMBgZuEBOCAniYO1UYef8DQQMDA9tN1R0KjOfPbboT/+XVHLYPq6oLEhBqIYgpSUbnTNi8T44NKMKSDjA26w+4KOM1hIJWBFMVrpZfAK4LzmJmUkAYgBBl6EB3ySgaRaNoFI2iUUQAWSwAAA=="

    private static let lock = NSLock()
    private static var _result: DecodeProbeResult = .pending
    private static var started = false
    static var result: DecodeProbeResult { lock.lock(); defer { lock.unlock() }; return _result }

    /// Einmalig im Hintergrund prüfen; `done` läuft auf dem Main-Thread.
    static func start(_ done: (() -> Void)? = nil) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let r = run()
            lock.lock(); _result = r; lock.unlock()
            Log.write("Probedekodierung H.264 \(width)×\(height) (Level 6.0): \(r)")
            DispatchQueue.main.async { done?() }
        }
    }

    /// Synchron prüfen und merken (für --print-status)
    static func runNow() {
        let r = run()
        lock.lock(); _result = r; started = true; lock.unlock()
    }

    static func run() -> DecodeProbeResult {
        guard let z = Data(base64Encoded: idrDeflated),
              let avcc = try? (z as NSData).decompressed(using: .zlib) as Data else { return .failed("Interner Fehler (Testbild)") }
        let fmt: CMVideoFormatDescription
        let sb: CMSampleBuffer
        do {
            fmt = try H264.makeFormat(sps: sps, pps: pps)
            sb = try H264.makeSample(avcc: avcc, format: fmt, pts: .zero, sync: true)
        } catch { return .failed("\(error)") }
        var lastErr = "?"
        for hw in [true, false] {
            let dec = VTDecoder(requireHardware: hw)
            let sem = DispatchSemaphore(value: 0)
            var out: (OSStatus, Int, Int)?
            dec.onOutput = { st, pb, _ in
                out = (st, pb.map(CVPixelBufferGetWidth) ?? 0, pb.map(CVPixelBufferGetHeight) ?? 0)
                sem.signal()
            }
            let t0 = Date()
            let st = dec.decode(sb, async: false)
            if st != noErr {
                lastErr = dec.lastCreateStatus != noErr ? "Decoder nicht verfügbar (\(dec.lastCreateStatus))" : "Fehler \(st)"
                dec.invalidate(); continue
            }
            dec.waitForFrames()
            _ = sem.wait(timeout: .now() + 3)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let usedHW = dec.usingHardware ?? hw
            dec.invalidate()
            guard let o = out else { lastErr = "kein Bild nach 3 s"; continue }
            guard o.0 == noErr else { lastErr = "Fehler \(o.0)"; continue }
            guard o.1 == width && o.2 == height else { lastErr = "falsche Größe \(o.1)×\(o.2)"; continue }
            return usedHW ? .hardware(ms: ms) : .software(ms: ms)
        }
        return .failed(lastErr)
    }
}
