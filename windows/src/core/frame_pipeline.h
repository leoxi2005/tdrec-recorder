// frame_pipeline.h — quyết định mỗi frame nằm ở vị trí nào trên trục thời gian.
//
// Bản C++ của Sources/TDRec/FramePipeline.swift. Logic phải giống hệt bản Mac.
//
// ── Nguyên tắc ──────────────────────────────────────────────────────────
// Dùng ĐỒNG HỒ THỰC, không dùng số đếm frame của TouchDesigner.
//
// `absTime.frame` tăng 1 mỗi lần TD render xong, không phải mỗi 1/60 giây. Nếu
// TD chỉ chạy được 34fps thì trong 1 giây thực nó chỉ tăng 34 — đặt 34 frame đó
// vào trục 60fps sẽ ra 0.57 giây video, hình chạy nhanh hơn thực tế và trôi
// khỏi nhạc.
//
// Watermark chỉ dùng để: (1) bỏ frame Spout phát lại y hệt, (2) báo TD render
// được bao nhiêu, (3) phát hiện người dùng quên nối uFrame.

#pragma once
#include <cstdint>
#include <cstddef>
#include "watermark.h"

namespace tdrec {

// Nơi nhận frame đã được gán vị trí. Bên hiện thực chịu trách nhiệm giữ
// constant frame rate (chèn lại frame trước cho những ô bị trống).
class FrameSink {
public:
    virtual ~FrameSink() = default;
    virtual void Append(const uint8_t* bgra, size_t bytesPerRow,
                        int width, int height, int64_t index) = 0;
};

class FramePipeline {
public:
    struct Config {
        bool useWatermark   = true;
        int  blockSize      = 2;
        bool eraseWatermark = true;
        int  fps            = 60;
    };

    struct Status {
        bool     watermarkLocked  = false;
        bool     counterStuck     = false;   // uFrame chưa nối absTime.frame
        uint64_t tdFramesRendered = 0;
        uint64_t framesSubmitted  = 0;
        uint64_t framesDropped    = 0;       // bỏ vì trùng hoặc vượt nhịp
    };

    explicit FramePipeline(const Config& cfg) : cfg_(cfg) {}

    void SetSink(FrameSink* sink) { sink_ = sink; }
    void Begin();                      // đặt lại mốc, gọi khi bắt đầu ghi
    void End() { sink_ = nullptr; }

    // Quên kết quả dò watermark — gọi khi đổi nguồn hoặc đổi blockSize.
    void ResetWatermarkLock() { originLocked_ = false; status_.watermarkLocked = false; }

    // Nộp một frame. `timeSeconds` là thời điểm frame xuất hiện, đo bằng đồng
    // hồ đơn điệu của hệ thống (giây, gốc tuỳ ý — chỉ hiệu số mới quan trọng).
    // Buffer có thể bị sửa tại chỗ nếu bật eraseWatermark.
    void Submit(uint8_t* bgra, size_t bytesPerRow,
                int width, int height, double timeSeconds);

    const Status& status() const { return status_; }
    const Config& config() const { return cfg_; }

private:
    Config     cfg_;
    Status     status_;
    FrameSink* sink_ = nullptr;

    bool     started_          = false;
    double   startTime_        = 0.0;
    int64_t  lastAssigned_     = -1;

    bool     haveLastTD_       = false;
    uint32_t lastTD_           = 0;
    bool     counterChanged_   = false;
    int      sameCounterRun_   = 0;

    bool               originLocked_ = false;
    Watermark::Origin  origin_       = Watermark::Origin::Top;
};

}  // namespace tdrec
