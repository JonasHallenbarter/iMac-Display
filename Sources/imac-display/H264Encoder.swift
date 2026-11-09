import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Hardware H.264 encoder (VideoToolbox) producing Annex B access units.
///
/// Threading: all state except the stats / config is owned by `queue` (serial). `encode(...)` must be
/// called on `queue` (ScreenCapture delivers its sample buffers on this queue). Everything else is
/// safe to call from any thread.
final class H264Encoder {
    struct Settings {
        var fps: Int = 60
        var bitrateMbit: Double = 100

        // --- tuning (defaults chosen with `--selftest-quality`, see QualityLab.swift) ---

        /// DataRateLimits: at most `bitrate * peakFactor` over `peakWindow` seconds. 0 disables the limit.
        var peakFactor: Double = 1.5
        var peakWindow: Double = 1.0
        /// kVTCompressionPropertyKey_Quality (0...1); nil = not set.
        var quality: Double? = nil
        /// Constant-quality mode: do not set AverageBitRate, set Quality to this value instead
        /// (DataRateLimits from `bitrateMbit * peakFactor` still caps the rate). nil = average-bitrate mode.
        var constantQuality: Double? = nil
        /// kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality (only set when true; the standard-mode
        /// H.264 encoder rejects it with -12900 on M4 Pro anyway).
        var prioritizeSpeed: Bool = false
        /// Try kVTVideoEncoderSpecification_EnableLowLatencyRateControl first. Off by default: at 4096x2304 it only
        /// works up to ExpectedFrameRate 56 (level 5.2 limit) and then drops ~2/3 of all frames; at 60 fps it
        /// outputs nothing (the probe falls back to the standard mode).
        var lowLatency: Bool = false
        /// kVTCompressionPropertyKey_MaxFrameDelayCount; nil = not set (encoder default).
        var maxFrameDelayCount: Int? = nil
        /// kVTCompressionPropertyKey_MaxAllowedFrameQP / MinAllowedFrameQP; nil = not set.
        var maxQP: Int? = nil
        var minQP: Int? = nil
        /// kVTCompressionPropertyKey_SpatialAdaptiveQPLevel (macOS 15+): -1 default, 0 disable; nil = not set.
        var spatialAQ: Int? = nil
        /// Periodic keyframe interval (seconds).
        var keyframeIntervalSeconds: Double = 5
        /// true: the encoder forces the periodic keyframe itself, and only on frames with new content (a static
        /// screen never gets periodic IDRs, which would visibly drop text quality every few seconds until the
        /// refinement catches up). false: VideoToolbox inserts them by PTS distance (old behaviour).
        var keyframesOnlyOnChange: Bool = true

        /// Static refinement: when no new frame arrived for `refineDelayMs`, re-encode the cached frame up to
        /// `refineCount` times (every `refineIntervalMs`) so static content converges to near-lossless quickly.
        var refineCount: Int = 12
        var refineDelayMs: Double = 80
        var refineIntervalMs: Double = 17
        /// Stop refining early once the encoder-reported luma PSNR (macOS 14.4+) reaches this value. 0 = never.
        var refineTargetPSNR: Double = 60
        /// While refining, raise AverageBitRate (and DataRateLimits) by this factor so the rate control spends
        /// enough bits to sharpen the static frame. VideoToolbox honours AverageBitRate changes mid-session, but
        /// ignores MaxAllowedFrameQP changes (measured on M4 Pro / macOS 26). 1 = no boost.
        var refineBitrateFactor: Double = 8
        /// Make the first refine frame an IDR (at the boosted rate). The rate control otherwise sometimes keeps
        /// skipping unchanged macroblocks after a long run of small updates, and the refinement does nothing.
        var refineStartsWithKeyframe: Bool = true
        /// Ask VideoToolbox for per-frame luma MSE (macOS 14.4+). Needed for `refineTargetPSNR`.
        var calculateMSE: Bool = false
        /// Drop new captured frames while this many frames are still inside the encoder (0 = never drop).
        /// The hardware encoder cannot always sustain 4096x2304@60; without a limit frames queue up inside
        /// VideoToolbox and latency grows to 100+ ms. The newest frame is encoded as soon as there is room.
        var maxInFlight: Int = 1
        /// Experimental knobs (lab only): CAVLC instead of CABAC, kVTCompressionPropertyKey_MaximumRealTimeFrameRate
        /// (macOS 15+), kVTCompressionPropertyKey_MaxH264SliceBytes.
        var entropyCAVLC: Bool = false
        var maxRealTimeFrameRate: Double? = nil
        var maxSliceBytes: Int? = nil

        /// The configuration used before the quality lab (for before/after comparisons).
        static func legacy(fps: Int, bitrateMbit: Double) -> Settings {
            var s = Settings(fps: fps, bitrateMbit: bitrateMbit)
            s.peakFactor = 1.5; s.peakWindow = 1.0; s.quality = nil; s.prioritizeSpeed = true
            s.lowLatency = true; s.constantQuality = nil; s.maxFrameDelayCount = nil; s.maxQP = nil; s.minQP = nil; s.spatialAQ = nil
            s.keyframeIntervalSeconds = 5; s.refineCount = 0; s.refineTargetPSNR = 0; s.refineBitrateFactor = 1
            s.calculateMSE = false; s.maxInFlight = 0; s.keyframesOnlyOnChange = false
            return s
        }
    }

    /// Per-frame details (for diagnostics and the quality lab).
    struct FrameInfo {
        enum Kind: String { case capture, keyframeRequest, idleRefresh, refine }
        var kind: Kind
        /// Number of the captured buffer this frame was encoded from (1 = first `encode` call).
        var sourceSeq: Int
        var isKey: Bool
        var bytes: Int
        /// DispatchTime.now().uptimeNanoseconds at submission / at output.
        var submitNs: UInt64
        var outputNs: UInt64
        /// Encoder-reported luma MSE (only with `calculateMSE`, macOS 14.4+).
        var lumaMSE: Double?
    }

    let queue = DispatchQueue(label: "imac-display.encoder", qos: .userInteractive)

    /// JSON config ({"codec","width","height","fps"}), called whenever it is first known or changes.
    var onConfig: ((Data) -> Void)?
    /// One encoded access unit (Annex B; keyframes start with SPS + PPS).
    var onFrame: ((Data, Bool, UInt64) -> Void)?
    /// Same access unit plus details; called right before `onFrame` on the same thread.
    var onEncodedFrame: ((Data, FrameInfo) -> Void)?

    let settings: Settings
    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private(set) var usingLowLatencyRC = false

    // queue-owned
    private var cachedBuffer: CVPixelBuffer?
    private var cachedSeq = 0
    private var keyframePending = false
    private var lastPTS: CMTime = .invalid
    private var lastEncodeHostTime: UInt64 = 0 // DispatchTime uptime ns
    private var idleTimer: DispatchSourceTimer?
    private var refineTimer: DispatchSourceTimer?
    private var refineRemaining = 0
    private var refineBoostActive = false
    private var refineNeedsKey = false
    private var skippedLatest = false
    private var rateWarningLogged = false

    // output-side state (VT callback thread), guarded by `lock`
    private let lock = NSLock()
    private var firstPTS: CMTime = .invalid
    private var lastTimestampUs: UInt64 = 0
    private var currentConfig: Data?
    private var statFrames = 0
    private var statBytes = 0
    private var statKeyframes = 0
    private var statFramesTotal = 0
    private var lastLumaPSNR: Double = 0 // written on VT thread, read on queue (under lock)
    private var inFlight = 0
    private var lastKeyNs: UInt64 = 0
    private var statDropped = 0

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: public API

    /// Encode a captured frame. Must be called on `queue`.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        cachedBuffer = pixelBuffer
        cachedSeq += 1
        if cachedSeq == 1 { logColorTags(pixelBuffer) }
        if settings.maxInFlight > 0 {
            lock.lock(); let busy = inFlight >= settings.maxInFlight; if busy { statDropped += 1 }; lock.unlock()
            if busy { skippedLatest = true; return }
        }
        skippedLatest = false
        forcePeriodicKeyIfDue()
        encodeOnQueue(pixelBuffer, pts: pts, kind: .capture)
    }

    private func forcePeriodicKeyIfDue() {
        guard settings.keyframesOnlyOnChange, settings.keyframeIntervalSeconds > 0 else { return }
        lock.lock(); let last = lastKeyNs; lock.unlock()
        if last > 0, DispatchTime.now().uptimeNanoseconds &- last >= UInt64(settings.keyframeIntervalSeconds * 1e9) {
            keyframePending = true
        }
    }

    /// Logs the colour tags of the first captured buffer once (they must match the BT.709 / video-range VUI).
    private func logColorTags(_ pb: CVPixelBuffer) {
        func tag(_ k: CFString) -> String {
            (CVBufferCopyAttachment(pb, k, nil) as? String)?.replacingOccurrences(of: "ITU_R_", with: "") ?? "–"
        }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let fourcc = String((0..<4).map { Character(UnicodeScalar(UInt8((fmt >> (24 - 8 * $0)) & 0xff))) })
        logLine("Capture-Farbtags: Format \(fourcc) (\(fourcc == "420v" ? "NV12 video range" : "unerwartet!")), "
                + "Matrix \(tag(kCVImageBufferYCbCrMatrixKey)), Primaries \(tag(kCVImageBufferColorPrimariesKey)), "
                + "Transfer \(tag(kCVImageBufferTransferFunctionKey)) → SPS-VUI: BT.709, video range")
    }

    /// Captured frames skipped because the encoder was busy (since the last call).
    func takeDroppedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let d = statDropped; statDropped = 0
        return d
    }

    /// Called on the VT thread whenever a frame left the encoder.
    private func frameLeftEncoder() {
        lock.lock(); inFlight -= 1; lock.unlock()
        guard settings.maxInFlight > 0 else { return }
        queue.async {
            guard self.skippedLatest, let buf = self.cachedBuffer, self.session != nil else { return }
            self.lock.lock(); let room = self.inFlight < self.settings.maxInFlight; self.lock.unlock()
            guard room else { return }
            self.skippedLatest = false
            self.forcePeriodicKeyIfDue()
            self.encodeOnQueue(buf, pts: self.hostNow(), kind: .capture)
        }
    }

    /// Force the next frame to be a keyframe. If the screen is static (no new frames from
    /// ScreenCaptureKit within ~50 ms), the last captured buffer is re-encoded as keyframe.
    func requestKeyframe() {
        queue.async {
            self.keyframePending = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard self.keyframePending, let buf = self.cachedBuffer else { return }
                self.encodeOnQueue(buf, pts: self.hostNow(), kind: .keyframeRequest)
            }
        }
    }

    /// Re-send the cached frame roughly once per second if nothing new was captured
    /// (keeps the client alive / lets it recover on a static screen).
    func startIdleRefresh(interval: TimeInterval = 1.0) {
        queue.async {
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in
                guard let self, let buf = self.cachedBuffer else { return }
                let idleNs = DispatchTime.now().uptimeNanoseconds &- self.lastEncodeHostTime
                if idleNs >= UInt64(interval * 1e9) {
                    self.encodeOnQueue(buf, pts: self.hostNow(), kind: .idleRefresh)
                }
            }
            t.resume()
            self.idleTimer = t
        }
    }

    func stop() {
        queue.sync {
            idleTimer?.cancel()
            idleTimer = nil
            refineTimer?.cancel()
            refineTimer = nil
            if let s = session {
                VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(s)
            }
            session = nil
            cachedBuffer = nil
        }
    }

    /// Returns (frames, bytes, keyframes) since the last call.
    func takeStats() -> (frames: Int, bytes: Int, keyframes: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (statFrames, statBytes, statKeyframes)
        statFrames = 0; statBytes = 0; statKeyframes = 0
        return r
    }

    var codecConfigJSON: Data? {
        lock.lock(); defer { lock.unlock() }
        return currentConfig
    }

    // MARK: session

    private func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        var attempts: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
             kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true],
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
        ]
        if !settings.lowLatency || ProcessInfo.processInfo.environment["IMAC_DISPLAY_NO_LOWLATENCY"] != nil {
            attempts.removeFirst()
        }
        for spec in attempts {
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            guard st == noErr, let s else {
                logLine("VTCompressionSessionCreate fehlgeschlagen (\(st)) mit \(spec.keys)")
                continue
            }
            let lowLatency = spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] != nil
            if configure(s), !lowLatency || probeProducesOutput(s, width: width, height: height) {
                usingLowLatencyRC = lowLatency
                logLine("H.264-Encoder: \(width)x\(height) @ \(settings.fps) fps, \(settings.bitrateMbit) Mbit/s, Hardware, LowLatencyRC=\(lowLatency)"
                        + (settings.refineCount > 0 ? ", Standbild-Verfeinerung \(settings.refineCount)x" : ""))
                return s
            }
            VTCompressionSessionInvalidate(s)
        }
        return nil
    }

    /// The low-latency rate control silently produces no output for some sizes (e.g. 4096x2304 on M4 Pro).
    /// Encode one black frame synchronously and check that something comes out.
    private func probeProducesOutput(_ s: VTCompressionSession, width: Int, height: Int) -> Bool {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        for plane in 0..<2 {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) {
                memset(base, plane == 0 ? 16 : 128, CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let got = NSLock()
        var ok = false
        let pts = CMTimeSubtract(hostNow(), CMTime(value: 1, timescale: 1))
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: nil, infoFlagsOut: nil) { status, _, sbuf in
            got.lock(); ok = (status == noErr && sbuf != nil); got.unlock()
        }
        guard st == noErr else { return false }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        got.lock(); defer { got.unlock() }
        if !ok { logLine("Low-Latency-Ratensteuerung liefert bei \(width)x\(height) keine Daten – verwende Standardmodus") }
        return ok
    }

    private func configure(_ s: VTCompressionSession) -> Bool {
        let fps = settings.fps
        let bps = settings.bitrateMbit * 1_000_000
        func set(_ key: CFString, _ value: CFTypeRef, required: Bool = true) -> Bool {
            let st = VTSessionSetProperty(s, key: key, value: value)
            if st != noErr {
                logLine("VTSessionSetProperty \(key) fehlgeschlagen (\(st))\(required ? "" : " – ignoriert")")
                return !required
            }
            return true
        }
        var ok = true
        ok = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue) && ok
        ok = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) && ok
        ok = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel) && ok
        if let cq = settings.constantQuality {
            ok = set(kVTCompressionPropertyKey_Quality, NSNumber(value: cq)) && ok
        } else {
            ok = set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Int(bps))) && ok
        }
        if settings.peakFactor > 0 {
            let limits = [NSNumber(value: Int(bps * settings.peakFactor * settings.peakWindow / 8)),
                          NSNumber(value: settings.peakWindow)] as CFArray
            _ = set(kVTCompressionPropertyKey_DataRateLimits, limits, required: false)
        }
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps), required: false)
        // with keyframesOnlyOnChange the encoder forces periodic keyframes itself (see encode()); VT's own limit is
        // then only a far-away safety net
        let kfi = settings.keyframesOnlyOnChange ? 3600 : max(1, settings.keyframeIntervalSeconds)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(Double(fps) * kfi)), required: false)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: kfi), required: false)
        if settings.prioritizeSpeed {
            _ = set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue, required: false)
        }
        _ = set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse, required: false)
        if let q = settings.quality {
            _ = set(kVTCompressionPropertyKey_Quality, NSNumber(value: q), required: false)
        }
        if let d = settings.maxFrameDelayCount {
            _ = set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: d), required: false)
        }
        if let q = settings.maxQP {
            _ = set(kVTCompressionPropertyKey_MaxAllowedFrameQP, NSNumber(value: q), required: false)
        }
        if let q = settings.minQP {
            _ = set(kVTCompressionPropertyKey_MinAllowedFrameQP, NSNumber(value: q), required: false)
        }
        if let aq = settings.spatialAQ, #available(macOS 15.0, *) {
            _ = set(kVTCompressionPropertyKey_SpatialAdaptiveQPLevel, NSNumber(value: aq), required: false)
        }
        if settings.entropyCAVLC {
            _ = set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CAVLC, required: false)
        }
        if let r = settings.maxRealTimeFrameRate, #available(macOS 15.0, *) {
            _ = set(kVTCompressionPropertyKey_MaximumRealTimeFrameRate, NSNumber(value: r), required: false)
        }
        if let b = settings.maxSliceBytes {
            _ = set(kVTCompressionPropertyKey_MaxH264SliceBytes, NSNumber(value: b), required: false)
        }
        if settings.calculateMSE || settings.refineTargetPSNR > 0, #available(macOS 14.4, *) {
            _ = set(kVTCompressionPropertyKey_CalculateMeanSquaredError, kCFBooleanTrue, required: false)
        }
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2, required: false)
        _ = set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2, required: false)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2, required: false)
        if !ok { return false }
        return VTCompressionSessionPrepareToEncodeFrames(s) == noErr
    }

    // MARK: static refinement (on queue)

    private func scheduleRefine(after ms: Double) {
        if refineTimer == nil {
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.setEventHandler { [weak self] in self?.refineTick() }
            t.schedule(deadline: .distantFuture)
            t.resume()
            refineTimer = t
        }
        refineTimer?.schedule(deadline: .now() + .microseconds(Int(ms * 1000)), leeway: .milliseconds(1))
    }

    private func refineTick() {
        guard refineRemaining > 0, let buf = cachedBuffer, session != nil else { endRefineQP(); return }
        if settings.refineTargetPSNR > 0 {
            lock.lock(); let p = lastLumaPSNR; lock.unlock()
            if p >= settings.refineTargetPSNR { refineRemaining = 0; endRefineQP(); return }
        }
        if settings.maxInFlight > 0 {
            // never queue refine frames behind each other: a new capture must find the encoder (almost) idle
            lock.lock(); let busy = inFlight >= settings.maxInFlight; lock.unlock()
            if busy { scheduleRefine(after: 3); return }
        }
        let first = refineRemaining == settings.refineCount
        let key = first && refineNeedsKey
        refineNeedsKey = false
        refineRemaining -= 1
        if settings.refineBitrateFactor > 1, !refineBoostActive, let s = session {
            applyRate(s, factor: settings.refineBitrateFactor)
            refineBoostActive = true
        }
        encodeOnQueue(buf, pts: hostNow(), kind: .refine, forceKey: key)
    }

    private func endRefineQP() {
        guard refineBoostActive, let s = session else { refineBoostActive = false; return }
        refineBoostActive = false
        applyRate(s, factor: 1)
    }

    /// Sets AverageBitRate / DataRateLimits to `factor` times the configured values (no-op in constant-quality mode).
    private func applyRate(_ s: VTCompressionSession, factor: Double) {
        guard settings.constantQuality == nil else { return }
        let bps = settings.bitrateMbit * 1_000_000 * factor
        let st1 = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: Int(bps)))
        var st2: OSStatus = noErr
        if settings.peakFactor > 0 {
            let limits = [NSNumber(value: Int(bps * settings.peakFactor * settings.peakWindow / 8)),
                          NSNumber(value: settings.peakWindow)] as CFArray
            st2 = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        }
        if (st1 != noErr || st2 != noErr) && !rateWarningLogged {
            rateWarningLogged = true
            logLine("Ratenumschaltung (Faktor \(factor), \(Int(bps / 1e6)) Mbit/s) abgelehnt: AverageBitRate \(st1), DataRateLimits \(st2)")
        }
    }

    // MARK: encoding (on queue)

    private func encodeOnQueue(_ pixelBuffer: CVPixelBuffer, pts inPTS: CMTime, kind inKind: FrameInfo.Kind,
                               forceKey refineKey: Bool = false) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || w != sessionWidth || h != sessionHeight {
            if let old = session {
                VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(old)
            }
            session = makeSession(width: w, height: h)
            sessionWidth = w; sessionHeight = h
            keyframePending = true
            refineBoostActive = false
            if session == nil {
                logLine("FEHLER: Kein Hardware-H.264-Encoder für \(w)x\(h) verfügbar.")
                return
            }
        }
        guard let session else { return }

        // A forced keyframe (new client / periodic) is never sent at the boosted refine rate, and static content
        // gets refined again after it.
        let kind: FrameInfo.Kind = (inKind == .refine && keyframePending) ? .keyframeRequest : inKind
        if kind != .refine, refineBoostActive { endRefineQP() }
        // New content or a fresh keyframe → refine (again). An idle refresh re-sends identical content and must
        // not restart a finished refinement.
        if kind == .capture || kind == .keyframeRequest || (kind == .idleRefresh && keyframePending) {
            refineRemaining = settings.refineCount
            refineNeedsKey = settings.refineStartsWithKeyframe && !keyframePending
        }

        // monotonic PTS
        var pts = inPTS
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
        }
        lastPTS = pts
        let submitNs = DispatchTime.now().uptimeNanoseconds
        lastEncodeHostTime = submitNs

        let forceKey = keyframePending || refineKey
        keyframePending = false
        let props: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let seq = cachedSeq
        let frameKind = kind
        lock.lock(); inFlight += 1; lock.unlock()

        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(settings.fps)),
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sbuf in
            guard let self else { return }
            defer { self.frameLeftEncoder() }
            guard status == noErr, let sbuf, !infoFlags.contains(.frameDropped) else {
                if forceKey { self.queue.async { self.keyframePending = true } }
                return
            }
            self.handleOutput(sbuf, kind: frameKind, seq: seq, submitNs: submitNs)
        }
        if st != noErr {
            logLine("VTCompressionSessionEncodeFrame fehlgeschlagen (\(st))")
            lock.lock(); inFlight -= 1; lock.unlock()
            if forceKey { keyframePending = true }
            if st == kVTInvalidSessionErr { self.session = nil }
            return
        }
        if settings.refineCount > 0 {
            if refineRemaining > 0 {
                scheduleRefine(after: kind == .refine ? settings.refineIntervalMs : settings.refineDelayMs)
            } else if refineBoostActive {
                // last refine frame submitted: restore the normal rate shortly after
                scheduleRefine(after: settings.refineIntervalMs)
            }
        }
    }

    // MARK: output (VT thread)

    private func handleOutput(_ sbuf: CMSampleBuffer, kind: FrameInfo.Kind, seq: Int, submitNs: UInt64) {
        guard let fmt = CMSampleBufferGetFormatDescription(sbuf),
              let block = CMSampleBufferGetDataBuffer(sbuf) else { return }

        var isKey = true
        var lumaMSE: Double?
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first {
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool, notSync { isKey = false }
            if #available(macOS 14.4, *),
               let qm = first[kVTSampleAttachmentKey_QualityMetrics] as? [CFString: Any] {
                if let n = qm[kVTSampleAttachmentQualityMetricsKey_LumaMeanSquaredError] as? NSNumber {
                    lumaMSE = n.doubleValue
                } else if let arr = qm[kVTSampleAttachmentQualityMetricsKey_LumaMeanSquaredError] as? [NSNumber], !arr.isEmpty {
                    lumaMSE = arr.map(\.doubleValue).reduce(0, +) / Double(arr.count)
                }
            }
        }

        // parameter sets
        var psCount = 0
        var nalLenSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &psCount, nalUnitHeaderLengthOut: &nalLenSize)

        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        var sps: [UInt8]?
        if isKey {
            for i in 0..<psCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    var bytes = Array(UnsafeBufferPointer(start: ptr, count: size))
                    if bytes.first.map({ $0 & 0x1f == 7 }) == true {
                        bytes = SPSRewriter.rewrite(bytes)
                        sps = bytes
                    }
                    out.append(contentsOf: startCode)
                    out.append(contentsOf: bytes)
                }
            }
        }

        // AVCC → Annex B
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let copyStatus = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }
        let n = Int(nalLenSize)
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var off = 0
            while off + n <= total {
                var len = 0
                for k in 0..<n { len = (len << 8) | Int(p[off + k]) }
                off += n
                guard len > 0, off + len <= total else { break }
                out.append(contentsOf: startCode)
                out.append(UnsafeBufferPointer(rebasing: p[off..<(off + len)]))
                off += len
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
        var configToSend: Data?
        let tsUs: UInt64
        lock.lock()
        if !firstPTS.isValid { firstPTS = pts }
        let rel = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS))
        var t = rel.isFinite && rel > 0 ? UInt64(rel * 1_000_000) : 0
        if t <= lastTimestampUs && statFramesTotal > 0 { t = lastTimestampUs + 1 }
        lastTimestampUs = t
        statFramesTotal += 1
        tsUs = t
        if let sps, sps.count >= 4 {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            let codec = String(format: "avc1.%02x%02x%02x", sps[1], sps[2], sps[3])
            let obj: [String: Any] = ["codec": codec, "width": Int(dims.width), "height": Int(dims.height), "fps": settings.fps]
            if let json = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), json != currentConfig {
                currentConfig = json
                configToSend = json
            }
        }
        if let m = lumaMSE { lastLumaPSNR = m > 0 ? 10 * log10(255 * 255 / m) : 99 } else { lastLumaPSNR = 0 }
        statFrames += 1
        statBytes += out.count
        if isKey { statKeyframes += 1; lastKeyNs = DispatchTime.now().uptimeNanoseconds }
        lock.unlock()

        if let configToSend {
            logLine("Stream-Config: \(String(data: configToSend, encoding: .utf8) ?? "?")")
            onConfig?(configToSend)
        }
        if let cb = onEncodedFrame {
            cb(out, FrameInfo(kind: kind, sourceSeq: seq, isKey: isKey, bytes: out.count, submitNs: submitNs,
                              outputNs: DispatchTime.now().uptimeNanoseconds, lumaMSE: lumaMSE))
        }
        onFrame?(out, isKey, tsUs)
    }
}

func logLine(_ s: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    print("[\(df.string(from: Date()))] \(s)")
    fflush(stdout)
}
