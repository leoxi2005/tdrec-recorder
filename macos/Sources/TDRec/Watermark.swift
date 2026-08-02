import Foundation

/// Watermark nhúng số frame của TouchDesigner vào vài pixel góc trên-trái.
///
/// Vì sao cần: Syphon chỉ publish "frame mới nhất", không có hàng đợi. Nếu app
/// nhận chậm hơn TD render thì frame bị nuốt, nếu nhanh hơn thì nhận trùng —
/// cả hai đều làm video giật dù FPS trung bình vẫn đúng. Đọc được số frame
/// thật của TD thì ta biết CHÍNH XÁC frame nào thiếu và chèn bù để giữ CFR,
/// nhờ đó A/V không bao giờ trôi.
///
/// Layout: 40 block, mỗi block `blockSize`×`blockSize` px, xếp ngang.
///   bit 0..7   : chuỗi nhận dạng cố định 0xB4 (0b10110100)
///   bit 8..31  : số frame (mod 2^24 ≈ 77 giờ @60fps)
///   bit 32..39 : checksum = (f ^ f>>8 ^ f>>16) & 0xFF
/// Trắng = 1, đen = 0.
///
/// Chuỗi nhận dạng là bắt buộc: nếu chỉ có counter + checksum thì vùng ảnh
/// đen tuyền sẽ giải mã thành counter 0 với checksum 0 — hợp lệ! — và app
/// tưởng nhầm là có watermark đứng yên. Vùng trắng tuyền cũng vậy. Chuỗi
/// 0xB4 xen kẽ sáng-tối nên không thể xuất hiện ở vùng màu phẳng.
enum Watermark {

    static let bitCount = 40
    static let magic: UInt32 = 0xB4
    static let magicBits = 8
    static let counterBits = 24
    static let counterMask: UInt32 = (1 << 24) - 1

    static func checksum(_ f: UInt32) -> UInt32 {
        ((f ^ (f >> 8) ^ (f >> 16)) & 0xFF)
    }

    /// Chiều nào của ảnh chứa watermark. Syphon/Metal có thể lật dọc tuỳ nguồn,
    /// nên lần đầu ta dò cả hai rồi khoá lại.
    enum Origin { case top, bottom }

    /// Giải mã watermark từ buffer BGRA.
    /// - Returns: số frame của TD, hoặc nil nếu checksum sai (không có watermark).
    static func decode(base: UnsafeRawPointer,
                       bytesPerRow: Int,
                       width: Int,
                       height: Int,
                       blockSize: Int,
                       origin: Origin) -> UInt32? {

        guard blockSize > 0,
              width >= blockSize * bitCount,
              height >= blockSize else { return nil }

        // lấy hàng giữa của dải để tránh lỗi biên
        let localY = blockSize / 2
        let y = (origin == .top) ? localY : (height - 1 - localY)
        guard y >= 0, y < height else { return nil }

        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)

        var bits: UInt64 = 0
        for bit in 0..<bitCount {
            let x = bit * blockSize + blockSize / 2
            let px = row + (x * 4)          // BGRA
            // luminance thô: B,G,R đều nhau vì watermark là đen/trắng
            let lum = Int(px[0]) + Int(px[1]) + Int(px[2])
            if lum > 383 { bits |= (1 << UInt64(bit)) }   // ngưỡng 128*3
        }

        // Chuỗi nhận dạng phải khớp trước — đây là thứ loại bỏ dương tính giả
        // ở vùng ảnh đen tuyền / trắng tuyền.
        guard UInt32(bits & 0xFF) == magic else { return nil }

        let counter = UInt32((bits >> UInt64(magicBits)) & UInt64(counterMask))
        let cksum = UInt32((bits >> UInt64(magicBits + counterBits)) & 0xFF)
        return cksum == checksum(counter) ? counter : nil
    }

    /// Xoá watermark khỏi ảnh sau khi đã đọc, bằng cách chép hàng pixel ngay
    /// dưới dải đè lên. Nhờ vậy file record ra không dính vệt nhấp nháy ở góc.
    static func erase(base: UnsafeMutableRawPointer,
                      bytesPerRow: Int,
                      width: Int,
                      height: Int,
                      blockSize: Int,
                      origin: Origin) {

        let stripW = min(width, blockSize * bitCount)
        guard stripW > 0, height > blockSize else { return }
        let byteW = stripW * 4

        // hàng nguồn sạch = ngay sát dưới (hoặc trên) dải watermark
        let srcY = (origin == .top) ? blockSize : (height - 1 - blockSize)
        guard srcY >= 0, srcY < height else { return }
        let src = base.advanced(by: srcY * bytesPerRow)

        for i in 0..<blockSize {
            let y = (origin == .top) ? i : (height - 1 - i)
            guard y >= 0, y < height else { continue }
            memcpy(base.advanced(by: y * bytesPerRow), src, byteW)
        }
    }
}
