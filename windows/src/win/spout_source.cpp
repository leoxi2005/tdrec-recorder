#include "spout_source.h"

#include <SpoutDX.h>
#include <cstring>

namespace tdrec {

namespace {
inline spoutDX* R(void* p) { return static_cast<spoutDX*>(p); }
}  // namespace

SpoutSource::SpoutSource() { receiver_ = new spoutDX(); }

SpoutSource::~SpoutSource() {
    Close();
    delete R(receiver_);
    receiver_ = nullptr;
}

std::vector<std::string> SpoutSource::ListSenders() {
    std::vector<std::string> out;
    spoutDX probe;
    const int n = probe.GetSenderCount();
    for (int i = 0; i < n; ++i) {
        char name[256] = {0};
        if (probe.GetSender(i, name, sizeof(name))) out.emplace_back(name);
    }
    return out;
}

bool SpoutSource::Open(const std::string& senderName, std::string* error) {
    if (!R(receiver_)->OpenDirectX11()) {
        if (error) *error =
            "Không mở được DirectX 11. Kiểm tra driver GPU đã cài đúng chưa.";
        return false;
    }
    // Tên rỗng = bám vào sender đang active.
    if (!senderName.empty())
        R(receiver_)->SetReceiverName(senderName.c_str());
    return true;
}

void SpoutSource::Close() {
    if (receiver_) R(receiver_)->ReleaseReceiver();
}

bool SpoutSource::Receive() {
    sizeChanged_ = false;

    // ReceiveImage đọc thẳng về CPU. Truyền buffer hiện tại; nếu sender đổi
    // kích thước, Spout báo qua IsUpdated() và ta cấp lại buffer rồi thử lại
    // ở frame sau.
    const bool got = R(receiver_)->ReceiveImage(
        buffer_.empty() ? nullptr : buffer_.data(),
        static_cast<unsigned int>(width_),
        static_cast<unsigned int>(height_),
        false,      // bRGB = false -> 4 kênh
        flip_);     // lật dọc nếu video ra bị lộn ngược

    if (R(receiver_)->IsUpdated()) {
        width_  = static_cast<int>(R(receiver_)->GetSenderWidth());
        height_ = static_cast<int>(R(receiver_)->GetSenderHeight());
        buffer_.assign(size_t(width_) * size_t(height_) * 4, 0);
        sizeChanged_ = true;
        return false;   // frame này chưa hợp lệ, đợi frame sau
    }

    if (!got || width_ <= 0 || height_ <= 0 || buffer_.empty()) return false;

    // Spout chỉ báo frame mới khi sender thực sự publish. Bỏ frame lặp ngay
    // tại đây để không tốn công giải mã watermark và ghi lại.
    if (!R(receiver_)->IsFrameNew()) return false;

    if (swapRB_) SwapRB();
    return true;
}

void SpoutSource::SwapRB() {
    // Đảo kênh R và B tại chỗ. Chỉ dùng khi màu ra sai — thứ tự kênh của Spout
    // phụ thuộc format mà sender chọn, không phải lúc nào cũng BGRA.
    uint8_t* p = buffer_.data();
    const size_t n = buffer_.size();
    for (size_t i = 0; i + 3 < n; i += 4) {
        const uint8_t t = p[i];
        p[i] = p[i + 2];
        p[i + 2] = t;
    }
}

std::string SpoutSource::name() const {
    return R(receiver_)->GetSenderName();
}

long SpoutSource::senderFrame() const {
    return R(receiver_)->GetSenderFrame();
}

double SpoutSource::sourceFps() const {
    return R(receiver_)->GetSenderFps();
}

}  // namespace tdrec
