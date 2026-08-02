// watermark.h — giải mã / xoá watermark đếm frame.
//
// Bản C++ của Sources/TDRec/Watermark.swift. Phải khớp TỪNG BIT với bản Swift
// và với td/tdrec_watermark.frag, nếu không cùng một project TouchDesigner sẽ
// cho kết quả khác nhau giữa Mac và Windows.
//
// Layout: 40 block, mỗi block blockSize×blockSize px, xếp ngang.
//   bit  0..7  : chuỗi nhận dạng cố định 0xB4
//   bit  8..31 : số frame (mod 2^24)
//   bit 32..39 : checksum = (f ^ f>>8 ^ f>>16) & 0xFF
// Trắng = 1, đen = 0.
//
// Chuỗi nhận dạng là bắt buộc: nếu chỉ có counter + checksum thì vùng ảnh đen
// tuyền giải mã ra counter 0 với checksum 0 — hợp lệ về mặt toán học — và app
// tưởng nhầm project có watermark đứng yên rồi bỏ sạch frame.

#pragma once
#include <cstdint>
#include <cstddef>

namespace tdrec {

struct Watermark {
    static constexpr int      kBitCount    = 40;
    static constexpr uint32_t kMagic       = 0xB4;
    static constexpr int      kMagicBits   = 8;
    static constexpr int      kCounterBits = 24;
    static constexpr uint32_t kCounterMask = (1u << 24) - 1u;

    enum class Origin { Top, Bottom };

    static uint32_t Checksum(uint32_t f) {
        return (f ^ (f >> 8) ^ (f >> 16)) & 0xFFu;
    }

    // Giải mã từ buffer BGRA. Trả về false nếu không có watermark hợp lệ.
    static bool Decode(const uint8_t* base, size_t bytesPerRow,
                       int width, int height, int blockSize,
                       Origin origin, uint32_t* outFrame);

    // Xoá dải watermark bằng cách chép hàng pixel sạch ngay cạnh đè lên.
    static void Erase(uint8_t* base, size_t bytesPerRow,
                      int width, int height, int blockSize, Origin origin);

    // Ghi watermark vào buffer — chỉ dùng cho self-test (đóng vai TouchDesigner).
    static void Encode(uint8_t* base, size_t bytesPerRow,
                       int width, int height, int blockSize,
                       Origin origin, uint32_t frame);
};

}  // namespace tdrec
