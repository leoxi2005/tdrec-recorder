import Foundation

/// Kiểm tra bộ giải mã watermark trên các mẫu ảnh tổng hợp.
///
/// Lý do tồn tại: bản đầu tiên của watermark chỉ có counter + checksum. Vùng
/// ảnh đen tuyền cho ra counter 0 với checksum 0 — hợp lệ về mặt toán học! —
/// nên app tưởng nhầm project có watermark đang đứng yên và bỏ sạch frame.
/// Chuỗi nhận dạng 0xB4 sinh ra để chặn đúng lỗi này, và test dưới đây khoá
/// nó lại để không bao giờ tái diễn.
enum DecodeTest {

    static func run() -> Int32 {
        print("── Kiểm tra bộ giải mã watermark ────────────────\n")

        let w = 512, h = 8, bs = 2
        var passed = 0, failed = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition { passed += 1; print("  ✓ \(name)") }
            else { failed += 1; print("  ✗ \(name) \(detail)") }
        }

        // --- Ảnh phẳng: TUYỆT ĐỐI không được nhận là watermark ---
        for (label, fill) in [("đen tuyền", UInt8(0)), ("trắng tuyền", UInt8(255)),
                              ("xám giữa", UInt8(128)), ("gần đen", UInt8(12))] {
            var buf = [UInt8](repeating: fill, count: w * h * 4)
            let r = buf.withUnsafeMutableBytes { raw -> UInt32? in
                Watermark.decode(base: raw.baseAddress!, bytesPerRow: w * 4,
                                 width: w, height: h, blockSize: bs, origin: .top)
            }
            check("ảnh \(label) → không nhận nhầm", r == nil, "(nhận nhầm thành frame \(r ?? 0))")
        }

        // --- Nhiễu ngẫu nhiên: xác suất lọt phải cực thấp ---
        var falseHits = 0
        for seed in 0..<300 {
            var rng = SplitMix(seed: UInt64(seed) &* 2654435761)
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<buf.count { buf[i] = UInt8(rng.next() & 0xFF) }
            let r = buf.withUnsafeMutableBytes { raw -> UInt32? in
                Watermark.decode(base: raw.baseAddress!, bytesPerRow: w * 4,
                                 width: w, height: h, blockSize: bs, origin: .top)
            }
            if r != nil { falseHits += 1 }
        }
        // 8 bit magic + 8 bit checksum = 1/65536 mỗi lần thử.
        check("300 ảnh nhiễu → tối đa 1 lọt", falseHits <= 1, "(lọt \(falseHits))")

        // --- Mã hoá đúng: phải đọc lại chính xác ---
        for frame: UInt32 in [0, 1, 42, 1000, 65535, 0xFFFFFE] {
            var buf = [UInt8](repeating: 30, count: w * h * 4)
            encode(frame: frame, into: &buf, bytesPerRow: w * 4, blockSize: bs)
            let r = buf.withUnsafeMutableBytes { raw -> UInt32? in
                Watermark.decode(base: raw.baseAddress!, bytesPerRow: w * 4,
                                 width: w, height: h, blockSize: bs, origin: .top)
            }
            check("mã hoá frame \(frame) → đọc lại đúng", r == frame, "(đọc ra \(String(describing: r)))")
        }

        // --- Xoá watermark: sau khi xoá phải không còn đọc được ---
        var buf = [UInt8](repeating: 30, count: w * h * 4)
        encode(frame: 12345, into: &buf, bytesPerRow: w * 4, blockSize: bs)
        let after = buf.withUnsafeMutableBytes { raw -> UInt32? in
            Watermark.erase(base: raw.baseAddress!, bytesPerRow: w * 4,
                            width: w, height: h, blockSize: bs, origin: .top)
            return Watermark.decode(base: raw.baseAddress!, bytesPerRow: w * 4,
                                    width: w, height: h, blockSize: bs, origin: .top)
        }
        check("sau khi xoá → không còn dấu vết", after == nil)

        print("\n\(passed) đạt, \(failed) hỏng\n")
        return failed == 0 ? 0 : 1
    }

    /// Ghi watermark vào buffer BGRA đúng layout mà GLSL TOP tạo ra.
    private static func encode(frame: UInt32, into buf: inout [UInt8],
                               bytesPerRow: Int, blockSize: Int) {
        let counter = frame & Watermark.counterMask
        let cksum = Watermark.checksum(counter)
        var bits: UInt64 = UInt64(Watermark.magic)
        bits |= UInt64(counter) << UInt64(Watermark.magicBits)
        bits |= UInt64(cksum) << UInt64(Watermark.magicBits + Watermark.counterBits)

        for bit in 0..<Watermark.bitCount {
            let on = (bits >> UInt64(bit)) & 1 == 1
            let v: UInt8 = on ? 255 : 0
            for dx in 0..<blockSize {
                for dy in 0..<blockSize {
                    let x = bit * blockSize + dx
                    let o = dy * bytesPerRow + x * 4
                    buf[o] = v; buf[o+1] = v; buf[o+2] = v; buf[o+3] = 255
                }
            }
        }
    }

    /// PRNG cố định để test tái lập được (Math.random không dùng được ở đây).
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
