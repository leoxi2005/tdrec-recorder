import Foundation
import Metal
import CoreVideo
import SyphonBridge

/// Bộ tự kiểm tra chạy không cần TouchDesigner.
///
/// Nó dựng một Syphon server thật, phát ra chuỗi frame có đánh số bằng đúng
/// watermark mà GLSL TOP trong TD sẽ tạo, rồi cho chính đường ống của app thu
/// lại. Sau đó đối chiếu số frame ghi được với số frame đã phát.
///
/// Mục đích: chứng minh phần Syphon → watermark → ProRes hoạt động chính xác,
/// tách biệt khỏi mọi vấn đề có thể đến từ project TouchDesigner.
enum SelfTest {

    struct Options {
        var width = 1920
        var height = 1080
        var fps = 60
        /// FPS mà bên phát (giả lập TD) thực sự đạt được. Khác `fps` để mô
        /// phỏng trường hợp TouchDesigner không chạy đủ nhịp mục tiêu.
        var senderFPS: Int? = nil
        var seconds = 5
        var codec: ProResWriter.Codec = .hq
        var blockSize = 2
        /// Có vẽ watermark hay không. Đặt false để mô phỏng project chưa gắn
        /// GLSL TOP — app phải nhận ra là KHÔNG có watermark, tuyệt đối không
        /// được đọc nhầm vùng ảnh phẳng thành watermark hợp lệ.
        var paintWatermark = true
        var output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tdrec_selftest.mov")
    }

    static func run(_ opt: Options) -> Int32 {
        print("── TDRec self-test ──────────────────────────────")
        let sendFPS = opt.senderFPS ?? opt.fps
        print("  \(opt.width)×\(opt.height) · ghi \(opt.fps)fps · nguồn phát \(sendFPS)fps · \(opt.seconds)s · \(opt.codec.rawValue)")
        print("  output: \(opt.output.path)\n")

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            print("✗ Không tạo được Metal device"); return 1
        }

        // --- Bên phát: đóng vai TouchDesigner ---
        let senderName = "TDRecSelfTest"
        guard let publisher = TDSyphonPublisher(name: senderName, device: device) else {
            print("✗ Không tạo được Syphon server"); return 1
        }
        guard let painter = WatermarkPainter(device: device, queue: queue,
                                             width: opt.width, height: opt.height,
                                             blockSize: opt.paintWatermark ? opt.blockSize : 0) else {
            print("✗ Không tạo được painter"); return 1
        }

        // --- Bên thu: chính đường ống của app ---
        guard let source = SyphonSource() else {
            print("✗ Không tạo được SyphonSource"); return 1
        }
        let pipeline = FramePipeline()
        pipeline.config = .init(useWatermark: true, blockSize: opt.blockSize,
                                eraseWatermark: true, fps: opt.fps)

        let drops = Counter()
        let received = Counter()
        source.onDrop = { drops.increment() }
        source.onFrame = { frame in
            received.increment()
            pipeline.submit(frame)
        }

        // Chờ server xuất hiện trong directory rồi mới nối vào.
        var uuid: String?
        for _ in 0..<50 {
            if let s = SyphonSource.servers().first(where: { $0.serverName == senderName }) {
                uuid = s.uuid; break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let uuid else { print("✗ Server không xuất hiện trong Syphon directory"); return 1 }
        guard source.connect(uuid: uuid) else { print("✗ Không kết nối được"); return 1 }
        print("✓ Đã kết nối tới \(senderName)")

        // Phát vài frame mồi để pool khởi tạo đúng kích thước trước khi ghi.
        for i in 0..<10 {
            if let tex = painter.render(frame: UInt32(i)) { publisher.publishTexture(tex) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        let writer: ProResWriter
        do {
            writer = try ProResWriter(url: opt.output, width: opt.width, height: opt.height,
                                      fps: opt.fps, codec: opt.codec)
        } catch {
            print("✗ Không tạo được writer: \(error.localizedDescription)"); return 1
        }
        pipeline.beginRecording(writer: writer)

        // --- Phát đúng nhịp fps ---
        let total = sendFPS * opt.seconds
        let interval = 1.0 / Double(sendFPS)
        let start = Date()
        var sent = 0

        for i in 0..<total {
            let target = start.addingTimeInterval(Double(i) * interval)
            let now = Date()
            if target > now { RunLoop.current.run(until: target) }

            // Bắt đầu từ 1000 để chắc chắn app xử lý đúng việc chuẩn hoá gốc.
            if let tex = painter.render(frame: UInt32(1000 + i)) {
                publisher.publishTexture(tex)
                sent += 1
            }
        }

        // Cho những frame cuối kịp đi hết đường ống.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        pipeline.endRecording()

        let sema = DispatchSemaphore(value: 0)
        var writeError: Error?
        writer.finish { result in
            if case .failure(let e) = result { writeError = e }
            sema.signal()
        }
        // finishWriting cần chạy runloop để callback về
        while sema.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        source.disconnect()
        publisher.stop()

        if let e = writeError {
            print("✗ Lỗi ghi file: \(e.localizedDescription)"); return 1
        }

        // --- Đối chiếu ---
        let stats = writer.currentStats()
        let st = pipeline.status
        let elapsed = Date().timeIntervalSince(start)

        print("""

        ── Kết quả ──────────────────────────────────────
          Đã phát (giả lập TD) : \(sent)
          App nhận được        : \(received.value)
          Ghi vào file         : \(stats.written)
          Chèn bù frame thiếu  : \(stats.duplicated)
          Bỏ vì trùng/trễ      : \(stats.rejected)
          Bỏ tại nguồn (pool)  : \(drops.value)
          Watermark            : \(st.watermarkLocked ? "ĐỌC ĐƯỢC (\(st.watermarkOrigin))" : "KHÔNG ĐỌC ĐƯỢC")
          Thời gian thực tế    : \(String(format: "%.2f", elapsed))s
        """)

        // Điều PHẢI đúng: thời lượng video khớp thời gian thực đã trôi qua.
        // Đây mới là thứ quyết định video có khớp nhạc hay không.
        let videoDuration = Double(stats.written) / Double(opt.fps)
        let realDuration = Double(opt.seconds)
        let driftMs = (videoDuration - realDuration) * 1000

        print(String(format: "  Thời lượng video      : %.3fs (thực tế phát %.3fs, lệch %+.0f ms)",
                     videoDuration, realDuration, driftMs))

        var failures: [String] = []
        if opt.paintWatermark {
            if !st.watermarkLocked { failures.append("không giải mã được watermark") }
            if st.counterStuck { failures.append("bộ đếm watermark đứng yên") }
        } else {
            // Đây là phép thử dương-tính-giả: nguồn KHÔNG có watermark.
            if st.watermarkLocked {
                failures.append("DƯƠNG TÍNH GIẢ — nguồn không có watermark nhưng app báo đọc được")
            }
            if st.counterStuck {
                failures.append("DƯƠNG TÍNH GIẢ — báo 'counter đứng yên' dù nguồn không có watermark")
            }
        }
        if abs(driftMs) > 100 {
            failures.append(String(format: "video lệch %.0f ms so với thời gian thực → sẽ trôi khỏi nhạc", driftMs))
        }
        if drops.value > 0 { failures.append("\(drops.value) frame bị bỏ tại nguồn") }
        // Khi nguồn chậm hơn nhịp ghi, chèn bù là ĐÚNG — chỉ báo lỗi nếu bù
        // nhiều hơn mức lý thuyết.
        let expectedFill = max(0, opt.fps - sendFPS) * opt.seconds
        if stats.duplicated > expectedFill + opt.fps / 2 {
            failures.append("chèn bù \(stats.duplicated) frame, nhiều hơn mức dự kiến \(expectedFill)")
        }

        if failures.isEmpty {
            print("\n✓ ĐẠT — đường ống ghi chính xác từng frame.\n")
            return 0
        } else {
            print("\n✗ KHÔNG ĐẠT:")
            for f in failures { print("   • \(f)") }
            print("")
            return 1
        }
    }
}


/// Vẽ frame test: nền gradient chuyển động + watermark số frame ở góc trên-trái,
/// tạo bằng đúng quy ước mà GLSL TOP phía TouchDesigner dùng.
final class WatermarkPainter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let texture: MTLTexture
    private let blockSize: Int

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void paint(texture2d<float, access::write> dst [[texture(0)]],
                      constant uint &frame [[buffer(0)]],
                      constant uint &blockSize [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
        uint w = dst.get_width(), h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;

        // nền: gradient chạy theo số frame để mỗi frame khác nhau rõ rệt
        float t = float(frame % 256) / 255.0;
        float4 c = float4(float(gid.x) / float(w), float(gid.y) / float(h), t, 1.0);

        // watermark: 40 block ở hàng trên cùng — phải khớp đúng layout của
        // td/tdrec_watermark.frag, nếu không self-test sẽ kiểm tra sai thứ.
        if (blockSize > 0u && gid.y < blockSize && gid.x < blockSize * 40u) {
            uint bit = gid.x / blockSize;
            uint counter = frame & 0xFFFFFFu;
            uint cksum = (counter ^ (counter >> 8) ^ (counter >> 16)) & 0xFFu;
            float v;
            if (bit < 8u)       v = ((0xB4u   >> bit)        & 1u) ? 1.0 : 0.0;
            else if (bit < 32u) v = ((counter >> (bit - 8u)) & 1u) ? 1.0 : 0.0;
            else                v = ((cksum   >> (bit - 32u))& 1u) ? 1.0 : 0.0;
            c = float4(v, v, v, 1.0);
        }
        dst.write(c, gid);
    }
    """

    init?(device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int, blockSize: Int) {
        self.device = device
        self.queue = queue
        self.blockSize = blockSize

        guard let lib = try? device.makeLibrary(source: Self.shader, options: nil),
              let fn = lib.makeFunction(name: "paint"),
              let ps = try? device.makeComputePipelineState(function: fn) else { return nil }
        pipeline = ps

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        texture = t
    }

    func render(frame: UInt32) -> MTLTexture? {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        var f = frame
        var b = UInt32(blockSize)
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        enc.setBytes(&f, length: 4, index: 0)
        enc.setBytes(&b, length: 4, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (texture.width + 15) / 16,
                             height: (texture.height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return texture
    }
}


/// Kiểm tra chu trình nối → ngắt → nối lại → ghi.
///
/// Lỗi từng gặp: disconnect() không xoá kích thước pool, nên khi nối lại đúng
/// nguồn cũ thì onResolutionChange không bắn, engine tưởng chưa nhận frame nào
/// và từ chối cho ghi. Lần đầu chạy được, lần thứ hai thì không.
enum ReconnectTest {

    static func run() -> Int32 {
        print("── Kiem tra noi → ngat → noi lai ────────────────\n")

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let publisher = TDSyphonPublisher(name: "TDRecReconnect", device: device),
              let painter = WatermarkPainter(device: device, queue: queue,
                                             width: 1920, height: 1080, blockSize: 2),
              let source = SyphonSource() else {
            print("✗ Khong khoi tao duoc"); return 1
        }

        var reportedSizes: [String] = []
        source.onResolutionChange = { w, h in
            reportedSizes.append("\(w)x\(h)")
        }
        source.onFrame = { _ in }

        // Chờ server xuất hiện.
        var uuid: String?
        for _ in 0..<50 {
            if let s = SyphonSource.servers().first(where: { $0.serverName == "TDRecReconnect" }) {
                uuid = s.uuid; break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let uuid else { print("✗ Server khong xuat hien"); return 1 }

        var failures: [String] = []

        // Lặp 3 vòng: mỗi vòng nối, nhận frame, rồi ngắt.
        for round in 1...3 {
            guard source.connect(uuid: uuid) else {
                failures.append("vong \(round): khong noi duoc"); break
            }

            let before = reportedSizes.count
            for i in 0..<20 {
                if let tex = painter.render(frame: UInt32(round * 1000 + i)) {
                    publisher.publishTexture(tex)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }

            let got = reportedSizes.count - before
            let ok = got >= 1 && source.sourceWidth == 1920 && source.sourceHeight == 1080
            print("  vong \(round): bao kich thuoc \(got) lan, sourceWidth=\(source.sourceWidth) → \(ok ? "OK" : "HONG")")
            if !ok {
                failures.append("vong \(round): khong bao lai kich thuoc sau khi noi lai")
            }

            source.disconnect()
            if source.sourceWidth != 0 {
                failures.append("vong \(round): disconnect khong xoa sourceWidth")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        publisher.stop()

        if failures.isEmpty {
            print("\n✓ DAT — noi lai bao nhieu lan cung ghi duoc.\n")
            return 0
        }
        print("\n✗ KHONG DAT:")
        for f in failures { print("   • \(f)") }
        print("")
        return 1
    }
}
