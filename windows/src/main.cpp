// main.cpp — TDRec cho Windows (bản dòng lệnh).
//
// Cùng nguyên lý với bản macOS: TouchDesigner chỉ chia sẻ texture qua Spout,
// còn việc encode chạy ở process riêng bằng NVENC. TD không phải encode gì nên
// giữ nguyên FPS.
//
// Vòng lặp ghi làm việc qua IFrameSource nên chạy được cả với nguồn giả lập
// (--mock) trên máy không phải Windows. Nhờ vậy phần điều phối được kiểm chứng
// độc lập với Spout.

#include "core/frame_pipeline.h"
#include "core/ffmpeg_sink.h"
#include "core/frame_source.h"

#ifdef _WIN32
  #include "win/spout_source.h"
  #include <windows.h>
#endif

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <memory>
#include <string>
#include <vector>
#include <iostream>
#include <thread>
#include <atomic>
#include <csignal>

using namespace tdrec;

namespace {

std::atomic<bool> g_stop{false};
void OnSignal(int) { g_stop = true; }

double NowSeconds() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

const char* Arg(int argc, char** argv, const char* flag, const char* fallback) {
    for (int i = 1; i + 1 < argc; ++i)
        if (std::strcmp(argv[i], flag) == 0) return argv[i + 1];
    return fallback;
}
bool HasFlag(int argc, char** argv, const char* flag) {
    for (int i = 1; i < argc; ++i)
        if (std::strcmp(argv[i], flag) == 0) return true;
    return false;
}

void Usage() {
    std::printf(R"(TDRec — ghi Spout ra video, khong rot frame.

  --senders                     liet ke Spout sender dang phat        [Windows]
  --probe                       nhan frame 5 giay va bao cao          [Windows]
                                (chay TRUOC khi ghi that — khong dung ffmpeg)
  --record                      bat dau ghi
      --sender <ten>            ten Spout sender (bo trong = sender active)
      --mock                    dung nguon gia lap thay cho Spout (moi he dieu hanh)
      --mockfps <n>             nhip cua nguon gia lap, mac dinh = --fps
      --mockstuck               gia lap quen noi uFrame (watermark dung yen)
      --out <duong-dan>         file xuat
      --fps <n>                 nhip ghi, mac dinh 60
      --codec <ten>             hevc_nvenc (mac dinh) | h264_nvenc | libx264 | prores_ks
      --qp <n>                  chat luong NVENC, cang nho cang dep (mac dinh 18)
      --preset <p>              NVENC p1..p7 (mac dinh p5)
      --10bit                   xuat 10-bit (chi HEVC)
      --width/--height <px>     chi dung voi --mock
      --seconds <n>             tu dung sau n giay (0 = cho Ctrl+C)
      --no-watermark            khong doc watermark
      --block <n>               block size watermark, khop uBlock trong GLSL TOP
      --swap-rb                 dao kenh do/xanh neu mau ra sai
      --flip                    lat doc neu video ra bi lon nguoc
      --ffmpeg <duong-dan>      duong dan ffmpeg neu khong nam trong PATH
      --quiet                   khong in tien do tung giay

Vi du:
  tdrec --senders
  tdrec --probe --sender RECORD
  tdrec --record --sender RECORD --out D:\show.mov --fps 60
  tdrec --record --mock --width 1920 --height 1080 --fps 60 --seconds 5 \
        --codec libx264 --out test.mov
)");
}

struct RecordConfig {
    FramePipeline::Config pipe;
    FFmpegSink::Options   sink;
    double  seconds = 0;
    bool    quiet   = false;
};

RecordConfig ParseRecord(int argc, char** argv, int width, int height) {
    RecordConfig c;
    c.pipe.fps            = std::atoi(Arg(argc, argv, "--fps", "60"));
    c.pipe.blockSize      = std::atoi(Arg(argc, argv, "--block", "2"));
    c.pipe.useWatermark   = !HasFlag(argc, argv, "--no-watermark");
    c.pipe.eraseWatermark = true;

    c.sink.ffmpegPath = Arg(argc, argv, "--ffmpeg", "ffmpeg");
    c.sink.output     = Arg(argc, argv, "--out", "tdrec_out.mov");
    c.sink.codec      = Arg(argc, argv, "--codec", "hevc_nvenc");
    c.sink.preset     = Arg(argc, argv, "--preset", "p5");
    c.sink.cqLevel    = std::atoi(Arg(argc, argv, "--qp", "18"));
    c.sink.tenBit     = HasFlag(argc, argv, "--10bit");
    c.sink.width      = width;
    c.sink.height     = height;
    c.sink.fps        = c.pipe.fps;
    // libx264 không hiểu cờ NVENC; đặt sẵn tham số hợp lệ cho nó.
    if (c.sink.codec == "libx264")
        c.sink.extraArgs = "-pix_fmt yuv420p -preset ultrafast -crf 20";

    c.seconds = std::atof(Arg(argc, argv, "--seconds", "0"));
    c.quiet   = HasFlag(argc, argv, "--quiet");
    return c;
}

// ── Vòng lặp ghi, dùng chung cho nguồn Spout và nguồn giả lập ───────────
int RunRecord(IFrameSource& src, const RecordConfig& cfg) {
    FramePipeline pipe(cfg.pipe);
    FFmpegSink sink;
    std::string err;

    if (!sink.Open(cfg.sink, &err)) {
        std::printf("Loi mo ffmpeg: %s\n", err.c_str());
        return 1;
    }
    std::printf("Lenh ffmpeg: %s\n", sink.CommandLine().c_str());

    pipe.SetSink(&sink);
    pipe.Begin();

    std::printf("\nDANG GHI %dx%d @%dfps -> %s\n",
                src.width(), src.height(), cfg.pipe.fps, cfg.sink.output.c_str());
    if (cfg.seconds <= 0) std::printf("Nhan Ctrl+C de dung.\n");
    std::printf("\n");

    const double t0 = NowSeconds();
    double lastReport = t0;

    while (!g_stop) {
        if (cfg.seconds > 0 && NowSeconds() - t0 >= cfg.seconds) break;

        const bool got = src.Receive();

        // Phai kiem tra SizeChanged() DOC LAP voi got: khi nguon doi kich thuoc,
        // Receive() tra false (frame do chua hop le) nen neu long trong
        // `if (got)` thi guard nay khong bao gio chay.
        if (src.SizeChanged()) {
            std::printf("\n!! Do phan giai nguon doi giua chung — dung ghi.\n");
            break;
        }

        if (got) {
            pipe.Submit(src.pixels(), src.stride(), src.width(), src.height(), NowSeconds());
        } else {
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }

        const double now = NowSeconds();
        if (!cfg.quiet && now - lastReport >= 1.0) {
            lastReport = now;
            const auto s = sink.stats();
            std::printf("\r  %6.1fs | ghi %llu | bu %llu | bo %llu | nguon %.1ffps    ",
                        sink.duration(),
                        (unsigned long long)s.written,
                        (unsigned long long)s.duplicated,
                        (unsigned long long)(s.rejected + pipe.status().framesDropped),
                        src.sourceFps());
            std::fflush(stdout);
        }
    }

    const double wall = NowSeconds() - t0;
    pipe.End();
    const bool ok = sink.Close(&err);
    const auto s = sink.stats();

    std::printf("\n\n── Xong ────────────────────────────────\n");
    std::printf("  File            : %s\n", cfg.sink.output.c_str());
    std::printf("  Thoi gian thuc  : %.3f s\n", wall);
    std::printf("  Thoi luong video: %.3f s\n", sink.duration());
    std::printf("  Lech            : %+.0f ms\n", (sink.duration() - wall) * 1000.0);
    std::printf("  Frame ghi       : %llu\n", (unsigned long long)s.written);
    std::printf("  Frame chen bu   : %llu\n", (unsigned long long)s.duplicated);
    std::printf("  Frame bo        : %llu\n",
                (unsigned long long)(s.rejected + pipe.status().framesDropped));
    std::printf("  Watermark       : %s\n",
                pipe.status().watermarkLocked ? "DOC DUOC" : "khong thay");
    if (pipe.status().counterStuck)
        std::printf("  !! Watermark dung yen — uFrame chua noi absTime.frame\n");
    if (s.sizeMismatch)
        std::printf("  !! Co frame sai kich thuoc bi chan — nguon da doi do phan giai\n");
    if (!ok) std::printf("  !! %s\n", err.c_str());
    return ok ? 0 : 1;
}

int CmdRecordMock(int argc, char** argv) {
    MockSource::Options mo;
    mo.width  = std::atoi(Arg(argc, argv, "--width",  "1920"));
    mo.height = std::atoi(Arg(argc, argv, "--height", "1080"));
    mo.fps    = std::atof(Arg(argc, argv, "--mockfps",
                              Arg(argc, argv, "--fps", "60")));
    mo.blockSize    = std::atoi(Arg(argc, argv, "--block", "2"));
    mo.watermark    = !HasFlag(argc, argv, "--no-watermark");
    mo.stuckCounter = HasFlag(argc, argv, "--mockstuck");

    MockSource src(mo);
    const RecordConfig cfg = ParseRecord(argc, argv, mo.width, mo.height);
    std::printf("Nguon gia lap: %dx%d @ %.1f fps%s\n",
                mo.width, mo.height, mo.fps,
                mo.stuckCounter ? " (watermark dung yen)" : "");
    return RunRecord(src, cfg);
}

#ifdef _WIN32

int CmdSenders() {
    const auto list = SpoutSource::ListSenders();
    if (list.empty()) { std::printf("Khong thay Spout sender nao dang phat.\n"); return 1; }
    std::printf("Spout sender dang phat:\n");
    for (const auto& s : list) std::printf("  - %s\n", s.c_str());
    return 0;
}

// Nhận frame một lúc rồi báo cáo — xác nhận đường Spout thông trước khi ghi
// thật. Không đụng tới ffmpeg nên loại trừ được một nguồn lỗi.
int CmdProbe(int argc, char** argv) {
    const std::string sender = Arg(argc, argv, "--sender", "");

    SpoutSource src;
    src.SetSwapRedBlue(HasFlag(argc, argv, "--swap-rb"));
    src.SetFlipVertical(HasFlag(argc, argv, "--flip"));
    std::string err;
    if (!src.Open(sender, &err)) { std::printf("Loi: %s\n", err.c_str()); return 1; }

    FramePipeline::Config cfg;
    cfg.fps            = std::atoi(Arg(argc, argv, "--fps", "60"));
    cfg.blockSize      = std::atoi(Arg(argc, argv, "--block", "2"));
    cfg.useWatermark   = !HasFlag(argc, argv, "--no-watermark");
    cfg.eraseWatermark = false;                 // chỉ dò, không sửa ảnh
    FramePipeline pipe(cfg);
    pipe.Begin();                               // không gắn sink -> không ghi

    std::printf("Dang nhan 5 giay tu \"%s\"...\n",
                sender.empty() ? "(sender active)" : sender.c_str());

    const double t0 = NowSeconds();
    int frames = 0;
    double firstFrameAt = -1;
    while (NowSeconds() - t0 < 5.0 && !g_stop) {
        if (src.Receive()) {
            if (firstFrameAt < 0) firstFrameAt = NowSeconds();
            frames++;
            pipe.Submit(src.pixels(), src.stride(), src.width(), src.height(), NowSeconds());
        } else {
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
    }
    const double dt = NowSeconds() - t0;

    std::printf("\n── Ket qua ─────────────────────────────\n");
    std::printf("  Sender          : %s\n", src.name().c_str());
    std::printf("  Do phan giai    : %d x %d\n", src.width(), src.height());
    std::printf("  Frame nhan duoc : %d  (%.1f fps)\n", frames, frames / dt);
    std::printf("  Spout bao fps   : %.1f\n", src.sourceFps());
    std::printf("  Watermark       : %s\n",
                pipe.status().watermarkLocked ? "DOC DUOC" : "khong thay");
    if (pipe.status().counterStuck)
        std::printf("  !! Watermark dung yen — uFrame chua noi absTime.frame\n");
    if (src.width() % 2 || src.height() % 2)
        std::printf("  !! Do phan giai co canh le — codec can canh chan\n");

    if (frames == 0) {
        std::printf("\nKHONG nhan duoc frame nao. Kiem tra:\n"
                    "  - Syphon Spout Out TOP trong TD da bat Active chua\n"
                    "  - TOP do co dang cook khong (khong cook = ngung phat)\n"
                    "  - Ten sender co dung khong (chay --senders de xem)\n");
        return 1;
    }
    std::printf("\nOK — duong Spout thong. Co the chay --record.\n");
    return 0;
}

int CmdRecordSpout(int argc, char** argv) {
    const std::string sender = Arg(argc, argv, "--sender", "");

    SpoutSource src;
    src.SetSwapRedBlue(HasFlag(argc, argv, "--swap-rb"));
    src.SetFlipVertical(HasFlag(argc, argv, "--flip"));
    std::string err;
    if (!src.Open(sender, &err)) { std::printf("Loi: %s\n", err.c_str()); return 1; }

    // Chờ frame đầu để biết độ phân giải trước khi mở ffmpeg.
    std::printf("Doi frame dau tien...\n");
    const double waitStart = NowSeconds();
    while (!src.Receive()) {
        if (NowSeconds() - waitStart > 10.0) {
            std::printf("Khong nhan duoc frame sau 10 giay. Chay --probe de chan doan.\n");
            return 1;
        }
        if (g_stop) return 1;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }

    const RecordConfig cfg = ParseRecord(argc, argv, src.width(), src.height());
    return RunRecord(src, cfg);
}

// ── Menu khi người dùng BẤM ĐÚP file exe từ Explorer ───────────────────
//
// tdrec.exe là console app. Bấm đúp nó thì Windows tạo một console mới,
// chạy xong lệnh là ĐÓNG CỬA SỔ NGAY — người dùng chỉ thấy ô đen nháy một
// cái rồi tắt, nhìn y hệt "app hỏng, bấm không lên". Đây là hiểu lầm số
// một khi đưa công cụ dòng lệnh cho người không quen terminal.
//
// Cách phân biệt bấm đúp với gõ lệnh từ cmd: đếm số process đang gắn vào
// console. Console do Explorer dựng lên chỉ có duy nhất process này; console
// của cmd.exe / PowerShell thì có ít nhất cái shell đó nữa. Nhờ vậy chạy từ
// terminal vẫn giữ nguyên hành vi cũ (in usage rồi thoát) để còn viết script.
bool LaunchedFromExplorer() {
    DWORD pids[4] = {};
    const DWORD n = GetConsoleProcessList(pids, 4);
    return n <= 1;
}

std::string ReadLine(const char* label, const std::string& fallback) {
    std::printf("%s", label);
    std::fflush(stdout);
    std::string s;
    if (!std::getline(std::cin, s)) return fallback;
    const size_t a = s.find_first_not_of(" \t");
    if (a == std::string::npos) return fallback;
    const size_t b = s.find_last_not_of(" \t\r");
    s = s.substr(a, b - a + 1);
    return s.empty() ? fallback : s;
}

void WaitEnter() {
    std::printf("\n  ---------------------------------------------------\n");
    std::printf("  Nhan Enter de ve menu...");
    std::fflush(stdout);
    std::string bo;
    std::getline(std::cin, bo);
}

// Gọi lại đúng các hàm lệnh ở trên bằng argv dựng tại chỗ, để menu và dòng
// lệnh không bao giờ đi lệch nhau.
int Dispatch(const std::vector<std::string>& args) {
    std::vector<char*> argv;
    argv.push_back(const_cast<char*>("tdrec"));
    for (const auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
    const int argc = static_cast<int>(argv.size());

    if (HasFlag(argc, argv.data(), "--senders")) return CmdSenders();
    if (HasFlag(argc, argv.data(), "--probe"))   return CmdProbe(argc, argv.data());
    if (HasFlag(argc, argv.data(), "--record"))  return CmdRecordSpout(argc, argv.data());
    return 1;
}

void MenuProbe() {
    std::printf("\n  -- Kiem tra duong Spout ---------------------------\n\n");
    std::printf("  Nhan frame trong 5 giay roi bao cao. KHONG dung ffmpeg,\n");
    std::printf("  khong ghi file -- chi de xac nhan TD co dang phat khong.\n\n");
    CmdSenders();
    std::printf("\n");

    const std::string sender = ReadLine("  Ten sender (bo trong = sender dang active): ", "");
    std::vector<std::string> args{"--probe"};
    if (!sender.empty()) { args.push_back("--sender"); args.push_back(sender); }

    const std::string mau = ReadLine("  Mau bi dao do/xanh khong? (y/N): ", "n");
    if (mau == "y" || mau == "Y") args.push_back("--swap-rb");
    const std::string lat = ReadLine("  Anh bi lon nguoc khong? (y/N): ", "n");
    if (lat == "y" || lat == "Y") args.push_back("--flip");

    std::printf("\n");
    Dispatch(args);
}

void MenuRecord() {
    std::printf("\n  -- Bat dau ghi ------------------------------------\n\n");

    if (std::system("where ffmpeg >nul 2>nul") != 0) {
        std::printf("  !! KHONG THAY ffmpeg trong PATH.\n\n");
        std::printf("  TDRec goi ffmpeg de encode, goi cai dat nay khong kem san no.\n");
        std::printf("  Cai bang mot trong hai cach:\n");
        std::printf("      winget install Gyan.FFmpeg\n");
        std::printf("      choco install ffmpeg\n");
        std::printf("  Roi MO LAI tdrec.exe (PATH chi cap nhat o phien moi).\n");
        return;
    }

    CmdSenders();
    std::printf("\n");

    const std::string sender = ReadLine("  Ten sender (bo trong = sender dang active): ", "");
    const std::string fps    = ReadLine("  Nhip ghi fps [60]: ", "60");
    const std::string out    = ReadLine("  Luu ra file [tdrec_out.mov]: ", "tdrec_out.mov");

    std::printf("\n  Codec:\n");
    std::printf("    [1] hevc_nvenc  -- NVIDIA, nhe may nhat        (mac dinh)\n");
    std::printf("    [2] h264_nvenc  -- NVIDIA, tuong thich rong hon\n");
    std::printf("    [3] libx264     -- khong can NVIDIA, an CPU\n");
    const std::string c = ReadLine("  Chon [1]: ", "1");
    const std::string codec = (c == "2") ? "h264_nvenc" : (c == "3") ? "libx264" : "hevc_nvenc";

    std::vector<std::string> args{"--record", "--fps", fps, "--codec", codec, "--out", out};
    if (!sender.empty()) { args.push_back("--sender"); args.push_back(sender); }

    std::printf("\n  Nhan Ctrl+C MOT LAN de dung va dong file tu te.\n");
    std::printf("  (Dong thang cua so se lam hong file.)\n\n");
    ReadLine("  Nhan Enter de bat dau ghi...", "");
    std::printf("\n");
    Dispatch(args);
}

// Bấm đúp exe khi nó còn NẰM TRONG file .zip: Explorer lặng lẽ bung riêng
// mình nó ra một thư mục tạm rồi chạy ở đó. App vẫn khởi động nên trông như
// bình thường, nhưng file ghi ra lại rơi vào thư mục tạm và bị Windows dọn
// mất. Bắt sớm, vì triệu chứng ("ghi xong không thấy file đâu") rất khó đoán.
void CanhBaoChayTuZip() {
    char path[MAX_PATH] = {};
    if (!GetModuleFileNameA(nullptr, path, MAX_PATH)) return;
    std::string p(path);
    for (auto& ch : p) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    if (p.find("\\temp\\") == std::string::npos || p.find(".zip") == std::string::npos) return;

    std::printf("\n");
    std::printf("  !! DANG CHAY TU BEN TRONG FILE .ZIP\n\n");
    std::printf("  Windows chi bung tam file nay ra thu muc rac roi se xoa di.\n");
    std::printf("  Video ghi ra se roi vao do va mat.\n\n");
    std::printf("  Hay: chuot phai file .zip -> Extract All... ra mot thu muc that,\n");
    std::printf("  roi bam dup tdrec.exe trong thu muc vua giai nen.\n");
    WaitEnter();
}

int RunMenu() {
    SetConsoleTitleA("TDRec");
    CanhBaoChayTuZip();
    for (;;) {
        // Ctrl+C lúc đang ghi cũng bật cờ này; không dọn thì menu vừa hiện
        // ra đã tự thoát.
        g_stop = false;

        std::system("cls");
        std::printf("\n");
        std::printf("   =====================================================\n");
        std::printf("     T D R e c   --  ghi Spout ra video, khong rot frame\n");
        std::printf("   =====================================================\n\n");
        std::printf("     [1]  Liet ke Spout sender dang phat\n");
        std::printf("     [2]  Kiem tra duong Spout  (probe)   <-- LAM CAI NAY TRUOC\n");
        std::printf("     [3]  Bat dau ghi\n");
        std::printf("     [4]  Xem bang huong dan day du\n\n");
        std::printf("     [0]  Thoat\n\n");

        const std::string chon = ReadLine("  Chon roi bam Enter: ", "");
        if (chon == "0") return 0;

        if (chon == "1") {
            std::printf("\n  -- Spout sender dang phat -------------------------\n\n");
            CmdSenders();
            std::printf("\n  Khong thay ten nao? Trong TouchDesigner kiem tra:\n");
            std::printf("    - Syphon Spout Out TOP da bat Active chua\n");
            std::printf("    - TOP do co dang COOK khong (khong cook = lang le ngung phat)\n");
        } else if (chon == "2") {
            MenuProbe();
        } else if (chon == "3") {
            MenuRecord();
        } else if (chon == "4") {
            std::printf("\n");
            Usage();
        } else {
            continue;   // gõ linh tinh thì vẽ lại menu, không cần báo lỗi
        }
        WaitEnter();
    }
}

#endif  // _WIN32

}  // namespace

int main(int argc, char** argv) {
    std::signal(SIGINT, OnSignal);

#ifdef _WIN32
    // Bấm đúp từ Explorer: không có tham số nào và console là của riêng mình.
    // Vào menu thay vì in usage rồi đóng cửa sổ ngay trước mũi người dùng.
    if (argc < 2 && LaunchedFromExplorer()) return RunMenu();
#endif

    if (argc < 2 || HasFlag(argc, argv, "--help") || HasFlag(argc, argv, "-h")) {
        Usage();
        return 0;
    }

    // Chế độ giả lập chạy được trên mọi hệ điều hành.
    if (HasFlag(argc, argv, "--record") && HasFlag(argc, argv, "--mock"))
        return CmdRecordMock(argc, argv);

#ifdef _WIN32
    if (HasFlag(argc, argv, "--senders")) return CmdSenders();
    if (HasFlag(argc, argv, "--probe"))   return CmdProbe(argc, argv);
    if (HasFlag(argc, argv, "--record"))  return CmdRecordSpout(argc, argv);
#else
    if (HasFlag(argc, argv, "--senders") || HasFlag(argc, argv, "--probe")) {
        std::printf("Lenh nay can Spout, chi chay tren Windows.\n");
        return 1;
    }
    if (HasFlag(argc, argv, "--record")) {
        std::printf("Ngoai Windows chi ghi duoc voi --mock.\n"
                    "Tren macOS dung TDRec.app (thu muc ~/tdrec).\n");
        return 1;
    }
#endif

    Usage();
    return 1;
}
