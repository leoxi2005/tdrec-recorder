// frame_source.h — nơi frame đi vào chương trình.
//
// Tách thành interface để vòng lặp ghi trong main.cpp không phụ thuộc Spout.
// Nhờ vậy chạy được `--record --mock` trên máy không có Windows và kiểm chứng
// được toàn bộ đường đi: nhận frame → watermark → gán vị trí → ffmpeg → file.
//
// Chỉ còn đúng một thứ không test được ở ngoài Windows: bản thân SpoutSource.

#pragma once
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace tdrec {

class IFrameSource {
public:
    virtual ~IFrameSource() = default;

    // Lấy frame mới. false = chưa có frame mới (KHÔNG phải lỗi).
    virtual bool Receive() = 0;

    virtual uint8_t* pixels() = 0;
    virtual int      width()  const = 0;
    virtual int      height() const = 0;
    virtual size_t   stride() const = 0;

    virtual bool        SizeChanged() const { return false; }
    virtual std::string name()        const { return "?"; }
    virtual double      sourceFps()   const { return 0.0; }
};

// Nguồn giả lập: sinh frame có watermark đúng quy ước, theo nhịp đặt trước.
// Dùng để kiểm chứng vòng lặp ghi mà không cần TouchDesigner lẫn Windows.
class MockSource : public IFrameSource {
public:
    struct Options {
        int    width      = 1920;
        int    height     = 1080;
        double fps        = 60.0;   // nhịp mà "TouchDesigner" render được
        int    blockSize  = 2;
        bool   watermark  = true;
        bool   stuckCounter = false;  // mô phỏng quên nối uFrame
    };

    explicit MockSource(const Options& o);

    bool     Receive() override;
    uint8_t* pixels() override { return buf_.data(); }
    int      width()  const override { return o_.width; }
    int      height() const override { return o_.height; }
    size_t   stride() const override { return size_t(o_.width) * 4; }
    std::string name() const override { return "MockSource"; }
    double   sourceFps() const override { return o_.fps; }

    uint64_t produced() const { return produced_; }

private:
    Options              o_;
    std::vector<uint8_t> buf_;
    double               t0_ = 0.0;
    uint64_t             produced_ = 0;
    uint32_t             frameNo_ = 1000;   // bắt đầu lệch 0 để kiểm tra chuẩn hoá gốc
};

}  // namespace tdrec
