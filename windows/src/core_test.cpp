// core_test.cpp — kiểm tra phần lõi đa nền tảng của TDRec.
//
// Phần lõi (watermark + gán vị trí frame + giữ constant frame rate) không phụ
// thuộc Spout hay DirectX, nên chạy được cả trên macOS lẫn Windows. Nhờ vậy
// logic quan trọng nhất được kiểm chứng TRƯỚC khi đụng tới code riêng Windows.
//
// Chạy:  cmake --build build && ./build/tdrec_core_test

#include "core/watermark.h"
#include "core/frame_pipeline.h"
#include "core/ffmpeg_sink.h"

#include <cstdio>
#include <cstring>
#include <vector>
#include <string>
#include <cmath>

using namespace tdrec;

static int g_pass = 0, g_fail = 0;

static void Check(const char* name, bool ok, const std::string& detail = "") {
    if (ok) { g_pass++; std::printf("  [ok]   %s\n", name); }
    else    { g_fail++; std::printf("  [FAIL] %s %s\n", name, detail.c_str()); }
}

// PRNG cố định để test tái lập được.
struct SplitMix {
    uint64_t s;
    explicit SplitMix(uint64_t seed) : s(seed) {}
    uint64_t next() {
        s += 0x9E3779B97F4A7C15ull;
        uint64_t z = s;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
};

// ── Sink giả: chỉ ghi lại index, không gọi ffmpeg ──
class RecordingSink : public FrameSink {
public:
    std::vector<int64_t> indices;
    int64_t nextIndex = 0;
    int64_t duplicated = 0, rejected = 0;

    void Append(const uint8_t*, size_t, int, int, int64_t index) override {
        if (index < nextIndex) { rejected++; return; }
        while (nextIndex < index) { duplicated++; indices.push_back(nextIndex); nextIndex++; }
        indices.push_back(index);
        nextIndex = index + 1;
    }
};

static void TestWatermark() {
    std::printf("\n── Watermark ──\n");
    const int W = 512, H = 8, BS = 2;
    const size_t bpr = size_t(W) * 4;

    // Ảnh phẳng TUYỆT ĐỐI không được nhận là watermark.
    const struct { const char* name; uint8_t fill; } flats[] = {
        {"den tuyen", 0}, {"trang tuyen", 255}, {"xam giua", 128}, {"gan den", 12},
    };
    for (auto& f : flats) {
        std::vector<uint8_t> buf(size_t(W) * H * 4, f.fill);
        uint32_t out = 0;
        bool got = Watermark::Decode(buf.data(), bpr, W, H, BS,
                                     Watermark::Origin::Top, &out);
        Check((std::string("anh ") + f.name + " -> khong nhan nham").c_str(), !got);
    }

    // Nhiễu ngẫu nhiên: 8 bit magic + 8 bit checksum → ~1/65536 mỗi lần.
    int falseHits = 0;
    for (int seed = 0; seed < 300; ++seed) {
        SplitMix rng(uint64_t(seed) * 2654435761ull);
        std::vector<uint8_t> buf(size_t(W) * H * 4);
        for (auto& b : buf) b = uint8_t(rng.next() & 0xFF);
        uint32_t out = 0;
        if (Watermark::Decode(buf.data(), bpr, W, H, BS, Watermark::Origin::Top, &out))
            falseHits++;
    }
    Check("300 anh nhieu -> toi da 1 lot", falseHits <= 1,
          "(lot " + std::to_string(falseHits) + ")");

    // Mã hoá rồi giải mã phải ra đúng số ban đầu, ở cả hai chiều ảnh.
    const uint32_t frames[] = {0, 1, 42, 1000, 65535, 0xFFFFFE};
    for (auto origin : {Watermark::Origin::Top, Watermark::Origin::Bottom}) {
        for (uint32_t f : frames) {
            std::vector<uint8_t> buf(size_t(W) * H * 4, 30);
            Watermark::Encode(buf.data(), bpr, W, H, BS, origin, f);
            uint32_t out = 0;
            bool got = Watermark::Decode(buf.data(), bpr, W, H, BS, origin, &out);
            Check((std::string("ma hoa frame ") + std::to_string(f) +
                   (origin == Watermark::Origin::Top ? " (tren)" : " (duoi)")).c_str(),
                  got && out == f);
        }
    }

    // Xoá xong phải không còn dấu vết.
    {
        std::vector<uint8_t> buf(size_t(W) * H * 4, 30);
        Watermark::Encode(buf.data(), bpr, W, H, BS, Watermark::Origin::Top, 12345);
        Watermark::Erase(buf.data(), bpr, W, H, BS, Watermark::Origin::Top);
        uint32_t out = 0;
        Check("sau khi xoa -> khong con dau vet",
              !Watermark::Decode(buf.data(), bpr, W, H, BS, Watermark::Origin::Top, &out));
    }
}

// Dựng một frame test có watermark (hoặc không) rồi nộp vào pipeline.
static void FeedPipeline(FramePipeline& pipe, std::vector<uint8_t>& buf,
                         int W, int H, uint32_t tdFrame, double t, bool withWatermark) {
    std::fill(buf.begin(), buf.end(), uint8_t(30));
    if (withWatermark) {
        Watermark::Encode(buf.data(), size_t(W) * 4, W, H,
                          pipe.config().blockSize, Watermark::Origin::Top, tdFrame);
    }
    pipe.Submit(buf.data(), size_t(W) * 4, W, H, t);
}

static void TestPipeline() {
    std::printf("\n── Gan vi tri frame ──\n");
    const int W = 256, H = 8;

    // 1. Nguồn chạy đúng nhịp: mỗi frame một ô, không bù, không bỏ.
    {
        FramePipeline::Config cfg; cfg.fps = 60; cfg.blockSize = 2;
        FramePipeline pipe(cfg);
        RecordingSink sink;
        pipe.SetSink(&sink); pipe.Begin();
        std::vector<uint8_t> buf(size_t(W) * H * 4);
        for (int i = 0; i < 300; ++i)
            FeedPipeline(pipe, buf, W, H, 1000 + i, i / 60.0, true);

        Check("nguon 60fps / ghi 60fps -> 300 frame",
              sink.indices.size() == 300, "(" + std::to_string(sink.indices.size()) + ")");
        Check("khong chen bu", sink.duplicated == 0,
              "(" + std::to_string(sink.duplicated) + ")");
        Check("watermark doc duoc", pipe.status().watermarkLocked);
    }

    // 2. Nguồn chậm hơn nhịp ghi: video PHẢI đúng thời lượng thực.
    {
        FramePipeline::Config cfg; cfg.fps = 60; cfg.blockSize = 2;
        FramePipeline pipe(cfg);
        RecordingSink sink;
        pipe.SetSink(&sink); pipe.Begin();
        std::vector<uint8_t> buf(size_t(W) * H * 4);
        const int srcFps = 20, secs = 5;
        for (int i = 0; i < srcFps * secs; ++i)
            FeedPipeline(pipe, buf, W, H, 1000 + i, i / double(srcFps), true);

        const double dur = sink.nextIndex / 60.0;
        Check("nguon 20fps / ghi 60fps -> dung thoi luong",
              std::fabs(dur - (secs - 1.0 / srcFps)) < 0.05,
              "(" + std::to_string(dur) + "s)");
        // 100 frame thật trải trên ~297 ô của trục 60fps -> ~197 frame bù.
        const int64_t expectFill = sink.nextIndex - int64_t(srcFps * secs);
        Check("so frame bu dung ly thuyet",
              std::llabs(sink.duplicated - expectFill) <= 2,
              "(bu " + std::to_string(sink.duplicated) +
              ", ly thuyet " + std::to_string(expectFill) + ")");
    }

    // 3. Nguồn NHANH hơn nhịp ghi: không được kéo dài video.
    {
        FramePipeline::Config cfg; cfg.fps = 30; cfg.blockSize = 2;
        FramePipeline pipe(cfg);
        RecordingSink sink;
        pipe.SetSink(&sink); pipe.Begin();
        std::vector<uint8_t> buf(size_t(W) * H * 4);
        const int srcFps = 60, secs = 5;
        for (int i = 0; i < srcFps * secs; ++i)
            FeedPipeline(pipe, buf, W, H, 1000 + i, i / double(srcFps), true);

        const double dur = sink.nextIndex / 30.0;
        Check("nguon 60fps / ghi 30fps -> KHONG dai ra",
              dur < secs + 0.2, "(" + std::to_string(dur) + "s)");
    }

    // 4. Không có watermark: vẫn phải đúng thời lượng, và không báo nhầm.
    {
        FramePipeline::Config cfg; cfg.fps = 30; cfg.blockSize = 2;
        FramePipeline pipe(cfg);
        RecordingSink sink;
        pipe.SetSink(&sink); pipe.Begin();
        std::vector<uint8_t> buf(size_t(W) * H * 4);
        for (int i = 0; i < 150; ++i)
            FeedPipeline(pipe, buf, W, H, 0, i / 30.0, false);

        Check("khong watermark -> van ghi du frame",
              sink.indices.size() == 150, "(" + std::to_string(sink.indices.size()) + ")");
        Check("khong watermark -> KHONG bao doc duoc", !pipe.status().watermarkLocked);
        Check("khong watermark -> KHONG bao counter dung yen",
              !pipe.status().counterStuck);
    }

    // 5. uFrame chưa nối absTime.frame: watermark đứng yên.
    //    App phải phát hiện VÀ vẫn ghi đủ frame.
    {
        FramePipeline::Config cfg; cfg.fps = 30; cfg.blockSize = 2;
        FramePipeline pipe(cfg);
        RecordingSink sink;
        pipe.SetSink(&sink); pipe.Begin();
        std::vector<uint8_t> buf(size_t(W) * H * 4);
        for (int i = 0; i < 150; ++i)
            FeedPipeline(pipe, buf, W, H, 777, i / 30.0, true);   // số không đổi

        Check("counter dung yen -> phat hien duoc", pipe.status().counterStuck);
        Check("counter dung yen -> VAN ghi du frame",
              sink.indices.size() == 150, "(" + std::to_string(sink.indices.size()) + ")");
    }

    // 6. Jitter thời gian: không được sinh ra bù/bỏ lung tung.
    {
        FramePipeline::Config cfg; cfg.fps = 30; cfg.blockSize = 2;
        FramePipeline pipe(cfg);
        RecordingSink sink;
        pipe.SetSink(&sink); pipe.Begin();
        std::vector<uint8_t> buf(size_t(W) * H * 4);
        SplitMix rng(12345);
        for (int i = 0; i < 300; ++i) {
            // lệch ngẫu nhiên ±40% chu kỳ frame
            const double j = (double(rng.next() % 1000) / 1000.0 - 0.5) * 0.8 / 30.0;
            FeedPipeline(pipe, buf, W, H, 1000 + i, i / 30.0 + j, true);
        }
        Check("jitter +-40% -> khong bo frame that",
              sink.indices.size() >= 298, "(" + std::to_string(sink.indices.size()) + ")");
        Check("jitter +-40% -> chen bu it",
              sink.duplicated <= 5, "(" + std::to_string(sink.duplicated) + ")");
    }
}

static void TestFFmpegCommand() {
    std::printf("\n── Dong lenh ffmpeg ──\n");
    FFmpegSink::Options o;
    o.width = 10350; o.height = 1080; o.fps = 60;
    o.codec = "hevc_nvenc"; o.output = "C:\\Users\\vj\\My Videos\\show.mov";

    FFmpegSink sink;
    const std::string cmd = sink.CommandLine();  // dùng mặc định, chưa Open
    // Chỉ kiểm tra được sau khi Open gán opt_, nên gọi Open thất bại có chủ đích
    // sẽ không hợp lý — thay vào đó kiểm tra hàm dựng chuỗi qua Open thật.
    std::string err;
    FFmpegSink s2;
    o.ffmpegPath = "/bin/cat";       // chạy được nhưng không phải ffmpeg
    o.output = "/dev/null";
    bool opened = s2.Open(o, &err);
    Check("Open() voi canh chan -> thanh cong", opened, err);
    const std::string c2 = s2.CommandLine();
    Check("lenh co -f rawvideo", c2.find("-f rawvideo") != std::string::npos);
    Check("lenh co dung do phan giai", c2.find("10350x1080") != std::string::npos);
    Check("lenh co codec nvenc", c2.find("hevc_nvenc") != std::string::npos);
    Check("duong dan duoc trich dan", c2.find("\"/dev/null\"") != std::string::npos);
    s2.Close(&err);

    // Cạnh lẻ phải bị chặn sớm với thông báo rõ ràng.
    FFmpegSink s3;
    o.width = 10351;
    Check("canh le -> bi chan", !s3.Open(o, &err), err);
    (void)cmd;
}

// Kiểm tra FFmpegSink đầu-cuối bằng ffmpeg THẬT: nạp frame có lỗ hổng cố ý,
// rồi đếm lại số frame trong file xuất. Đây là phép thử duy nhất chứng minh
// phần chèn bù giữ constant frame rate hoạt động qua đường ống thật.
static void TestSinkEndToEnd() {
    std::printf("\n── FFmpegSink dau-cuoi (ffmpeg that) ──\n");

    const int W = 64, H = 64, FPS = 30;
    const char* out = "/tmp/tdrec_sink_test.mov";

    FFmpegSink::Options o;
    o.width = W; o.height = H; o.fps = FPS;
    o.output = out;
    o.codec = "libx264";            // có sẵn ở mọi bản ffmpeg, không cần NVIDIA
    o.extraArgs = "-pix_fmt yuv420p -preset ultrafast -crf 30";

    FFmpegSink sink;
    std::string err;
    if (!sink.Open(o, &err)) {
        Check("mo duoc ffmpeg", false, err);
        return;
    }

    std::vector<uint8_t> frame(size_t(W) * H * 4, 90);

    // Nạp các ô: 0,1,2 rồi nhảy thẳng tới 10 (bỏ trống 3..9), rồi 11.
    // Kỳ vọng: file có đúng 12 frame, trong đó 7 frame là hình lặp.
    const int64_t idx[] = {0, 1, 2, 10, 11};
    for (int64_t i : idx)
        sink.Append(frame.data(), size_t(W) * 4, W, H, i);

    const auto st = sink.stats();
    bool closed = sink.Close(&err);

    Check("ffmpeg dong sach", closed, err);
    Check("ghi dung 12 frame", st.written == 12,
          "(" + std::to_string(st.written) + ")");
    Check("chen bu dung 7 frame", st.duplicated == 7,
          "(" + std::to_string(st.duplicated) + ")");

    // Đối chiếu bằng ffprobe cho chắc — đếm frame thật trong file.
    std::string cmd = "ffprobe -v error -count_frames -select_streams v:0 "
                      "-show_entries stream=nb_read_frames -of default=nw=1:nk=1 ";
    cmd += out;
    cmd += " 2>/dev/null";
    if (FILE* fp = popen(cmd.c_str(), "r")) {
        char buf[64] = {0};
        if (std::fgets(buf, sizeof buf, fp)) {
            const int n = std::atoi(buf);
            Check("ffprobe dem duoc 12 frame trong file", n == 12,
                  "(" + std::to_string(n) + ")");
        } else {
            Check("chay duoc ffprobe", false);
        }
        pclose(fp);
    }
    std::remove(out);
}

// Frame sai kich thuoc phai bi chan. Neu lot qua, video hong hoan toan va con
// tran bo dem lastFrame_ khi chen bu.
static void TestSizeGuard() {
    std::printf("\n── Chan frame sai kich thuoc ──\n");

    const int W = 64, H = 64;
    FFmpegSink::Options o;
    o.width = W; o.height = H; o.fps = 30;
    o.output = "/tmp/tdrec_size_test.mov";
    o.codec = "libx264";
    o.extraArgs = "-pix_fmt yuv420p -preset ultrafast -crf 35";

    FFmpegSink sink;
    std::string err;
    if (!sink.Open(o, &err)) { Check("mo duoc ffmpeg", false, err); return; }

    std::vector<uint8_t> ok(size_t(W) * H * 4, 100);
    std::vector<uint8_t> big(size_t(W * 2) * (H * 2) * 4, 100);

    sink.Append(ok.data(),  size_t(W) * 4,     W,     H,     0);
    sink.Append(big.data(), size_t(W * 2) * 4, W * 2, H * 2, 1);   // phai bi chan
    sink.Append(ok.data(),  size_t(W) * 4,     W,     H,     1);

    const auto st = sink.stats();
    sink.Close(&err);

    Check("frame sai kich thuoc bi chan", st.sizeMismatch);
    Check("chi ghi 2 frame dung kich thuoc", st.written == 2,
          "(" + std::to_string(st.written) + ")");
    std::remove(o.output.c_str());
}

int main() {
    std::printf("========================================\n");
    std::printf(" TDRec — kiem tra phan loi da nen tang\n");
    std::printf("========================================\n");

    TestWatermark();
    TestPipeline();
    TestFFmpegCommand();
    TestSinkEndToEnd();
    TestSizeGuard();

    std::printf("\n----------------------------------------\n");
    std::printf(" %d dat, %d hong\n", g_pass, g_fail);
    std::printf("----------------------------------------\n");
    return g_fail == 0 ? 0 : 1;
}
