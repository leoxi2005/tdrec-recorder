import Foundation
import CoreVideo

/// Xử lý từng frame trên một serial queue riêng.
///
/// Vì sao không dùng main actor: ở 10990×1080@60 có 60 frame/giây đi qua đây.
/// Đẩy qua main thread vừa làm giật UI, vừa KHÔNG đảm bảo thứ tự — mà sai thứ
/// tự frame thì video hỏng. Serial queue cho ta thứ tự tuyệt đối và tách hẳn
/// khỏi UI.
///
/// ── Vị trí frame trên trục thời gian ────────────────────────────────────
/// Dùng ĐỒNG HỒ THỰC, không dùng số đếm frame của TouchDesigner.
///
/// Lý do: `absTime.frame` tăng 1 đơn vị mỗi lần TD render xong, không phải mỗi
/// 1/60 giây. Nếu TD chỉ chạy được 34fps thì trong 1 giây thực nó chỉ tăng 34 —
/// đặt 34 frame đó vào trục 60fps sẽ ra 0.57 giây video, tức là hình chạy
/// nhanh hơn thực tế và trôi khỏi nhạc.
///
/// Đặt theo đồng hồ thực thì mỗi frame nằm đúng chỗ nó xuất hiện, chỗ trống do
/// TD rớt frame được ProResWriter chèn bù. Video luôn khớp nhạc bất kể TD chạy
/// nhanh chậm ra sao.
///
/// Watermark vẫn cần, nhưng đổi vai trò: dùng để nhận ra frame Syphon phát lại
/// y hệt (tránh ghi trùng) và để báo cho người dùng biết TD đang rớt bao nhiêu.
final class FramePipeline: @unchecked Sendable {

    struct Config {
        var useWatermark = true
        var blockSize = 2
        var eraseWatermark = true
        var fps = 60
    }

    struct Status {
        var watermarkLocked = false
        var watermarkOrigin: Watermark.Origin = .top
        /// Số frame liên tiếp giải mã watermark thất bại.
        var decodeFailures = 0
        /// Watermark đọc được nhưng con số KHÔNG BAO GIỜ đổi — dấu hiệu người
        /// dùng quên nối uniform uFrame vào absTime.frame trong GLSL TOP.
        var counterStuck = false
        /// Số frame TD render được kể từ lúc bắt đầu ghi (đếm theo watermark).
        var tdFramesRendered = 0
    }

    private let queue = DispatchQueue(label: "tdrec.frames", qos: .userInitiated)
    private let lock = NSLock()

    private var _config = Config()
    private var _status = Status()

    var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }
    var status: Status {
        lock.lock(); defer { lock.unlock() }; return _status
    }

    // --- state chỉ được chạm trên `queue` ---
    private var writer: ProResWriter?
    private var startHostTime: UInt64 = 0
    private var lastAssignedIndex: Int64 = -1
    private var originLocked = false
    private var origin: Watermark.Origin = .top
    private var consecutiveFailures = 0

    private var lastTDFrame: UInt32?
    private var counterEverChanged = false
    private var sameCounterRun = 0
    private var tdFrameCount = 0

    private var timebase = mach_timebase_info_data_t()

    init() { mach_timebase_info(&timebase) }

    func submit(_ frame: SyphonSource.Frame) {
        queue.async { [weak self] in
            self?.process(frame.pixelBuffer, hostTime: frame.hostTime)
        }
    }

    func beginRecording(writer: ProResWriter) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writer = writer
            self.startHostTime = 0          // frame đầu tiên sẽ đặt mốc
            self.lastAssignedIndex = -1
            self.lastTDFrame = nil
            self.counterEverChanged = false
            self.sameCounterRun = 0
            self.tdFrameCount = 0
            self.setStatus { $0.counterStuck = false; $0.tdFramesRendered = 0 }
        }
    }

    func endRecording() {
        queue.async { [weak self] in self?.writer = nil }
    }

    func resetWatermarkLock() {
        queue.async { [weak self] in
            guard let self else { return }
            self.originLocked = false
            self.consecutiveFailures = 0
            self.setStatus { $0.watermarkLocked = false; $0.decodeFailures = 0 }
        }
    }

    // MARK: - Xử lý

    private func process(_ pb: CVPixelBuffer, hostTime: UInt64) {
        let cfg = config
        var tdFrame: UInt32?

        if cfg.useWatermark {
            tdFrame = readAndEraseWatermark(pb, cfg: cfg)
        }

        guard let writer else { return }

        // Bỏ frame Syphon phát lại y hệt (cùng số watermark). Chỉ áp dụng khi
        // bộ đếm thực sự có thay đổi — nếu nó đứng yên thì đó là lỗi cấu hình
        // uFrame, lúc đó bỏ theo watermark sẽ nuốt sạch mọi frame.
        if let td = tdFrame {
            if let last = lastTDFrame {
                if td == last {
                    sameCounterRun += 1
                    // Đứng yên quá 30 frame liên tiếp = chắc chắn uFrame sai.
                    if sameCounterRun > 30 && !counterEverChanged {
                        setStatus { $0.counterStuck = true }
                    }
                    if counterEverChanged { return }   // trùng thật → bỏ
                } else {
                    counterEverChanged = true
                    sameCounterRun = 0
                    tdFrameCount += 1
                    setStatus { $0.counterStuck = false; $0.tdFramesRendered = self.tdFrameCount }
                }
            }
            lastTDFrame = td
        }

        // Mốc thời gian: frame đầu tiên của lần ghi = index 0.
        if startHostTime == 0 { startHostTime = hostTime }
        let elapsed = seconds(from: startHostTime, to: hostTime)
        var index = max(0, Int64((elapsed * Double(cfg.fps)).rounded()))

        // Chống va chạm do jitter: hai frame đến sát nhau có thể làm tròn về
        // cùng một ô. Nếu vứt frame sau đi thì lại phải chèn hình lặp vào ô kế,
        // vừa mất frame thật vừa kém mượt. Đẩy nó sang ô kế tiếp thì giữ được
        // cả hai và tự khớp lại ở frame sau.
        if index <= lastAssignedIndex {
            let pushed = lastAssignedIndex + 1
            // Nhưng KHÔNG đẩy vô hạn: nếu nguồn thực sự nhanh hơn nhịp ghi
            // (vd TD 60fps mà ghi 30fps) thì đẩy mãi sẽ làm video dài ra và
            // trôi khỏi nhạc. Quá 2 ô so với vị trí thật thì bỏ frame.
            if pushed > index + 2 { return }
            index = pushed
        }
        lastAssignedIndex = index

        writer.append(pb, tdIndex: index)
    }

    private func seconds(from a: UInt64, to b: UInt64) -> Double {
        guard b > a else { return 0 }
        let ns = Double(b - a) * Double(timebase.numer) / Double(timebase.denom)
        return ns / 1_000_000_000
    }

    private func readAndEraseWatermark(_ pb: CVPixelBuffer, cfg: Config) -> UInt32? {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        var value: UInt32?

        if originLocked {
            value = Watermark.decode(base: base, bytesPerRow: bpr, width: w, height: h,
                                     blockSize: cfg.blockSize, origin: origin)
        } else {
            // Syphon/Metal có thể lật dọc tuỳ nguồn — dò cả hai đầu rồi khoá lại.
            for candidate in [Watermark.Origin.top, .bottom] {
                if let v = Watermark.decode(base: base, bytesPerRow: bpr, width: w, height: h,
                                            blockSize: cfg.blockSize, origin: candidate) {
                    origin = candidate
                    originLocked = true
                    value = v
                    setStatus { $0.watermarkLocked = true; $0.watermarkOrigin = candidate }
                    break
                }
            }
        }

        if value != nil {
            if consecutiveFailures != 0 {
                consecutiveFailures = 0
                setStatus { $0.decodeFailures = 0 }
            }
            if cfg.eraseWatermark {
                Watermark.erase(base: base, bytesPerRow: bpr, width: w, height: h,
                                blockSize: cfg.blockSize, origin: origin)
            }
        } else {
            consecutiveFailures += 1
            let n = consecutiveFailures
            if n % 30 == 0 { setStatus { $0.decodeFailures = n } }
        }

        return value
    }

    private func setStatus(_ mutate: (inout Status) -> Void) {
        lock.lock(); mutate(&_status); lock.unlock()
    }
}
