#include "ffmpeg_sink.h"
#include <cstring>
#include <sstream>

#ifdef _WIN32
  #include <io.h>
  #define TDREC_POPEN  _popen
  #define TDREC_PCLOSE _pclose
  #define TDREC_PIPE_MODE "wb"
#else
  #define TDREC_POPEN  popen
  #define TDREC_PCLOSE pclose
  #define TDREC_PIPE_MODE "w"
#endif

namespace tdrec {

FFmpegSink::~FFmpegSink() {
    if (pipe_) { TDREC_PCLOSE(pipe_); pipe_ = nullptr; }
}

std::string FFmpegSink::CommandLine() const {
    std::ostringstream c;
    // Trích dẫn đường dẫn để chịu được khoảng trắng (rất hay gặp trên Windows).
    c << "\"" << opt_.ffmpegPath << "\""
      << " -hide_banner -loglevel error -y"
      << " -f rawvideo -pix_fmt bgra"
      << " -s " << opt_.width << "x" << opt_.height
      << " -r " << opt_.fps
      << " -i -"
      << " -c:v " << opt_.codec;

    const bool isNvenc = opt_.codec.find("nvenc") != std::string::npos;
    if (isNvenc) {
        // rc=constqp + cq cho chất lượng ổn định, không phụ thuộc bitrate mục tiêu.
        c << " -preset " << opt_.preset
          << " -rc constqp -qp " << opt_.cqLevel
          << " -pix_fmt " << (opt_.tenBit ? "p010le" : "yuv420p");
    } else if (opt_.codec == "prores_ks") {
        // ProRes trên Windows chỉ có encoder CPU — chậm, chỉ dùng khi bắt buộc.
        c << " -profile:v 3 -pix_fmt yuv422p10le";
    }

    // Gắn thẻ màu Rec.709 để Resolve/Premiere diễn giải giống bản Mac.
    c << " -colorspace bt709 -color_primaries bt709 -color_trc bt709";

    if (!opt_.extraArgs.empty()) c << " " << opt_.extraArgs;
    c << " \"" << opt_.output << "\"";
    return c.str();
}

bool FFmpegSink::Open(const Options& opt, std::string* error) {
    opt_ = opt;
    if (opt_.width <= 0 || opt_.height <= 0) {
        if (error) *error = "Kích thước ảnh không hợp lệ.";
        return false;
    }
    // H.264/HEVC yêu cầu cạnh chẵn.
    if (opt_.width % 2 || opt_.height % 2) {
        if (error) *error = "Độ phân giải có cạnh lẻ — codec yêu cầu cạnh chẵn.";
        return false;
    }

    frameBytes_ = size_t(opt_.width) * opt_.height * 4;
    lastFrame_.clear();
    nextIndex_ = 0;
    stats_ = Stats{};

    const std::string cmd = CommandLine();
    pipe_ = TDREC_POPEN(cmd.c_str(), TDREC_PIPE_MODE);
    if (!pipe_) {
        if (error) *error = "Không chạy được ffmpeg. Lệnh: " + cmd;
        return false;
    }
    return true;
}

bool FFmpegSink::WriteFrame(const uint8_t* bgra, size_t bytesPerRow,
                            int width, int height) {
    if (!pipe_ || stats_.broken) return false;

    const size_t rowBytes = size_t(width) * 4;
    // Buffer nguồn có thể có padding cuối hàng (stride > width*4), ffmpeg thì
    // đợi dữ liệu liền mạch — nên ghi từng hàng thay vì cả khối.
    if (bytesPerRow == rowBytes) {
        if (std::fwrite(bgra, 1, rowBytes * height, pipe_) != rowBytes * size_t(height)) {
            stats_.broken = true; return false;
        }
    } else {
        for (int y = 0; y < height; ++y) {
            if (std::fwrite(bgra + size_t(y) * bytesPerRow, 1, rowBytes, pipe_) != rowBytes) {
                stats_.broken = true; return false;
            }
        }
    }
    return true;
}

void FFmpegSink::Append(const uint8_t* bgra, size_t bytesPerRow,
                        int width, int height, int64_t index) {
    if (!pipe_ || stats_.broken) return;

    // ffmpeg da duoc mo voi mot kich thuoc co dinh. Frame khac kich thuoc se
    // lam hong toan bo video, va con tran bo dem lastFrame_ khi chen bu.
    // Chan tai day thay vi tin ben goi.
    if (width != opt_.width || height != opt_.height) {
        stats_.rejected++;
        stats_.sizeMismatch = true;
        return;
    }

    // Frame đến trễ hoặc trùng ô đã ghi → bỏ.
    if (index < nextIndex_) { stats_.rejected++; return; }

    // Lấp lỗ hổng bằng frame gần nhất để giữ constant frame rate.
    if (index > nextIndex_ && !lastFrame_.empty()) {
        const int64_t gap = index - nextIndex_;
        const int64_t fill = gap < kMaxGapFill ? gap : kMaxGapFill;
        for (int64_t i = 0; i < fill; ++i) {
            if (!WriteFrame(lastFrame_.data(), size_t(width) * 4, width, height)) return;
            nextIndex_++;
            stats_.duplicated++;
            stats_.written++;
        }
        // Lỗ hổng quá lớn = TD đã treo hoặc bị dừng; nhảy thẳng tới vị trí mới
        // thay vì ghi hàng nghìn frame lặp.
        if (gap > kMaxGapFill) nextIndex_ = index;
    }

    if (!WriteFrame(bgra, bytesPerRow, width, height)) return;
    nextIndex_++;
    stats_.written++;

    // Giữ bản sao packed để chèn bù lần sau.
    if (lastFrame_.size() != frameBytes_) lastFrame_.resize(frameBytes_);
    const size_t rowBytes = size_t(width) * 4;
    for (int y = 0; y < height; ++y) {
        std::memcpy(lastFrame_.data() + size_t(y) * rowBytes,
                    bgra + size_t(y) * bytesPerRow, rowBytes);
    }
}

bool FFmpegSink::Close(std::string* error) {
    if (!pipe_) return true;
    const int rc = TDREC_PCLOSE(pipe_);
    pipe_ = nullptr;
    if (rc != 0) {
        if (error) *error = "ffmpeg thoát với mã " + std::to_string(rc);
        return false;
    }
    return !stats_.broken;
}

}  // namespace tdrec
