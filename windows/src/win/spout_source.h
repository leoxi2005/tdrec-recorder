// spout_source.h — nhận frame từ TouchDesigner qua Spout (chỉ Windows).
//
// Đây là lớp DUY NHẤT phụ thuộc Windows. Mọi logic quan trọng (watermark, gán
// vị trí frame, giữ constant frame rate) nằm ở src/core và đã được kiểm chứng
// trên máy khác — nếu có lỗi, khả năng cao nằm trong file này.
//
// Dùng SpoutDX thay vì tự viết DirectX11: SpoutDX đã lo sẵn việc mở shared
// texture, đọc về CPU, và phát hiện frame mới. Tự viết lại phần đó chỉ tăng
// rủi ro mà không nhanh hơn đáng kể ở mức phân giải này.

#pragma once
#include "core/frame_source.h"

#include <string>
#include <vector>
#include <cstdint>

namespace tdrec {

class SpoutSource : public IFrameSource {
public:
    SpoutSource();
    ~SpoutSource();

    // Liệt kê mọi Spout sender đang phát.
    static std::vector<std::string> ListSenders();

    // Mở DirectX và bám vào một sender. Tên rỗng = lấy sender đang active.
    bool Open(const std::string& senderName, std::string* error);
    void Close();

    // Lấy frame mới. Trả false nếu chưa có frame mới (KHÔNG phải lỗi —
    // Spout chỉ publish khi nguồn render xong).
    //
    // Khi trả true, pixels() chứa ảnh BGRA liền mạch, stride = width()*4.
    bool Receive() override;

    // Kích thước có thể đổi giữa chừng nếu người dùng chỉnh res trong TD.
    bool SizeChanged() const override { return sizeChanged_; }

    uint8_t*    pixels()       override { return buffer_.data(); }
    int         width()  const override { return width_; }
    int         height() const override { return height_; }
    size_t      stride() const override { return size_t(width_) * 4; }
    std::string name()   const override;
    double      sourceFps() const override;

    // Số frame mà chính Spout đếm được từ phía sender — dùng để đối chiếu với
    // watermark khi chẩn đoán.
    long        senderFrame() const;

    // Nếu màu ra sai (đỏ và xanh dương đảo nhau), bật cờ này.
    void SetSwapRedBlue(bool v) { swapRB_ = v; }

    // Nếu video ra bị lộn ngược, bật cờ này. Chiều dọc của buffer phụ thuộc
    // cách sender ghi texture, chưa kiểm chứng được nếu không có TD thật.
    void SetFlipVertical(bool v) { flip_ = v; }

private:
    void SwapRB();

    void*                receiver_ = nullptr;   // spoutDX*, giấu để header không kéo Spout vào
    std::vector<uint8_t> buffer_;
    int                  width_  = 0;
    int                  height_ = 0;
    bool                 sizeChanged_ = false;
    bool                 swapRB_ = false;
    bool                 flip_   = false;
};

}  // namespace tdrec
