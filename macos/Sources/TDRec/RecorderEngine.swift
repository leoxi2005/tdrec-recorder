import Foundation
import SwiftUI
import AppKit
import CoreVideo
import SyphonBridge

@MainActor
final class RecorderEngine: ObservableObject {

    enum State: Equatable {
        case idle, connected, recording, finishing, muxing

        var label: String {
            switch self {
            case .idle:      return "Chưa kết nối"
            case .connected: return "Sẵn sàng"
            case .recording: return "ĐANG GHI"
            case .finishing: return "Đang đóng file…"
            case .muxing:    return "Đang ghép nhạc…"
            }
        }
        var isBusy: Bool { self == .finishing || self == .muxing }
    }

    // MARK: - Published

    @Published private(set) var state: State = .idle
    @Published private(set) var servers: [TDSyphonServer] = []
    @Published var selectedServerUUID: String?

    @Published private(set) var sourceWidth = 0
    @Published private(set) var sourceHeight = 0
    @Published private(set) var incomingFPS: Double = 0
    @Published private(set) var recordedDuration: Double = 0
    @Published private(set) var written = 0
    @Published private(set) var duplicated = 0
    @Published private(set) var rejected = 0
    @Published private(set) var droppedAtSource = 0
    @Published private(set) var watermarkLocked = false
    @Published private(set) var watermarkFailures = 0
    @Published private(set) var counterStuck = false
    @Published private(set) var tdFramesRendered = 0
    @Published private(set) var freeSpaceGB: Double = 0
    @Published private(set) var estimatedMinutesLeft: Double = 0
    @Published private(set) var lastMessage = "Mở TouchDesigner và bật Syphon Spout Out TOP."
    @Published private(set) var lastOutputURL: URL?

    // MARK: - Cài đặt

    @Published var codec: ProResWriter.Codec = .hq { didSet { updateDiskEstimate() } }
    @Published var fps: Int = 60 { didSet { updateDiskEstimate(); pushConfig() } }
    @Published var outputFolder: URL {
        didSet { updateDiskEstimate() }
    }
    @Published var clipName = "TDRec"

    @Published var useWatermark = true { didSet { pushConfig() } }
    @Published var watermarkBlockSize = 2 { didSet { pushConfig(); pipeline.resetWatermarkLock() } }
    @Published var eraseWatermark = true { didSet { pushConfig() } }

    @Published var audioFileURL: URL?
    @Published var audioOffset: Double = 0
    @Published var autoMux = true

    @Published var oscPort: UInt16 = 7400
    @Published private(set) var oscRunning = false

    // MARK: - Nội bộ

    private var source: SyphonSource?
    private let pipeline = FramePipeline()
    private var writer: ProResWriter?
    private let osc = OSCServer()

    private let fpsMeter = FPSMeter()
    private let dropCounter = Counter()

    private var uiTimer: Timer?
    private var pendingAudioOffset: Double?

    init() {
        outputFolder = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())

        setupSource()
        pushConfig()
        refreshServers()

        SyphonSource.observeServers { [weak self] in
            Task { @MainActor in self?.refreshServers() }
        }
        startOSC()
        updateDiskEstimate()

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Syphon

    private func setupSource() {
        guard let s = SyphonSource() else {
            lastMessage = "Không khởi tạo được Metal — app không chạy được trên máy này."
            return
        }
        s.onResolutionChange = { [weak self] w, h in
            Task { @MainActor in
                self?.sourceWidth = w
                self?.sourceHeight = h
                self?.updateDiskEstimate()
            }
        }
        // Hai closure này chạy trên thread của Metal, không phải main actor —
        // nên chỉ được chạm vào đối tượng tự khoá (FPSMeter, Counter, pipeline).
        let meter = fpsMeter
        let drops = dropCounter
        let pipe = pipeline
        s.onFrame = { frame in
            meter.mark(frame.hostTime)
            pipe.submit(frame)
        }
        s.onDrop = { drops.increment() }
        source = s
    }

    func refreshServers() {
        servers = SyphonSource.servers()
        if let sel = selectedServerUUID, !servers.contains(where: { $0.uuid == sel }) {
            if state == .recording { stopRecording() }
            selectedServerUUID = servers.first?.uuid
            source?.disconnect()
            if state != .idle { state = .idle }
            lastMessage = "Syphon server đã biến mất."
        } else if selectedServerUUID == nil {
            selectedServerUUID = servers.first?.uuid
        }
    }

    func connect() {
        guard let uuid = selectedServerUUID, let source else {
            lastMessage = "Chưa chọn Syphon server. Bấm Refresh."
            return
        }
        pipeline.resetWatermarkLock()
        if source.connect(uuid: uuid) {
            state = .connected
            lastMessage = "Đã kết nối \(servers.first { $0.uuid == uuid }?.displayName ?? uuid)"
        } else {
            lastMessage = "Kết nối thất bại — thử Refresh rồi chọn lại."
        }
    }

    func disconnect() {
        if state == .recording { stopRecording() }
        source?.disconnect()
        state = .idle
        sourceWidth = 0; sourceHeight = 0
        lastMessage = "Đã ngắt kết nối."
    }

    private func pushConfig() {
        pipeline.config = .init(useWatermark: useWatermark,
                                blockSize: watermarkBlockSize,
                                eraseWatermark: eraseWatermark,
                                fps: fps)
    }

    // MARK: - Ghi

    func startRecording() {
        guard state == .connected else {
            lastMessage = "Phải kết nối Syphon trước."
            return
        }
        guard sourceWidth > 0, sourceHeight > 0 else {
            lastMessage = "Chưa nhận được frame nào từ TouchDesigner."
            return
        }
        // ProRes yêu cầu chiều rộng chẵn; TD có thể xuất số lẻ (vd 10990 thì ok,
        // nhưng 10991 sẽ hỏng), nên chặn sớm với thông báo rõ ràng.
        guard sourceWidth % 2 == 0, sourceHeight % 2 == 0 else {
            lastMessage = "Độ phân giải \(sourceWidth)×\(sourceHeight) có cạnh lẻ — ProRes cần cạnh chẵn. Chỉnh lại res trong TD."
            return
        }

        let stamp = Self.timestamp()
        let name = clipName.trimmingCharacters(in: .whitespaces).isEmpty ? "TDRec" : clipName
        let url = outputFolder.appendingPathComponent("\(name)_\(stamp).mov")

        do {
            let w = try ProResWriter(url: url, width: sourceWidth, height: sourceHeight,
                                     fps: fps, codec: codec)
            writer = w
            pipeline.beginRecording(writer: w)
        } catch {
            lastMessage = "Không tạo được file: \(error.localizedDescription)"
            return
        }

        dropCounter.reset()
        fpsMeter.reset()
        written = 0; duplicated = 0; rejected = 0; droppedAtSource = 0
        state = .recording
        lastMessage = "Đang ghi → \(url.lastPathComponent)"
    }

    func stopRecording() {
        guard state == .recording, let w = writer else { return }
        state = .finishing
        pipeline.endRecording()

        w.finish { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.writer = nil
                switch result {
                case .success(let url):
                    self.lastOutputURL = url
                    if self.autoMux, let audio = self.audioFileURL {
                        self.runMux(video: url, audio: audio)
                    } else {
                        self.state = .connected
                        self.lastMessage = "Xong: \(url.lastPathComponent)"
                    }
                case .failure(let err):
                    self.state = .connected
                    self.lastMessage = "Lỗi đóng file: \(err.localizedDescription)"
                }
            }
        }
    }

    func toggleRecording() {
        switch state {
        case .connected: startRecording()
        case .recording: stopRecording()
        default: break
        }
    }

    private func runMux(video: URL, audio: URL) {
        state = .muxing
        let offset = pendingAudioOffset ?? audioOffset
        pendingAudioOffset = nil
        lastMessage = "Ghép nhạc (offset \(String(format: "%.3f", offset))s)…"

        AudioMux.mux(video: video, audio: audio, offset: offset,
                     deleteVideoOnSuccess: false) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.state = .connected
                switch result {
                case .success(let r):
                    self.lastOutputURL = r.outputURL
                    self.lastMessage = "Xong (kèm nhạc): \(r.outputURL.lastPathComponent)"
                case .failure(let e):
                    self.lastMessage = "Video OK, mux nhạc lỗi: \(e.localizedDescription)"
                }
            }
        }
    }

    func revealOutput() {
        guard let url = lastOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - OSC

    func startOSC() {
        osc.onMessage = { [weak self] addr, args in
            Task { @MainActor in self?.handleOSC(addr, args) }
        }
        do {
            try osc.start(port: oscPort)
            oscRunning = true
        } catch {
            oscRunning = false
            lastMessage = "OSC không mở được port \(oscPort): \(error.localizedDescription)"
        }
    }

    func restartOSC() { osc.stop(); startOSC() }

    private func handleOSC(_ address: String, _ args: [OSCServer.Argument]) {
        switch address {
        case "/tdrec/start":
            if let off = args.first?.asDouble { pendingAudioOffset = off }
            if state == .connected { startRecording() }
        case "/tdrec/stop":
            if state == .recording { stopRecording() }
        case "/tdrec/name":
            if let n = args.first?.asString, !n.isEmpty { clipName = n }
        default: break
        }
    }

    // MARK: - Nhịp cập nhật UI

    private func tick() {
        incomingFPS = fpsMeter.current()

        let st = pipeline.status
        watermarkLocked = st.watermarkLocked
        watermarkFailures = st.decodeFailures
        counterStuck = st.counterStuck
        tdFramesRendered = st.tdFramesRendered

        if let w = writer {
            let s = w.currentStats()
            written = s.written
            duplicated = s.duplicated
            rejected = s.rejected
            recordedDuration = w.duration
        }

        droppedAtSource = dropCounter.value
        updateDiskEstimate()
    }

    // MARK: - Dung lượng

    private func updateDiskEstimate() {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: outputFolder.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            freeSpaceGB = free.doubleValue / 1_073_741_824
        }
        let perMin = estimatedGBPerMinute
        estimatedMinutesLeft = perMin > 0 ? freeSpaceGB / perMin : 0
    }

    /// Ước lượng dung lượng theo bitrate danh nghĩa của ProRes, quy đổi tuyến
    /// tính theo số pixel và fps. Sai số thực tế khoảng ±15% tuỳ nội dung.
    var estimatedGBPerMinute: Double {
        guard sourceWidth > 0, sourceHeight > 0 else { return 0 }
        let pixelRatio = Double(sourceWidth * sourceHeight) / (1920.0 * 1080.0)
        let fpsRatio = Double(fps) / 60.0
        let mbPerSec = codec.mbPerSecAt1080p60 * pixelRatio * fpsRatio
        return mbPerSec * 60 / 1024
    }

    var resolutionLabel: String {
        sourceWidth > 0 ? "\(sourceWidth) × \(sourceHeight)" : "—"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
