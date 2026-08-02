import SwiftUI

/// Điểm vào. Tách khỏi `App` để có thể chạy chế độ dòng lệnh (--selftest)
/// mà không bật giao diện.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        if args.contains("--selftest") {
            var opt = SelfTest.Options()
            if let v = value(for: "--width",   in: args), let n = Int(v) { opt.width = n }
            if let v = value(for: "--height",  in: args), let n = Int(v) { opt.height = n }
            if let v = value(for: "--fps",     in: args), let n = Int(v) { opt.fps = n }
            if let v = value(for: "--seconds", in: args), let n = Int(v) { opt.seconds = n }
            if let v = value(for: "--senderfps", in: args), let n = Int(v) { opt.senderFPS = n }
            if args.contains("--nowatermark") { opt.paintWatermark = false }
            if let v = value(for: "--out",     in: args) { opt.output = URL(fileURLWithPath: v) }
            if let v = value(for: "--codec",   in: args),
               let c = ProResWriter.Codec.allCases.first(where: {
                   $0.rawValue.lowercased().contains(v.lowercased())
               }) { opt.codec = c }
            exit(SelfTest.run(opt))
        }

        if args.contains("--decodetest")    { exit(DecodeTest.run()) }
        if args.contains("--reconnecttest") { exit(ReconnectTest.run()) }

        if args.contains("--servers") {
            let list = SyphonSource.servers()
            if list.isEmpty {
                print("Không thấy Syphon server nào đang phát.")
            } else {
                print("Syphon server đang phát:")
                for s in list { print("  • \(s.displayName)   [uuid \(s.uuid)]") }
            }
            exit(list.isEmpty ? 1 : 0)
        }

        if args.contains("--osctest") {
            let port = UInt16(value(for: "--port", in: args) ?? "") ?? 7400
            exit(oscTest(port: port))
        }

        TDRecApp.main()
    }

    /// Nghe OSC trong 8 giây và in ra mọi message nhận được — dùng để kiểm tra
    /// TouchDesigner đã gửi đúng địa chỉ/port chưa.
    private static func oscTest(port: UInt16) -> Int32 {
        let osc = OSCServer()
        let counter = Counter()
        osc.onMessage = { address, args in
            counter.increment()
            let desc = args.map { a -> String in
                switch a {
                case .int(let v):    return "int(\(v))"
                case .float(let v):  return "float(\(v))"
                case .string(let s): return "str(\"\(s)\")"
                }
            }.joined(separator: ", ")
            print("  ← \(address)  [\(desc)]")
        }
        do { try osc.start(port: port) } catch {
            print("✗ Không mở được port \(port): \(error.localizedDescription)")
            return 1
        }
        print("Đang nghe OSC ở port \(port) trong 8 giây…")
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        osc.stop()
        print("\nNhận được \(counter.value) message.")
        return counter.value > 0 ? 0 : 1
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func printUsage() {
        print("""
        TDRec — ghi Syphon ra ProRes, không rớt frame.

        Chạy không tham số  : mở giao diện.

        Tự kiểm tra (không cần TouchDesigner):
          --selftest              chạy kiểm tra đầu-cuối
          --width  <px>           mặc định 1920
          --height <px>           mặc định 1080
          --fps    <n>            mặc định 60
          --seconds <n>           mặc định 5
          --senderfps <n>         giả lập TD chỉ chạy được n fps (mặc định = --fps)
          --nowatermark           nguồn không có watermark (thử dương tính giả)

        Kiểm tra khác:
          --decodetest            kiểm tra bộ giải mã watermark
          --reconnecttest         kiểm tra chu trình nối → ngắt → nối lại
          --servers               liệt kê Syphon server đang phát
          --codec  <tên>          proxy | lt | 422 | hq | 4444
          --out    <đường dẫn>    file .mov để kiểm tra

        Ví dụ:
          TDRec --selftest --width 10990 --height 1080 --seconds 10 --codec hq
        """)
    }
}

struct TDRecApp: App {
    @StateObject private var engine = RecorderEngine()

    var body: some Scene {
        WindowGroup("TDRec") {
            ContentView().environmentObject(engine)
        }
        .windowResizability(.contentMinSize)
    }
}
