# HANDOFF — TDRec

> Tài liệu bàn giao. Mở phiên làm việc mới thì đọc file này trước, đủ để tiếp tục mà không cần kể lại lịch sử.
>
> Cập nhật: 2026-08-02 · phiên bản v1.0.0

---

## 1. Vấn đề đang giải

`Movie File Out TOP` của TouchDesigner encode ngay trong tiến trình render. Ở độ phân giải wall (10350×1080 hoặc 10990×1080) nó **kéo tụt FPS và rớt frame** → video mất đồng bộ với nhạc.

TDRec tách khâu encode ra process riêng. TouchDesigner chỉ chia sẻ texture qua Syphon (macOS) / Spout (Windows), gần như không tốn tài nguyên.

```
TouchDesigner ──Syphon/Spout──▶ TDRec (process riêng)
                                  │ đọc watermark đếm frame (tuỳ chọn)
                                  │ gán vị trí frame theo ĐỒNG HỒ THỰC
                                  │ chèn bù frame thiếu để giữ CFR
                                  └─▶ encoder phần cứng ──▶ file
```

---

## 2. Trạng thái hiện tại

| | |
|---|---|
| Repo | https://github.com/leoxi2005/tdrec-recorder — **công khai** |
| Bản phát hành | v1.0.0 — `TDRec-macOS.zip` (927 KB), `TDRec-Windows.zip` (90 KB) |
| CI | GitHub Actions build cả 2 nền tảng, chạy test, tự tạo release khi push tag `v*` |
| macOS | ✅ **đã chạy thật với TouchDesigner** |
| Windows | ⚠️ build + test đạt trên CI, **chưa ai chạy với TouchDesigner thật** |

**Thư mục:** `~/tdrec-recorder` là nguồn chuẩn. `~/tdrec` và `~/tdrec-win` là bản gốc còn sót lại — đừng sửa song song kẻo lệch.

---

## 3. Bốn quyết định thiết kế cốt lõi — ĐỪNG vô tình phá

### 3.1. Vị trí frame tính theo ĐỒNG HỒ THỰC, không theo `absTime.frame`

Đây là quyết định quan trọng nhất, và bản đầu tiên đã làm **sai**.

`absTime.frame` tăng 1 mỗi lần TD render xong, **không phải mỗi 1/60 giây**. Nếu TD chỉ chạy 34fps thì 1 giây thực nó chỉ tăng 34 — đặt 34 frame đó lên trục 60fps sẽ ra 0.57 giây video. Đo thực tế: 10 giây thực bị nén thành 5.67 giây, **lệch 4.3 giây**.

Dùng đồng hồ thực thì mỗi frame nằm đúng chỗ nó xuất hiện, chỗ trống được chèn bù. Sau khi sửa: lệch **−17 ms** trên 10 giây.

*(`FramePipeline.swift` / `frame_pipeline.cpp`)*

### 3.2. Watermark cần chuỗi nhận dạng 0xB4

Watermark nhúng số frame vào 40 block ở góc trên-trái. Bản đầu chỉ có counter + checksum → **vùng ảnh đen tuyền giải mã thành counter 0 với checksum 0, hợp lệ về mặt toán học**, app tưởng có watermark đứng yên rồi bỏ sạch frame. Vùng trắng tuyền cũng vậy.

8 bit đầu giờ là chuỗi cố định `0xB4` (xen kẽ sáng-tối) nên vùng màu phẳng không thể tạo ra được. Có 12 phép thử khoá lại điều này.

Layout: `bit 0-7` magic · `bit 8-31` số frame · `bit 32-39` checksum.
**Phải khớp từng bit** giữa `Watermark.swift`, `watermark.cpp`, và `tdrec_watermark.frag`.

### 3.3. Frame chạy trên serial queue riêng, KHÔNG dùng main actor

60 frame/giây qua main thread vừa làm giật UI, vừa **không đảm bảo thứ tự** — mà sai thứ tự frame là hỏng video.

### 3.4. Pool buffer có trần cứng, không bao giờ chặn nguồn

Khi đĩa/encoder tụt, app **bỏ frame chứ tuyệt đối không chờ**. Chờ ở đó là block thread Syphon → kéo tụt chính TouchDesigner, đúng thứ đang muốn tránh. Dùng `kCVPixelBufferPoolAllocationThresholdKey`; không có nó thì RAM phình dần tới khi máy đứng.

---

## 4. Bẫy đã sập — đừng để tái diễn

| Bẫy | Triệu chứng | Cách chặn |
|---|---|---|
| `disconnect()` không xoá `poolWidth/poolHeight` | Lần đầu ghi được, ngắt rồi nối lại thì nút ghi từ chối | `--reconnecttest` |
| Watermark thiếu chuỗi nhận dạng | Báo "watermark đứng yên" dù project không hề có watermark | `--decodetest` |
| Gán vị trí frame theo `absTime.frame` | Video ngắn hơn thực tế, trôi khỏi nhạc | test lõi #2, #3 |
| `SizeChanged()` lồng trong `if (Receive())` | Code chết — đổi res giữa chừng làm hỏng video mà không báo | lưới an toàn trong `FFmpegSink::Append` |
| **`cmd.exe` cắt dấu nháy đầu+cuối** | ffmpeg không ghi được frame nào trên Windows → app vô dụng | test đầu-cuối trên CI |
| `swiftLanguageModes` đặt trước `targets` | Package.swift không parse được | build local |

Hai lỗi cuối chỉ lộ ra khi CI build bằng MSVC thật — cross-compile mingw trên Mac **không** phát hiện được.

---

## 5. Đã kiểm chứng gì

**macOS** (M4 Max, đo thật):

| | |
|---|---|
| 10990×1080 @60fps ProRes 4444, 10s | 600 phát → 600 ghi, 0 mất |
| Constant frame rate (ffprobe) | 600/600 đúng nhịp, 0 sai lệch |
| Nguồn 34fps → ghi 60fps, 10s | 9.983 s (lệch −17 ms) |
| Chạy thật với TouchDesigner | ✅ 518 frame, 0 bù, 0 bỏ |

**Windows** (CI, MSVC + ffmpeg thật): 43/43 test lõi đạt, `tdrec.exe` build và chạy được.

**Chưa kiểm chứng:** `SpoutSource` nhận frame thật từ TD · thứ tự kênh màu (cờ `--swap-rb`) · chiều dọc ảnh (cờ `--flip`) · hiệu năng ở res wall.

---

## 6. Việc tiếp theo

### Ưu tiên 1 — Xác minh Windows *(người dùng chủ yếu dùng Windows)*

Chỉ cần một lệnh, không đụng ffmpeg nên loại trừ được một nguồn lỗi:

```bat
tdrec.exe --probe --sender RECORD
```

Nếu ra độ phân giải và FPS hợp lý là coi như xong 95%. Nếu màu sai → `--swap-rb`; ảnh lộn ngược → `--flip`.

### Ưu tiên 2 — Hiệu năng Windows ở res wall

Bản Windows đọc frame từ GPU về CPU. Mã nguồn Spout ghi chú khâu này tốn "2.5–3.5 ms ở 1920×1080". Ở 10350×1080 (5.4× số pixel) → ước tính **13.5–19 ms/frame**:

| Nhịp ghi | Ngân sách | Kết luận |
|---|---|---|
| 30 fps | 33 ms | thoải mái |
| 60 fps | 16.7 ms | **sát trần** |

Nếu `--probe` cho FPS thấp hơn TD thì chính là khâu này. Hướng xử lý: đưa thẳng texture DirectX vào NVENC, bỏ hẳn việc đọc về CPU (phức tạp hơn nhiều).

### Ưu tiên 3 — Giao diện cho Windows

Cố ý chưa làm, để bề mặt nhỏ nhất cho lần debug đầu. Làm sau khi nhân chạy ổn.

---

## 7. Lệnh hay dùng

```bash
# macOS — thư mục macos/
swift build -c release
./build.sh install                    # build + đóng gói + cài vào /Applications
./build.sh test 10990 1080 10         # self-test đầu-cuối, KHÔNG cần mở TouchDesigner

./.build/release/TDRec --decodetest       # 12 phép thử bộ giải mã watermark
./.build/release/TDRec --reconnecttest    # chu trình nối → ngắt → nối lại
./.build/release/TDRec --servers          # TD có đang phát Syphon không

# Windows — thư mục windows/
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release
build\Release\tdrec_core_test.exe          # 43 phép thử phần lõi
build\Release\tdrec.exe --senders
build\Release\tdrec.exe --probe --sender RECORD

# Chạy vòng lặp ghi bằng nguồn giả lập — chạy được trên MỌI hệ điều hành
./build/tdrec --record --mock --width 10350 --height 1080 --fps 30 \
              --seconds 8 --codec libx264 --out test.mov

# Phát hành bản mới
git tag v1.0.1 && git push origin v1.0.1     # CI tự build + tạo release
```

---

## 8. Bối cảnh người dùng

- **Máy:** MacBook Pro M4 Max, 36 GB, macOS 26.5 — nhưng **chủ yếu dùng Windows để chạy TouchDesigner**
- **Show:** VJ / mapping, tường 10350×1080 và 10990×1080
- **TouchDesigner** đặt 30fps trong project `Floating Particles.4.toe`
- Chain TOP chạy **8-bit** → Syphon truyền bit-exact, không mất chất lượng
- Ghi ra ProRes 422 HQ là mặc định hợp lý trên Mac

**Lưu ý dung lượng:** ProRes 422 HQ ở res wall ăn ~9.3 GB/phút. Ổ trong còn ~350 GB → khoảng 37 phút. Show dài nên cắm NVMe ngoài.

---

## 9. Thiết lập trong TouchDesigner

1. Thêm **Syphon Spout Out TOP** vào cuối chain, đặt **Sender Name**, bật **Active**
   *(TOP chỉ phát khi nó COOK — không cook thì lặng lẽ ngừng phát, đây là bẫy hay gặp)*
2. *(tuỳ chọn)* Gắn `tdrec_watermark.frag` vào một GLSL TOP đặt giữa chain và Syphon Out, với uniform:
   - `uFrame` = `absTime.frame` **dạng expression**, không phải số cố định
   - `uBlock` = `2`, phải khớp "Block size" trong app

Watermark **không bắt buộc** — video vẫn đúng thời lượng khi không có. Nó chỉ thêm việc loại frame trùng và cho biết TD render được bao nhiêu frame.

---

## 10. Giới hạn đã biết

- **Syphon trên macOS chỉ truyền 8-bit RGBA** (doc Derivative nói rõ). Chain 16-bit float sẽ bị ép xuống 8-bit ngay tại Syphon — giới hạn của Syphon, không phải của app.
- Windows **không có encoder ProRes phần cứng** → dùng NVENC HEVC/H.264.
- ProRes và H.264/HEVC đều yêu cầu **cạnh chẵn**. App chặn sớm và báo rõ.
- Bộ đếm watermark 24-bit → tràn sau ~77 giờ chạy liên tục ở 60fps (app xử lý được).
- macOS chặn app lần đầu vì chưa ký bằng tài khoản Apple Developer → chuột phải → Open → Open.
