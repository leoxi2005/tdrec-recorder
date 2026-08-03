# TDRec cho Windows

Ghi hình từ TouchDesigner ra video mà **không kéo tụt FPS của TD** và **không rớt frame** — cùng nguyên lý với bản macOS, nhưng dùng **Spout + NVENC** thay cho Syphon + ProRes.

---

## ▶ Bắt đầu ở đây — bấm đúp `tdrec.exe`

**Ba bước, làm đúng thứ tự:**

1. **Chuột phải file `TDRec-Windows.zip` → Properties → tick `Unblock` → OK.**
   File tải từ mạng bị Windows đánh dấu, không bỏ dấu này thì SmartScreen chặn không cho chạy.
2. **Chuột phải → `Extract All...`** ra một thư mục thật.
   Bấm đúp *bên trong* file .zip thì Windows chỉ bung tạm ra thư mục rác rồi xoá — video ghi ra sẽ mất. App có bắt trường hợp này và báo, nhưng cứ giải nén cho đúng là hơn.
3. **Bấm đúp `tdrec.exe`** trong thư mục vừa giải nén → hiện menu → chọn **[2] Kiểm tra đường Spout** trước tiên.

Nếu hiện bảng xanh *"Windows protected your PC"*: bấm **More info → Run anyway**. App chưa ký số nên Windows cảnh báo mọi lần đầu.

**Không cần cài Visual C++ Redistributable** — runtime đã nhúng thẳng vào exe.

**Cần ffmpeg trong PATH** thì mới *ghi* được (mục [3]). Mục [1] và [2] không cần:
```
winget install Gyan.FFmpeg
```
Cài xong phải **mở lại** `tdrec.exe` thì PATH mới cập nhật.

> **Vì sao phải có menu:** `tdrec.exe` vốn là công cụ dòng lệnh. Bấm đúp một công cụ dòng lệnh thì Windows mở cửa sổ đen, chạy xong là **đóng ngay** — nhìn y hệt "app không mở được". Nên từ v1.0.2 exe tự nhận biết mình được bấm đúp (đếm process gắn vào console) và hiện menu, giữ cửa sổ lại. Gọi từ cmd/PowerShell thì hành vi vẫn y như cũ, script không bị ảnh hưởng.

Phần còn lại của tài liệu này dành cho người muốn build từ mã nguồn hoặc chạy trực tiếp bằng dòng lệnh.

---

## Trạng thái kiểm chứng

Code viết trên máy macOS. Không chạy được với TouchDesigner thật ở đây, nhưng đã kiểm chứng được khá nhiều:

| Đã kiểm chứng | Cách làm |
|---|---|
| ✅ 43/43 test phần lõi | chạy thật trên macOS, gồm test đầu-cuối qua ffmpeg + ffprobe đếm lại frame |
| ✅ Toàn bộ vòng lặp ghi | `--record --mock` ở 10350×1080@60 → 482 frame, lệch **+25 ms** |
| ✅ Nguồn chậm hơn nhịp ghi | mock 30fps → ghi 60fps, 8 giây thực → 7.950 s video (lệch −50 ms) |
| ✅ 13/13 lệnh gọi SpoutDX | đối chiếu từng chữ ký với `SpoutDX.h` thật, và đọc cài đặt `ReceiveImage`/`IsFrameNew` để xác nhận đúng ngữ nghĩa |
| ✅ Biên dịch được sang Windows | cross-compile bằng mingw-w64 → ra file **PE32+ x86-64** thật |
| ✅ File CMakeLists | build chéo qua chính CMake, mọi target thành công |

**Chưa kiểm chứng được** (cần máy Windows + TouchDesigner):

- `SpoutSource` nhận frame thật từ TD
- Thứ tự kênh màu — Spout trả về đúng byte order của sender, mà TD dùng format nào thì phải thử mới biết. Có cờ `--swap-rb` để chỉnh
- Hiệu năng NVENC và khâu đọc frame về CPU ở độ phân giải wall

### Ba lỗi thật đã tìm ra nhờ biên dịch chéo

Đều nằm ở khâu build, MSVC cũng sẽ dính y hệt:

1. `WIN32_LEAN_AND_MEAN` loại bỏ `mmsystem.h`, mà `SpoutFrameCount` cần `timeBeginPeriod` từ đó → lỗi `TIMECAPS was not declared`
2. Thiếu liên kết `version` (cho `GetFileVersionInfo` trong `SpoutUtils`) và `winmm`
3. `SpoutCopy` dùng hàm SSE3 `_mm_shuffle_epi8` — GCC/Clang cần cờ `-mssse3`

---

## Cần cài trước

1. **Visual Studio 2022 Build Tools** (chọn *Desktop development with C++*)
2. **CMake** ≥ 3.20 — https://cmake.org/download/
3. **Git**
4. **ffmpeg** có NVENC — tải bản gyan.dev hoặc BtbN, đặt `ffmpeg.exe` vào PATH

Kiểm tra ffmpeg có NVENC chưa:
```
ffmpeg -hide_banner -encoders | findstr nvenc
```
Phải thấy `hevc_nvenc` và `h264_nvenc`.

---

## Build

```bat
cd tdrec-win
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

CMake sẽ tự tải Spout2 SDK về. Nếu bước đó hỏng vì repo Spout đổi cấu trúc, mở `CMakeLists.txt` và ghim lại một tag cụ thể ở dòng `GIT_TAG master`.

---

## Chạy theo đúng thứ tự này

Đừng nhảy thẳng vào ghi — làm tuần tự sẽ khoanh vùng lỗi nhanh hơn nhiều.

### 1. Test phần lõi (không cần TouchDesigner)

```bat
build\Release\tdrec_core_test.exe
```

Phải ra `43 dat, 0 hong`. Nếu hỏng ở đây thì là lỗi trình biên dịch hoặc build, chưa liên quan gì tới Spout.

### 2. Xem TouchDesigner có phát Spout không

```bat
build\Release\tdrec.exe --senders
```

Trong TD: thêm **Syphon Spout Out TOP**, đặt **Sender Name**, bật **Active**. Nhớ là TOP chỉ phát **khi nó cook** — TOP không cook thì lặng lẽ ngừng phát.

### 3. Thử nhận frame (chưa ghi file)

```bat
build\Release\tdrec.exe --probe --sender RECORD
```

Bước này không đụng tới ffmpeg nên loại trừ được một nguồn lỗi. Nó báo độ phân giải, FPS nhận được, và có đọc được watermark không.

**Nếu màu bị sai (đỏ và xanh dương đảo nhau)** — thêm `--swap-rb`. Thứ tự kênh của Spout phụ thuộc format mà sender chọn, mình chưa test được nên để cờ này cho bạn chỉnh.

### 4. Ghi thật

```bat
build\Release\tdrec.exe --record --sender RECORD --out D:\show.mov --fps 60
```

Dừng bằng `Ctrl+C`, hoặc thêm `--seconds 30` để tự dừng.

---

## Chọn codec trên Windows

Windows **không có encoder ProRes phần cứng** như Apple Silicon. Bảng đối chiếu:

| Codec | Cờ | Nhận xét |
|---|---|---|
| **HEVC NVENC** | `--codec hevc_nvenc` | **Mặc định.** Encode trên chip riêng của NVIDIA, gần như không tốn GPU. File nhẹ hơn ProRes rất nhiều. |
| HEVC NVENC 10-bit | `--codec hevc_nvenc --10bit` | Dải màu mượt hơn ở vùng chuyển sắc. Premiere/Resolve đọc được. |
| H.264 NVENC | `--codec h264_nvenc` | Tương thích rộng hơn, chất lượng kém HEVC một chút. |
| ProRes | `--codec prores_ks` | Encoder **CPU**, chậm. Chỉ dùng khi bắt buộc phải giao file ProRes. |

Chất lượng chỉnh bằng `--qp` (mặc định 18, càng nhỏ càng đẹp và càng nặng). `--preset p1` nhanh nhất … `p7` đẹp nhất.

---

## Điểm khác so với bản macOS

| | macOS | Windows |
|---|---|---|
| Truyền hình | Syphon (chỉ 8-bit RGBA) | Spout (hỗ trợ tới 32-bit float) |
| Encoder | ProRes phần cứng (Media Engine) | NVENC HEVC/H.264 |
| Đường dữ liệu | GPU→GPU, zero-copy | GPU→CPU→ffmpeg qua pipe |
| Giao diện | Có | Chưa — dòng lệnh trước |

**Lưu ý về hiệu năng — đọc kỹ chỗ này.**

Bản Windows phải đọc frame từ GPU về CPU rồi đẩy qua pipe. Chính mã nguồn Spout ghi chú tốc độ khâu này: *"Two textures — approx 2.5–3.5 msec at 1920x1080"*.

Ở 10350×1080 là **5.4 lần** số pixel của 1080p → ước tính **13,5–19 ms mỗi frame**, chỉ riêng khâu đọc về CPU:

| Nhịp ghi | Ngân sách/frame | Ước tính | Kết luận |
|---|---|---|---|
| 30 fps | 33 ms | 13,5–19 ms | thoải mái |
| 60 fps | 16,7 ms | 13,5–19 ms | **sát trần, có thể không kịp** |

Nên **thử `--probe` trước** — nếu FPS nhận được thấp hơn FPS của TD thì đó chính là khâu này. Hướng xử lý là đưa thẳng texture DirectX vào NVENC, bỏ hẳn việc đọc về CPU (phức tạp hơn nhiều, làm khi cần).

Đây là điểm khác biệt lớn nhất so với bản Mac: Apple Silicon dùng unified memory nên không có khâu đọc về này.

---

## Khi có lỗi, gửi mình những thứ này

1. Output đầy đủ của `tdrec_core_test.exe`
2. Output đầy đủ của `--senders` và `--probe`
3. Dòng `Lenh ffmpeg:` mà `--record` in ra
4. Thông báo lỗi build (nếu hỏng lúc build)

---

## Cấu trúc mã nguồn

```
src/core/               ── đa nền tảng, đã kiểm chứng
  watermark.{h,cpp}       giải mã / xoá / mã hoá watermark đếm frame
  frame_pipeline.{h,cpp}  gán vị trí frame theo đồng hồ thực
  ffmpeg_sink.{h,cpp}     đẩy sang ffmpeg, giữ constant frame rate
src/win/                ── chỉ Windows, CHƯA kiểm chứng
  spout_source.{h,cpp}    nhận frame qua SpoutDX
src/main.cpp            ── dòng lệnh
src/core_test.cpp       ── 43 phép thử cho phần lõi
```

Watermark phải khớp **từng bit** với bản macOS (`~/tdrec/Sources/TDRec/Watermark.swift`) và với GLSL TOP (`~/tdrec/td/tdrec_watermark.frag`) — cùng một project TouchDesigner phải cho kết quả giống nhau ở cả hai hệ.
