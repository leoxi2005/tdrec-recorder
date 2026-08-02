# TDRec

Ghi hình từ TouchDesigner ra ProRes mà **không kéo tụt FPS của TD**, và **không rớt frame**.

TD chỉ chia sẻ texture qua Syphon (zero-copy, gần như không tốn tài nguyên). Toàn bộ việc encode diễn ra trong process riêng, dùng encoder ProRes phần cứng của Apple Silicon.

---

## Đã kiểm chứng trên máy này

M4 Max / 36 GB / macOS 26.5:

| Bài test | Kết quả |
|---|---|
| Bộ giải mã watermark (12 phép thử) | đạt — vùng đen/trắng/xám phẳng không bị nhận nhầm |
| Nguồn 20fps → ghi 60fps, 8s | 7.967s video, lệch **-33 ms** |
| Nguồn 34fps → ghi 60fps, 10s | 9.983s video, lệch **-17 ms** |
| Không có watermark, 10350×1080 @30fps | 240 frame, 0 bù, 0 bỏ, lệch **0 ms** |
| 1920×1080 @60fps, ProRes 422 HQ, 5s | 300 phát → **300 ghi**, 0 mất |
| 10990×1080 @60fps, ProRes 422 HQ, 10s | 600 phát → **600 ghi**, 0 mất |
| 10990×1080 @60fps, ProRes 4444, 10s | 600 phát → **600 ghi**, 0 mất |
| Constant frame rate | 600/600 frame đúng nhịp, **0 sai lệch** |
| Watermark xoá khỏi bản xuất | sạch, không còn vệt |

Tự chạy lại bất cứ lúc nào:

```bash
./build.sh test 10990 1080 10
```

---

## Cài đặt

```bash
cd ~/tdrec
./build.sh install      # build + cài vào /Applications
```

Cần: macOS 13+, Xcode command line tools, và `ffmpeg` (chỉ khi muốn tự ghép nhạc — `brew install ffmpeg`).

---

## Thiết lập trong TouchDesigner

### Bước 1 — Xuất tín hiệu qua Syphon

1. Thêm **Syphon Spout Out TOP** vào cuối chain.
2. Đặt **Sender Name** (ví dụ `wall`), bật **Active**.

### Bước 2 — Gắn watermark đếm frame *(tuỳ chọn)*

Giúp app biết TouchDesigner thực sự render được bao nhiêu frame và loại bỏ frame Syphon phát lại trùng. Bỏ qua cũng được — xem ghi chú cuối mục này.

1. Tạo **GLSL TOP**, trỏ **Pixel Shader** vào `td/tdrec_watermark.frag`.
2. Nối tín hiệu cuối cùng của bạn vào **input 0** của GLSL TOP.
3. Tab **Vectors**, thêm 2 uniform:

   | Tên | Giá trị |
   |---|---|
   | `uFrame` | `absTime.frame` *(dạng expression)* |
   | `uBlock` | `2` *(phải khớp "Block size" trong TDRec)* |

4. Nối output GLSL TOP → **Syphon Spout Out TOP**.

> ⚠️ Chỉ nối watermark vào **nhánh đi tới Syphon**. Nhánh ra máy chiếu/màn hình lấy thẳng tín hiệu gốc.

Watermark chiếm 80×2 pixel ở góc trên-trái và **được TDRec xoá khỏi file xuất**, nên bản record cuối cùng hoàn toàn sạch.

**Bước này là tuỳ chọn.** Vị trí frame trên trục thời gian được tính bằng đồng hồ thực, nên video luôn đúng thời lượng và khớp nhạc kể cả khi không có watermark. Watermark chỉ thêm hai thứ: loại bỏ frame Syphon phát lại y hệt, và cho biết TouchDesigner thực sự render được bao nhiêu frame. Không muốn gắn thì cứ bỏ tick “Đọc frame counter từ watermark” trong app.

### Bước 3 — Điều khiển từ TD qua OSC *(tuỳ chọn)*

Thêm **OSC Out DAT** trỏ tới `127.0.0.1` port `7400`:

| Message | Tác dụng |
|---|---|
| `/tdrec/name  "TEN_CLIP"` | đặt tên file cho lần ghi kế tiếp |
| `/tdrec/start  <giây>` | bắt đầu ghi; tham số là **vị trí phát của nhạc** ngay lúc đó |
| `/tdrec/stop` | dừng và đóng file |

Ví dụ Python DAT trong TD:

```python
def onStart():
    pos = op('audiofilein1')['index'].eval() / op('audiofilein1').par.rate
    op('oscout1').sendOSC('/tdrec/start', [pos])
```

Truyền đúng vị trí nhạc là điều kiện để app ghép nhạc khớp tuyệt đối.

---

## Dùng app

1. Mở TDRec → chọn Syphon server → **Kết nối**.
2. Chọn codec + FPS (**phải khớp FPS của TouchDesigner**).
3. Chọn file nhạc nếu muốn tự ghép.
4. **BẮT ĐẦU GHI** (hoặc phím `Space`, hoặc OSC).

### Đọc chỉ số sức khoẻ khi đang ghi

| Chỉ số | Ý nghĩa |
|---|---|
| **Bù (frame thiếu)** > 0 | TouchDesigner rớt frame. Video vẫn khớp nhạc nhưng có hình lặp → giảm tải cho TD. |
| **Bỏ tại nguồn** > 0 | Đĩa hoặc encoder tụt lại → hạ codec (4444 → 422 HQ → LT) hoặc ghi ra ổ nhanh hơn. |
| **FPS nhận** thấp hơn FPS cài | Bản thân TD không chạy đủ nhịp — vấn đề nằm ở project, không phải ở app. |
| Cả ba đều 0 | Bản ghi sạch tuyệt đối. |

---

## Chọn codec

Số liệu đo thực tế ở **10990×1080 @60fps**:

| Codec | Dung lượng | Dùng khi |
|---|---|---|
| ProRes 422 Proxy | ~1.9 GB/phút | xem duyệt nhanh |
| ProRes 422 LT | ~4.3 GB/phút | máy yếu / ổ chậm |
| ProRes 422 HQ | ~9.3 GB/phút | **mặc định nên dùng** |
| ProRes 4444 | ~14 GB/phút | cần alpha hoặc hậu kỳ nặng |

App tự tính và hiện số phút còn ghi được theo dung lượng trống.

---

## Giới hạn cần biết

- **Syphon trên macOS chỉ truyền được 8-bit RGBA.** Nếu chain TOP của bạn chạy 16-bit float thì dải màu bị ép xuống 8-bit ngay tại Syphon — đây là giới hạn của Syphon, không phải của app. Với chain 8-bit thì truyền **bit-exact**, không mất gì.
- ProRes yêu cầu cạnh chẵn. App chặn sớm và báo rõ nếu res có cạnh lẻ.
- Bộ đếm watermark là 24-bit → tràn sau ~77 giờ chạy liên tục ở 60fps (app xử lý được việc tràn).

---

## Dòng lệnh

```bash
TDRec --selftest [--width N --height N --fps N --seconds N --codec hq|4444|lt|422|proxy]
TDRec --osctest [--port 7400]      # kiểm tra TD có gửi OSC tới không
TDRec --help
```

---

## Cấu trúc mã nguồn

```
Sources/SyphonBridge/    cầu nối Objective-C tới Syphon.framework
Sources/TDRec/
  SyphonSource.swift     nhận texture, blit sang buffer riêng bằng GPU
  FramePipeline.swift    xử lý frame trên serial queue (giữ đúng thứ tự)
  Watermark.swift        giải mã + xoá số frame
  ProResWriter.swift     AVAssetWriter, giữ constant frame rate, chèn bù
  OSCServer.swift        nhận lệnh điều khiển từ TD
  AudioMux.swift         ghép nhạc gốc bằng ffmpeg (không re-encode)
  RecorderEngine.swift   điều phối + trạng thái cho giao diện
  SelfTest.swift         giả lập TD để tự kiểm tra đầu-cuối
td/tdrec_watermark.frag  GLSL TOP gắn vào TouchDesigner
```
