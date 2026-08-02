import Foundation
import AVFoundation
import CoreVideo

/// Ghi CVPixelBuffer ra file ProRes bằng encoder phần cứng (VideoToolbox).
///
/// Điểm cốt lõi: file LUÔN là constant frame rate. Mỗi frame được đặt đúng vị
/// trí thời gian theo số frame của TouchDesigner. Nếu có frame bị mất giữa
/// chừng, ta chèn lại frame trước đó cho đủ chỗ — thà lặp 1 hình còn hơn để
/// toàn bộ video trôi khỏi nhạc.
final class ProResWriter: @unchecked Sendable {

    enum Codec: String, CaseIterable, Identifiable {
        case proxy    = "ProRes 422 Proxy"
        case lt       = "ProRes 422 LT"
        case standard = "ProRes 422"
        case hq       = "ProRes 422 HQ"
        case p4444    = "ProRes 4444 (có alpha)"

        var id: String { rawValue }

        var avCodec: AVVideoCodecType {
            switch self {
            case .proxy:    return .proRes422Proxy
            case .lt:       return .proRes422LT
            case .standard: return .proRes422
            case .hq:       return .proRes422HQ
            case .p4444:    return .proRes4444
            }
        }

        var hasAlpha: Bool { self == .p4444 }

        /// MB/s xấp xỉ ở 1920×1080@60 — dùng để ước lượng dung lượng.
        var mbPerSecAt1080p60: Double {
            switch self {
            case .proxy:    return 5.5
            case .lt:       return 12.5
            case .standard: return 18.0
            case .hq:       return 27.0
            case .p4444:    return 40.5
            }
        }
    }

    struct Stats {
        var written = 0          // frame thực sự ghi vào file
        var duplicated = 0       // frame chèn bù do TD/Syphon nuốt mất
        var rejected = 0         // frame đến trễ/trùng, bị bỏ
    }

    private let url: URL
    private let fps: Int32
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor!

    private let queue = DispatchQueue(label: "tdrec.writer", qos: .userInitiated)

    /// index frame kế tiếp cần ghi (theo trục thời gian của file, bắt đầu từ 0)
    private var nextIndex: Int64 = 0
    private var lastBuffer: CVPixelBuffer?
    private var finished = false

    private(set) var stats = Stats()
    private let statsLock = NSLock()

    /// Số frame bù tối đa cho một lỗ hổng. Nếu TD treo vài giây, ta không muốn
    /// ghi hàng nghìn frame lặp — cắt ở đây và báo lỗi rõ ràng.
    private let maxGapFill = 240

    init(url: URL, width: Int, height: Int, fps: Int, codec: Codec) throws {
        self.url = url
        self.fps = Int32(fps)

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var settings: [String: Any] = [
            AVVideoCodecKey:  codec.avCodec,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
        ]
        // Gắn thẻ màu Rec.709 để Resolve/Premiere/QuickTime diễn giải giống nhau.
        settings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]

        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // Bắt buộc: báo cho AVFoundation biết đây là nguồn realtime, nó sẽ ưu
        // tiên không chặn và tự bỏ qua tối ưu hoá cần buffer toàn bộ.
        input.expectsMediaDataInRealTime = true

        let srcAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: srcAttrs)

        guard writer.canAdd(input) else {
            throw NSError(domain: "TDRec", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Không thêm được video input — \(codec.rawValue) ở \(width)×\(height) có thể vượt khả năng encoder."
            ])
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "TDRec", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "startWriting() thất bại."
            ])
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Nạp một frame. `tdIndex` là số frame đã chuẩn hoá về 0 tại lúc bắt đầu ghi.
    /// Gọi từ thread nào cũng được; xử lý thật diễn ra trên queue riêng.
    func append(_ buffer: CVPixelBuffer, tdIndex: Int64) {
        queue.async { [weak self] in self?.appendSync(buffer, tdIndex: tdIndex) }
    }

    private func appendSync(_ buffer: CVPixelBuffer, tdIndex: Int64) {
        guard !finished, writer.status == .writing else { return }

        // Frame đến trễ hoặc trùng số với frame đã ghi → bỏ.
        if tdIndex < nextIndex {
            bump { $0.rejected += 1 }
            return
        }

        // Lấp lỗ hổng bằng frame gần nhất để giữ constant frame rate.
        if tdIndex > nextIndex, let last = lastBuffer {
            let gap = Int(tdIndex - nextIndex)
            let fill = min(gap, maxGapFill)
            for _ in 0..<fill {
                guard waitForReady() else { return }
                if adaptor.append(last, withPresentationTime: time(nextIndex)) {
                    nextIndex += 1
                    bump { $0.duplicated += 1; $0.written += 1 }
                }
            }
            // Nếu lỗ hổng quá lớn, nhảy thẳng tới vị trí mới thay vì ghi hàng
            // nghìn frame lặp (TD chắc chắn đã treo hoặc bị stop).
            if gap > maxGapFill { nextIndex = tdIndex }
        }

        guard waitForReady() else { return }
        if adaptor.append(buffer, withPresentationTime: time(nextIndex)) {
            nextIndex += 1
            lastBuffer = buffer
            bump { $0.written += 1 }
        } else {
            bump { $0.rejected += 1 }
        }
    }

    /// Chờ input sẵn sàng. Có trần thời gian để không treo vĩnh viễn nếu
    /// encoder chết.
    private func waitForReady() -> Bool {
        var spins = 0
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing { return false }
            if spins > 2000 { return false }        // ~2 giây
            usleep(1000)
            spins += 1
        }
        return true
    }

    private func time(_ index: Int64) -> CMTime {
        CMTime(value: index, timescale: fps)
    }

    private func bump(_ mutate: (inout Stats) -> Void) {
        statsLock.lock(); mutate(&stats); statsLock.unlock()
    }

    func currentStats() -> Stats {
        statsLock.lock(); defer { statsLock.unlock() }; return stats
    }

    var duration: Double { Double(nextIndex) / Double(fps) }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.input.markAsFinished()
            self.writer.finishWriting {
                if self.writer.status == .completed {
                    completion(.success(self.url))
                } else {
                    completion(.failure(self.writer.error ?? NSError(
                        domain: "TDRec", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "finishWriting thất bại."])))
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.writer.cancelWriting()
        }
    }
}
