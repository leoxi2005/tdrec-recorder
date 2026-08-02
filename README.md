# TDRec

Ghi hình từ TouchDesigner ra file chất lượng cao **mà không kéo tụt FPS** và **không rớt frame**.

TouchDesigner chỉ chia sẻ texture qua Syphon (macOS) / Spout (Windows) — gần như không tốn tài nguyên. Toàn bộ việc encode chạy ở process riêng bằng encoder phần cứng.

> 📄 **[HANDOFF.md](HANDOFF.md)** — trạng thái dự án, quyết định thiết kế, việc còn lại. Đọc file này trước khi tiếp tục phát triển.

## Tải về

Vào tab **Releases** ở trên, tải file cho hệ của bạn:

| | File | Yêu cầu |
|---|---|---|
| **macOS** | `TDRec-macOS.zip` | macOS 13+, Apple Silicon |
| **Windows** | `TDRec-Windows.zip` | Windows 10/11 x64, GPU NVIDIA, có ffmpeg trong PATH |

### macOS
Giải nén, kéo `TDRec.app` vào Applications. Lần đầu mở, macOS sẽ chặn vì app chưa ký bằng tài khoản Apple Developer — chuột phải vào app → **Open** → **Open** lần nữa.

### Windows
Giải nén ra một thư mục. Chạy `tdrec.exe --help` để xem hướng dẫn. Cần cài [ffmpeg có NVENC](https://www.gyan.dev/ffmpeg/builds/) và đặt vào PATH.

## Vì sao cần app này

`Movie File Out TOP` của TouchDesigner encode ngay trong tiến trình render, nên ở độ phân giải lớn nó kéo tụt FPS và làm video rớt frame — mất đồng bộ với nhạc.

TDRec tách hẳn khâu encode ra:

```
TouchDesigner ──Syphon/Spout──▶ TDRec (process riêng)
                                  │ đọc watermark đếm frame
                                  │ gán vị trí theo đồng hồ thực
                                  └─▶ encoder phần cứng ──▶ file
```

Điểm mấu chốt: vị trí mỗi frame trên trục thời gian được tính bằng **đồng hồ thực**, không phải số đếm frame của TD. Nhờ vậy video luôn đúng thời lượng và khớp nhạc, kể cả khi TD không chạy đủ FPS mục tiêu — chỗ trống được chèn bù để giữ constant frame rate.

## Số liệu đã đo

Trên MacBook Pro M4 Max:

| Bài đo | Kết quả |
|---|---|
| 10990×1080 @60fps, ProRes 4444, 10s | 600 phát → **600 ghi**, 0 mất |
| Constant frame rate (ffprobe) | 600/600 đúng nhịp, **0 sai lệch** |
| Nguồn 34fps → ghi 60fps, 10 giây thực | 9.983 s video (lệch **−17 ms**) |
| Nguồn 20fps → ghi 60fps, 8 giây thực | 7.967 s video (lệch **−33 ms**) |

## Thiết lập trong TouchDesigner

1. Thêm **Syphon Spout Out TOP** vào cuối chain, đặt **Sender Name**, bật **Active**
2. *(tuỳ chọn)* Gắn `tdrec_watermark.frag` vào một GLSL TOP giữa chain và Syphon/Spout Out, với uniform `uFrame = absTime.frame` (dạng expression) và `uBlock = 2`

Watermark không bắt buộc — video vẫn đúng thời lượng khi không có. Nó chỉ thêm việc loại frame trùng và cho biết TD render được bao nhiêu frame.

Chi tiết: [macos/README.md](macos/README.md) · [windows/README.md](windows/README.md)

## Khác biệt giữa hai bản

| | macOS | Windows |
|---|---|---|
| Truyền hình | Syphon (trần 8-bit RGBA) | Spout |
| Encoder | ProRes phần cứng | NVENC HEVC/H.264 |
| Đường dữ liệu | GPU→GPU, zero-copy | GPU→CPU→ffmpeg |
| Giao diện | Có | Dòng lệnh |

Bản Windows đọc frame về CPU nên ở 10350×1080 khâu này tốn ~13,5–19 ms/frame: 30fps thoải mái, **60fps sát trần**. Chạy `--probe` trước để đo.

## Giấy phép

Mã của TDRec: MIT.
Có kèm [Syphon.framework](https://github.com/Syphon/Syphon-Framework) (BSD 2-Clause) và tự tải [Spout2](https://github.com/leadedge/Spout2) (BSD 2-Clause) lúc build.
