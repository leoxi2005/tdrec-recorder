// ffmpeg_sink.h — nhận frame và đẩy sang ffmpeg qua pipe.
//
// Vì sao dùng ffmpeg thay vì gọi thẳng NVENC: Windows KHÔNG có encoder ProRes
// phần cứng như Apple Silicon. Đường nhanh nhất trên NVIDIA là NVENC HEVC/H.264,
// mà ffmpeg đã bọc sẵn (h264_nvenc / hevc_nvenc) — đỡ phải kéo cả Video Codec
// SDK vào và dễ đổi codec khi máy không có NVIDIA.
//
// Giữ constant frame rate giống hệt bản Mac: frame nào thiếu thì chèn lại frame
// trước cho đủ chỗ, thà lặp một hình còn hơn để video trôi khỏi nhạc.

#pragma once
#include "frame_pipeline.h"
#include <string>
#include <vector>
#include <cstdio>

namespace tdrec {

class FFmpegSink : public FrameSink {
public:
    struct Options {
        std::string ffmpegPath = "ffmpeg";
        std::string output     = "out.mov";
        std::string codec      = "hevc_nvenc";  // hoặc h264_nvenc, prores_ks, dnxhd…
        std::string preset     = "p5";          // NVENC: p1 nhanh nhất … p7 chất nhất
        std::string extraArgs;                  // cờ thêm, cách nhau bằng khoảng trắng
        int  width  = 0;
        int  height = 0;
        int  fps    = 60;
        int  cqLevel = 18;                      // càng nhỏ càng đẹp (NVENC)
        bool tenBit  = false;
    };

    struct Stats {
        uint64_t written    = 0;   // frame thực sự đẩy vào ffmpeg
        uint64_t duplicated = 0;   // frame chèn bù giữ nhịp
        uint64_t rejected   = 0;   // frame đến trễ/trùng
        bool     broken     = false;
        bool     sizeMismatch = false;  // co frame sai kich thuoc bi chan
    };

    ~FFmpegSink() override;

    bool Open(const Options& opt, std::string* error);
    void Append(const uint8_t* bgra, size_t bytesPerRow,
                int width, int height, int64_t index) override;
    bool Close(std::string* error);

    const Stats& stats() const { return stats_; }
    double duration() const { return double(nextIndex_) / opt_.fps; }

    // Dòng lệnh ffmpeg sẽ chạy — in ra để người dùng tự chẩn đoán được.
    std::string CommandLine() const;

private:
    bool WriteFrame(const uint8_t* bgra, size_t bytesPerRow, int width, int height);

    Options              opt_;
    Stats                stats_;
    std::FILE*           pipe_ = nullptr;
    int64_t              nextIndex_ = 0;
    std::vector<uint8_t> lastFrame_;   // để chèn bù, lưu dạng packed BGRA
    size_t               frameBytes_ = 0;

    // Trần số frame chèn bù cho một lỗ hổng. Nếu TD treo vài giây ta không
    // muốn ghi hàng nghìn frame lặp — nhảy thẳng tới vị trí mới.
    static constexpr int kMaxGapFill = 240;
};

}  // namespace tdrec
