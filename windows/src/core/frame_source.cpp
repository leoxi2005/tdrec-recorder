#include "frame_source.h"
#include "watermark.h"

#include <chrono>
#include <cmath>
#include <cstring>

namespace tdrec {

namespace {
double NowSeconds() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}
}  // namespace

MockSource::MockSource(const Options& o) : o_(o) {
    buf_.assign(size_t(o_.width) * size_t(o_.height) * 4, 0);
    t0_ = NowSeconds();
}

bool MockSource::Receive() {
    // Chỉ "phát" frame khi đã tới nhịp — mô phỏng đúng cách Spout chỉ publish
    // sau mỗi lần nguồn render xong, chứ không phải liên tục.
    const double elapsed = NowSeconds() - t0_;
    const uint64_t due = uint64_t(elapsed * o_.fps);
    if (due <= produced_) return false;

    produced_++;

    // Nền đổi màu theo frame để mỗi frame khác nhau rõ rệt — nếu encoder ghi
    // nhầm frame lặp thì nhìn file sẽ thấy ngay.
    const uint8_t v = uint8_t(produced_ % 200 + 20);
    std::memset(buf_.data(), v, buf_.size());

    if (o_.watermark) {
        const uint32_t n = o_.stuckCounter ? 777u : frameNo_;
        Watermark::Encode(buf_.data(), stride(), o_.width, o_.height,
                          o_.blockSize, Watermark::Origin::Top, n);
    }
    frameNo_++;
    return true;
}

}  // namespace tdrec
