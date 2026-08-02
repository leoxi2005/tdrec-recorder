import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var engine: RecorderEngine

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                transportBar
                Divider().overlay(Theme.stroke)

                ScrollView {
                    VStack(spacing: 12) {
                        outputPanel
                        precisionPanel
                        audioPanel
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 700)
        .preferredColorScheme(.dark)
        .onAppear {
            // SwiftUI trao first responder cho ô text đầu tiên khi mở cửa sổ,
            // làm nó sáng viền xanh và cuộn view tới đó. Gỡ ra ngay.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    // MARK: - Thanh điều khiển trên cùng
    //
    // Đặt cố định ở đầu cửa sổ, không cuộn: khi đang chạy show người dùng chỉ
    // cần nhìn timecode và nút dừng, không phải cuộn tìm.

    private var transportBar: some View {
        VStack(spacing: 12) {
            sourceRow

            HStack(alignment: .center, spacing: 14) {
                StatusDot(color: stateColor, pulsing: engine.state == .recording)

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.state.label)
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(engine.state == .recording ? Theme.rec : Theme.text)
                    Text(engine.resolutionLabel)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }

                Spacer()

                Text(timecode(engine.recordedDuration))
                    .font(Theme.mono(30, .bold))
                    .foregroundStyle(engine.state == .recording ? Theme.rec : Theme.textFaint)
                    .contentTransition(.numericText())
            }

            recordButton

            if engine.state == .recording || engine.written > 0 {
                statsStrip
            }

            noticeStack
        }
        .padding(14)
        .background(Theme.panelHi)
    }

    private var recordButton: some View {
        Button(action: { engine.toggleRecording() }) {
            HStack(spacing: 8) {
                Image(systemName: engine.state == .recording ? "stop.fill" : "circle.fill")
                    .font(.system(size: engine.state == .recording ? 13 : 11))
                Text(engine.state == .recording ? "DỪNG GHI" : "BẮT ĐẦU GHI")
                    .font(Theme.ui(13, .bold))
                    .tracking(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(recordButtonEnabled
                          ? (engine.state == .recording ? Theme.rec : Theme.rec.opacity(0.88))
                          : Theme.stroke)
            )
            .foregroundStyle(recordButtonEnabled ? .white : Theme.textFaint)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!recordButtonEnabled)
    }

    private var recordButtonEnabled: Bool {
        engine.state == .connected || engine.state == .recording
    }

    private var statsStrip: some View {
        HStack(spacing: 0) {
            Metric(label: "ĐÃ GHI", value: "\(engine.written)", wide: true)
            Metric(label: "FPS NHẬN", value: String(format: "%.1f", engine.incomingFPS),
                   tint: fpsTint, wide: true)
            Metric(label: "BÙ", value: "\(engine.duplicated)",
                   tint: engine.duplicated > 0 ? Theme.warn : Theme.text)
            Metric(label: "BỎ (TRÙNG)", value: "\(engine.rejected)",
                   tint: engine.rejected > 0 ? Theme.warn : Theme.text)
            Metric(label: "BỎ TẠI NGUỒN", value: "\(engine.droppedAtSource)",
                   tint: engine.droppedAtSource > 0 ? Theme.alert : Theme.text)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bg.opacity(0.6))
        )
    }

    private var fpsTint: Color {
        guard engine.state == .recording, engine.incomingFPS > 0 else { return Theme.text }
        return engine.incomingFPS < Double(engine.fps) - 3 ? Theme.warn : Theme.ok
    }

    // MARK: - Thông báo

    @ViewBuilder private var noticeStack: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let reason = disabledReason {
                Notice(level: .info, text: reason)
            }
            if engine.counterStuck {
                Notice(level: .bad, text: "Số trong watermark không tăng. Trong GLSL TOP, uniform uFrame phải là expression absTime.frame (tab Vectors). Hoặc bỏ tick watermark bên dưới — app vẫn ghi đúng nhịp mà không cần nó.")
            }
            if engine.droppedAtSource > 0 {
                Notice(level: .warn, text: "Đĩa hoặc encoder đang tụt — frame bị bỏ ngay tại nguồn. Hạ codec xuống 422 HQ hoặc LT.")
            }
            if engine.duplicated > 0, engine.written > 0 {
                let pct = Double(engine.duplicated) / Double(engine.written) * 100
                Notice(level: .warn, text: String(format: "%.0f%% số frame là hình lặp — TouchDesigner không chạy đủ %d fps. Video vẫn đúng thời lượng và khớp nhạc, nhưng chuyển động kém mượt.", pct, engine.fps))
            }
            if engine.written > 0 && !engine.counterStuck
                && engine.droppedAtSource == 0 && engine.duplicated == 0 {
                Notice(level: .good, text: "Sạch — mỗi frame đều vào file, đúng nhịp.")
            }
            if !engine.lastMessage.isEmpty, engine.state != .recording {
                Notice(level: .info, text: engine.lastMessage)
            }
        }
    }

    private var disabledReason: String? {
        guard engine.state == .idle else { return nil }
        return engine.servers.isEmpty
            ? "Chưa ghi được: TouchDesigner không phát Syphon. Kiểm tra Syphon Spout Out TOP đã bật Active và có cook chưa, rồi bấm Refresh."
            : "Chưa ghi được: bấm Kết nối ở trên trước."
    }

    // MARK: - Nguồn

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("NGUỒN")
                    .font(Theme.ui(9, .semibold)).tracking(1.1)
                    .foregroundStyle(Theme.textFaint)

                Picker("", selection: Binding(
                    get: { engine.selectedServerUUID ?? "" },
                    set: { engine.selectedServerUUID = $0.isEmpty ? nil : $0 })) {
                        if engine.servers.isEmpty { Text("— không có nguồn —").tag("") }
                        ForEach(engine.servers, id: \.uuid) { Text($0.displayName).tag($0.uuid) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(engine.state == .recording)

                Button("Refresh") { engine.refreshServers() }
                    .disabled(engine.state == .recording)

                if engine.state == .idle {
                    Button("Kết nối") { engine.connect() }
                        .disabled(engine.selectedServerUUID == nil)
                } else {
                    Button("Ngắt") { engine.disconnect() }
                        .disabled(engine.state.isBusy)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Xuất file

    private var outputPanel: some View {
        Panel(title: "Xuất file") {
            Row(label: "Codec") {
                Picker("", selection: $engine.codec) {
                    ForEach(ProResWriter.Codec.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 190)
                .disabled(engine.state == .recording)
            }

            Row(label: "FPS", hint: "khớp FPS của TouchDesigner") {
                Picker("", selection: $engine.fps) {
                    ForEach([24, 25, 30, 48, 50, 60, 120], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 78)
                .disabled(engine.state == .recording)
            }

            Row(label: "Tên clip") {
                TextField("TDRec", text: $engine.clipName)
                    .textFieldStyle(.roundedBorder).frame(width: 190)
                    .disabled(engine.state == .recording)
            }

            Row(label: "Thư mục") {
                Text(engine.outputFolder.path)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1).truncationMode(.head)
                Button("Chọn…") { pickFolder() }
                    .controlSize(.small)
                    .disabled(engine.state == .recording)
            }

            diskBar
        }
    }

    private var diskBar: some View {
        let perMin = engine.estimatedGBPerMinute
        let mins = engine.estimatedMinutesLeft
        let tight = mins > 0 && mins < 15
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: tight ? "externaldrive.badge.exclamationmark" : "externaldrive")
                    .font(.system(size: 10))
                    .foregroundStyle(tight ? Theme.alert : Theme.textFaint)
                if perMin > 0 {
                    Text(String(format: "%.1f GB/phút", perMin))
                        .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(String(format: "trống %.0f GB", engine.freeSpaceGB))
                        .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(String(format: "ghi được ~%.0f phút", mins))
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(tight ? Theme.alert : Theme.textDim)
                } else {
                    Text(String(format: "trống %.0f GB", engine.freeSpaceGB))
                        .font(Theme.mono(10)).foregroundStyle(Theme.textDim)
                    Spacer()
                }
            }
            if perMin > 0 {
                GeometryReader { geo in
                    // Thanh biểu thị phần đĩa mà một tiếng ghi sẽ ăn mất.
                    let hourFrac = min(1.0, (perMin * 60) / max(engine.freeSpaceGB, 0.001))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.stroke)
                        Capsule().fill(tight ? Theme.alert : Theme.accent)
                            .frame(width: geo.size.width * hourFrac)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    // MARK: - Độ chính xác

    private var precisionPanel: some View {
        Panel(title: "Độ chính xác frame",
              accessory: AnyView(
                Group {
                    if engine.useWatermark {
                        HStack(spacing: 4) {
                            Image(systemName: engine.watermarkLocked ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 9))
                            Text(engine.watermarkLocked ? "đã bắt được" : "chưa thấy")
                                .font(Theme.ui(10))
                        }
                        .foregroundStyle(engine.watermarkLocked ? Theme.ok : Theme.textFaint)
                    }
                })) {

            Toggle(isOn: $engine.useWatermark) {
                Text("Đọc frame counter từ watermark").font(Theme.ui(12))
            }
            .toggleStyle(.switch).controlSize(.small)
            .disabled(engine.state == .recording)

            if engine.useWatermark {
                Row(label: "Block size", hint: "khớp uBlock trong GLSL TOP") {
                    Picker("", selection: $engine.watermarkBlockSize) {
                        ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .labelsHidden().frame(width: 78)
                    .disabled(engine.state == .recording)
                }
                Toggle(isOn: $engine.eraseWatermark) {
                    Text("Xoá vệt watermark khỏi file xuất").font(Theme.ui(12))
                }
                .toggleStyle(.switch).controlSize(.small)
                .disabled(engine.state == .recording)

                if engine.tdFramesRendered > 0 {
                    Notice(level: .info, text: "TouchDesigner đã render \(engine.tdFramesRendered) frame kể từ lúc bắt đầu ghi.")
                }
            } else {
                Notice(level: .info, text: "Không bắt buộc. Vị trí frame tính bằng đồng hồ thực nên video vẫn đúng thời lượng và khớp nhạc. Watermark chỉ thêm việc loại frame trùng và cho biết TD render được bao nhiêu.")
            }
        }
    }

    // MARK: - Nhạc

    private var audioPanel: some View {
        Panel(title: "Nhạc") {
            HStack(spacing: 8) {
                Text(engine.audioFileURL?.lastPathComponent ?? "— chưa chọn file —")
                    .font(Theme.ui(11))
                    .foregroundStyle(engine.audioFileURL == nil ? Theme.textFaint : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if engine.audioFileURL != nil {
                    Button("Bỏ") { engine.audioFileURL = nil }.controlSize(.small)
                }
                Button("Chọn…") { pickAudio() }.controlSize(.small)
            }

            Toggle(isOn: $engine.autoMux) {
                Text("Tự ghép nhạc sau khi ghi xong").font(Theme.ui(12))
            }
            .toggleStyle(.switch).controlSize(.small)
            .disabled(engine.audioFileURL == nil)

            Row(label: "Offset", hint: "giây — OSC sẽ ghi đè") {
                TextField("0.0", value: $engine.audioOffset, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 78)
            }

            Row(label: "OSC") {
                TextField("7400", value: $engine.oscPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Button("Áp dụng") { engine.restartOSC() }.controlSize(.small)
                StatusDot(color: engine.oscRunning ? Theme.ok : Theme.rec)
                Text(engine.oscRunning ? "đang nghe" : "tắt")
                    .font(Theme.ui(10)).foregroundStyle(Theme.textFaint)
            }

            if engine.lastOutputURL != nil {
                Button("Hiện file trong Finder") { engine.revealOutput() }
                    .controlSize(.small)
                    .disabled(engine.state.isBusy)
            }
        }
    }

    // MARK: - Helpers

    private var stateColor: Color {
        switch engine.state {
        case .idle: return Theme.textFaint
        case .connected: return Theme.ok
        case .recording: return Theme.rec
        case .finishing, .muxing: return Theme.warn
        }
    }

    private func timecode(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d.%02d",
                      total / 3600, (total % 3600) / 60, total % 60,
                      Int((t - Double(total)) * 100))
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = engine.outputFolder
        if p.runModal() == .OK, let url = p.url { engine.outputFolder = url }
    }

    private func pickAudio() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        if p.runModal() == .OK, let url = p.url { engine.audioFileURL = url }
    }
}
