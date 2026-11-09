import Foundation

/// Rewrites an H.264 SPS so its VUI carries bitstream_restriction with max_num_reorder_frames = 0.
///
/// VideoToolbox emits pic_order_cnt_type 0 without bitstream_restriction even with frame reordering
/// disabled. Decoders (Chrome's VideoToolbox path, FFmpeg) then assume the worst case and hold back
/// up to 16 frames before output (~300 ms at 4K). Our encoder never reorders, so 0 is correct.
enum SPSRewriter {
    private static var cache: [[UInt8]: [UInt8]] = [:]
    private static let lock = NSLock()

    /// `sps` is a NAL unit without start code (first byte = NAL header). Returns the input on any parse problem.
    static func rewrite(_ sps: [UInt8]) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[sps] { return hit }
        let out = (try? doRewrite(sps)) ?? sps
        if out == sps { log("SPS unverändert gelassen (Parser-Problem oder bereits ok)") }
        cache[sps] = out
        return out
    }

    private struct ParseError: Error {}

    private static func log(_ s: String) {
        print("[Encoder] \(s)")
        fflush(stdout)
    }

    private static func doRewrite(_ nal: [UInt8]) throws -> [UInt8] {
        guard nal.count > 4, nal[0] & 0x1f == 7 else { throw ParseError() }
        var r = BitReader(unescape(Array(nal[1...])))
        var w = BitWriter()

        func cu(_ n: Int) throws -> UInt32 { let v = try r.u(n); w.u(v, n); return v }
        func cue() throws -> UInt32 { let v = try r.ue(); w.ue(v); return v }
        func cse() throws { _ = try cue() } // se(v) has the same bit layout as ue(v)

        let profile = try cu(8)
        _ = try cu(8) // constraint flags
        _ = try cu(8) // level
        _ = try cue() // sps id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = try cue()
            if chroma == 3 { _ = try cu(1) }
            _ = try cue(); _ = try cue() // bit depths
            _ = try cu(1)
            if try cu(1) == 1 { throw ParseError() } // scaling matrices: not emitted by VideoToolbox
        }
        _ = try cue() // log2_max_frame_num
        let pocType = try cue()
        if pocType == 2 { return nal } // already no reordering
        if pocType == 0 {
            _ = try cue()
        } else {
            _ = try cu(1); try cse(); try cse()
            let n = try cue()
            for _ in 0..<n { try cse() }
        }
        let maxRefFrames = try cue()
        _ = try cu(1)
        _ = try cue(); _ = try cue() // size in MBs
        if try cu(1) == 0 { _ = try cu(1) } // frame_mbs_only / mb_adaptive
        _ = try cu(1) // direct_8x8
        if try cu(1) == 1 { for _ in 0..<4 { _ = try cue() } } // cropping

        // VUI: copy everything up to bitstream_restriction_flag, then write our own.
        let vuiPresent = try r.u(1)
        w.u(1, 1)
        if vuiPresent == 1 {
            if try cu(1) == 1 { if try cu(8) == 255 { _ = try cu(16); _ = try cu(16) } } // aspect ratio
            if try cu(1) == 1 { _ = try cu(1) } // overscan
            if try cu(1) == 1 { _ = try cu(3); _ = try cu(1); if try cu(1) == 1 { _ = try cu(8); _ = try cu(8); _ = try cu(8) } }
            if try cu(1) == 1 { _ = try cue(); _ = try cue() } // chroma loc
            if try cu(1) == 1 { _ = try cu(32); _ = try cu(32); _ = try cu(1) } // timing
            func hrd() throws {
                let cnt = try cue(); _ = try cu(4); _ = try cu(4)
                for _ in 0...cnt { _ = try cue(); _ = try cue(); _ = try cu(1) }
                _ = try cu(5); _ = try cu(5); _ = try cu(5); _ = try cu(5)
            }
            let nalHrd = try cu(1); if nalHrd == 1 { try hrd() }
            let vclHrd = try cu(1); if vclHrd == 1 { try hrd() }
            if nalHrd == 1 || vclHrd == 1 { _ = try cu(1) }
            _ = try cu(1) // pic_struct_present
            if try r.u(1) == 1 { return nal } // already has bitstream_restriction
        } else {
            for _ in 0..<9 { w.u(0, 1) } // aspect, overscan, video signal, chroma loc, timing, nal/vcl hrd, pic_struct
        }
        w.u(1, 1)     // bitstream_restriction_flag
        w.u(1, 1)     // motion_vectors_over_pic_boundaries_flag
        w.ue(0)       // max_bytes_per_pic_denom
        w.ue(0)       // max_bits_per_mb_denom
        w.ue(15)      // log2_max_mv_length_horizontal
        w.ue(15)      // log2_max_mv_length_vertical
        w.ue(0)       // max_num_reorder_frames
        w.ue(max(1, maxRefFrames)) // max_dec_frame_buffering
        w.u(1, 1)     // rbsp_stop_one_bit
        w.align()

        let out = [nal[0]] + escape(w.bytes)
        log("SPS mit max_num_reorder_frames=0 ergänzt (verhindert Decoder-Puffer)")
        return out
    }

    // MARK: - RBSP helpers

    private static func unescape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(b.count)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    private static func escape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(b.count + 4)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x <= 3 { out.append(3); zeros = 0 }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct BitReader {
        let data: [UInt8]
        var pos = 0
        init(_ d: [UInt8]) { data = d }
        mutating func u(_ n: Int) throws -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<n {
                guard pos / 8 < data.count else { throw ParseError() }
                v = (v << 1) | UInt32((data[pos / 8] >> (7 - UInt8(pos % 8))) & 1)
                pos += 1
            }
            return v
        }
        mutating func ue() throws -> UInt32 {
            var zeros = 0
            while try u(1) == 0 { zeros += 1; if zeros > 31 { throw ParseError() } }
            return zeros == 0 ? 0 : (UInt32(1) << UInt32(zeros)) - 1 + (try u(zeros))
        }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var bit = 0
        mutating func u(_ v: UInt32, _ n: Int) {
            for i in stride(from: n - 1, through: 0, by: -1) {
                if bit % 8 == 0 { bytes.append(0) }
                if (v >> UInt32(i)) & 1 == 1 { bytes[bytes.count - 1] |= 1 << (7 - UInt8(bit % 8)) }
                bit += 1
            }
        }
        mutating func ue(_ v: UInt32) {
            let x = UInt64(v) + 1
            let len = 64 - x.leadingZeroBitCount
            u(0, len - 1)
            u(UInt32(x), len)
        }
        mutating func align() { while bit % 8 != 0 { u(0, 1) } }
    }
}
