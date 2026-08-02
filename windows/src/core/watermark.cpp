#include "watermark.h"
#include <cstring>

namespace tdrec {

namespace {
// Hàng pixel dùng để đọc/ghi, tính theo chiều watermark nằm ở đầu nào của ảnh.
inline int RowFor(int localY, int height, Watermark::Origin origin) {
    return origin == Watermark::Origin::Top ? localY : (height - 1 - localY);
}
}  // namespace

bool Watermark::Decode(const uint8_t* base, size_t bytesPerRow,
                       int width, int height, int blockSize,
                       Origin origin, uint32_t* outFrame) {
    if (blockSize <= 0 || width < blockSize * kBitCount || height < blockSize)
        return false;

    // Lấy hàng giữa của dải để tránh sai số ở biên.
    const int y = RowFor(blockSize / 2, height, origin);
    if (y < 0 || y >= height) return false;

    const uint8_t* row = base + static_cast<size_t>(y) * bytesPerRow;

    uint64_t bits = 0;
    for (int bit = 0; bit < kBitCount; ++bit) {
        const int x = bit * blockSize + blockSize / 2;
        const uint8_t* px = row + static_cast<size_t>(x) * 4;   // BGRA
        // Watermark chỉ có đen/trắng nên B, G, R bằng nhau; cộng cả ba cho chắc.
        const int lum = px[0] + px[1] + px[2];
        if (lum > 383) bits |= (1ull << bit);                    // ngưỡng 128*3
    }

    // Chuỗi nhận dạng phải khớp trước — đây là thứ loại bỏ dương tính giả.
    if (static_cast<uint32_t>(bits & 0xFFull) != kMagic) return false;

    const uint32_t counter =
        static_cast<uint32_t>((bits >> kMagicBits) & kCounterMask);
    const uint32_t cksum =
        static_cast<uint32_t>((bits >> (kMagicBits + kCounterBits)) & 0xFFull);

    if (cksum != Checksum(counter)) return false;
    if (outFrame) *outFrame = counter;
    return true;
}

void Watermark::Erase(uint8_t* base, size_t bytesPerRow,
                      int width, int height, int blockSize, Origin origin) {
    const int stripW = width < blockSize * kBitCount ? width : blockSize * kBitCount;
    if (stripW <= 0 || height <= blockSize) return;
    const size_t byteW = static_cast<size_t>(stripW) * 4;

    // Hàng nguồn sạch = ngay sát ngoài dải watermark.
    const int srcY = RowFor(blockSize, height, origin);
    if (srcY < 0 || srcY >= height) return;
    const uint8_t* src = base + static_cast<size_t>(srcY) * bytesPerRow;

    for (int i = 0; i < blockSize; ++i) {
        const int y = RowFor(i, height, origin);
        if (y < 0 || y >= height) continue;
        std::memcpy(base + static_cast<size_t>(y) * bytesPerRow, src, byteW);
    }
}

void Watermark::Encode(uint8_t* base, size_t bytesPerRow,
                       int width, int height, int blockSize,
                       Origin origin, uint32_t frame) {
    if (blockSize <= 0 || width < blockSize * kBitCount || height < blockSize) return;

    const uint32_t counter = frame & kCounterMask;
    const uint32_t cksum = Checksum(counter);

    uint64_t bits = static_cast<uint64_t>(kMagic);
    bits |= static_cast<uint64_t>(counter) << kMagicBits;
    bits |= static_cast<uint64_t>(cksum) << (kMagicBits + kCounterBits);

    for (int bit = 0; bit < kBitCount; ++bit) {
        const uint8_t v = ((bits >> bit) & 1ull) ? 255 : 0;
        for (int dy = 0; dy < blockSize; ++dy) {
            const int y = RowFor(dy, height, origin);
            if (y < 0 || y >= height) continue;
            uint8_t* row = base + static_cast<size_t>(y) * bytesPerRow;
            for (int dx = 0; dx < blockSize; ++dx) {
                const int x = bit * blockSize + dx;
                uint8_t* px = row + static_cast<size_t>(x) * 4;
                px[0] = v; px[1] = v; px[2] = v; px[3] = 255;
            }
        }
    }
}

}  // namespace tdrec
