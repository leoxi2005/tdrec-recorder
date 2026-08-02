#include "frame_pipeline.h"
#include "watermark.h"
#include <cmath>
#include <algorithm>

namespace tdrec {

void FramePipeline::Begin() {
    started_        = false;
    startTime_      = 0.0;
    lastAssigned_   = -1;
    haveLastTD_     = false;
    counterChanged_ = false;
    sameCounterRun_ = 0;
    status_.counterStuck     = false;
    status_.tdFramesRendered = 0;
    status_.framesSubmitted  = 0;
    status_.framesDropped    = 0;
}

void FramePipeline::Submit(uint8_t* bgra, size_t bytesPerRow,
                           int width, int height, double timeSeconds) {
    status_.framesSubmitted++;

    // ── Đọc watermark (nếu có) ──
    bool haveTD = false;
    uint32_t td = 0;

    if (cfg_.useWatermark) {
        // Lần đầu dò cả hai đầu ảnh vì Spout/DirectX có thể lật dọc tuỳ nguồn,
        // sau đó khoá lại để khỏi dò mỗi frame.
        if (originLocked_) {
            haveTD = Watermark::Decode(bgra, bytesPerRow, width, height,
                                       cfg_.blockSize, origin_, &td);
        } else {
            for (auto cand : {Watermark::Origin::Top, Watermark::Origin::Bottom}) {
                if (Watermark::Decode(bgra, bytesPerRow, width, height,
                                      cfg_.blockSize, cand, &td)) {
                    origin_ = cand;
                    originLocked_ = true;
                    haveTD = true;
                    status_.watermarkLocked = true;
                    break;
                }
            }
        }

        if (haveTD && cfg_.eraseWatermark) {
            Watermark::Erase(bgra, bytesPerRow, width, height, cfg_.blockSize, origin_);
        }
    }

    if (!sink_) return;

    // ── Bỏ frame Spout phát lại y hệt ──
    // Chỉ áp dụng khi bộ đếm thực sự có thay đổi. Nếu nó đứng yên thì đó là
    // lỗi cấu hình uFrame; bỏ theo watermark lúc đó sẽ nuốt sạch mọi frame.
    if (haveTD) {
        if (haveLastTD_) {
            if (td == lastTD_) {
                sameCounterRun_++;
                if (sameCounterRun_ > 30 && !counterChanged_) status_.counterStuck = true;
                if (counterChanged_) { status_.framesDropped++; return; }
            } else {
                counterChanged_ = true;
                sameCounterRun_ = 0;
                status_.counterStuck = false;
                status_.tdFramesRendered++;
            }
        }
        lastTD_ = td;
        haveLastTD_ = true;
    }

    // ── Gán vị trí theo đồng hồ thực ──
    if (!started_) { startTime_ = timeSeconds; started_ = true; }
    const double elapsed = timeSeconds - startTime_;
    int64_t index = static_cast<int64_t>(std::llround(elapsed * cfg_.fps));
    if (index < 0) index = 0;

    // Chống va chạm do jitter: hai frame đến sát nhau có thể làm tròn về cùng
    // một ô. Vứt frame sau đi thì lại phải chèn hình lặp vào ô kế — vừa mất
    // frame thật vừa kém mượt. Đẩy sang ô kế tiếp giữ được cả hai.
    if (index <= lastAssigned_) {
        const int64_t pushed = lastAssigned_ + 1;
        // Nhưng KHÔNG đẩy vô hạn: nếu nguồn thật sự nhanh hơn nhịp ghi (TD
        // 60fps mà ghi 30fps) thì đẩy mãi sẽ làm video dài ra và trôi khỏi nhạc.
        if (pushed > index + 2) { status_.framesDropped++; return; }
        index = pushed;
    }
    lastAssigned_ = index;

    sink_->Append(bgra, bytesPerRow, width, height, index);
}

}  // namespace tdrec
