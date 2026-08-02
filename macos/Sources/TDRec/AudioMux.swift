import Foundation

/// Ghép file nhạc gốc vào video đã record bằng ffmpeg.
///
/// Vì sao mux thay vì thu lại audio: file nhạc gốc được chép nguyên si vào
/// container, KHÔNG hề re-encode → chất lượng bit-exact 100%, và không có
/// hiện tượng trôi do audio clock lệch video clock.
///
/// `offset` là vị trí phát của bài nhạc tại đúng thời điểm frame đầu tiên được
/// ghi (TouchDesigner gửi qua OSC). ffmpeg cắt từ đó nên A/V khớp tuyệt đối.
enum AudioMux {

    struct Result {
        let outputURL: URL
        let log: String
    }

    enum MuxError: LocalizedError {
        case ffmpegNotFound
        case failed(code: Int32, log: String)

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "Không tìm thấy ffmpeg. Cài bằng: brew install ffmpeg"
            case .failed(let code, let log):
                return "ffmpeg lỗi (mã \(code)):\n\(log.suffix(600))"
            }
        }
    }

    static func findFFmpeg() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// - Parameters:
    ///   - video: file .mov vừa record (chỉ có video)
    ///   - audio: file nhạc gốc
    ///   - offset: giây — vị trí phát của nhạc lúc bắt đầu ghi
    ///   - deleteVideoOnSuccess: xoá file video tạm sau khi mux xong
    static func mux(video: URL,
                    audio: URL,
                    offset: Double,
                    deleteVideoOnSuccess: Bool,
                    completion: @escaping (Swift.Result<Result, Error>) -> Void) {

        guard let ffmpeg = findFFmpeg() else {
            completion(.failure(MuxError.ffmpegNotFound)); return
        }

        let base = video.deletingPathExtension().lastPathComponent
        let out = video.deletingLastPathComponent()
            .appendingPathComponent("\(base)_AV.mov")
        try? FileManager.default.removeItem(at: out)

        var args = ["-hide_banner", "-y", "-i", video.path]
        // -ss đặt TRƯỚC -i của audio → chỉ áp dụng cho input audio.
        // Offset âm nghĩa là nhạc bắt đầu sau video: chèn im lặng bằng -itsoffset.
        if offset >= 0 {
            args += ["-ss", String(format: "%.6f", offset), "-i", audio.path]
        } else {
            args += ["-itsoffset", String(format: "%.6f", -offset), "-i", audio.path]
        }
        args += [
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy",              // video không đụng tới — giữ nguyên ProRes
            "-c:a", "pcm_s24le",         // audio không nén trong .mov
            "-shortest",
            out.path,
        ]

        let task = Process()
        task.executableURL = ffmpeg
        task.arguments = args

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe

        DispatchQueue.global(qos: .utility).async {
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let log = String(decoding: data, as: UTF8.self)

                if task.terminationStatus == 0 {
                    if deleteVideoOnSuccess { try? FileManager.default.removeItem(at: video) }
                    completion(.success(Result(outputURL: out, log: log)))
                } else {
                    completion(.failure(MuxError.failed(code: task.terminationStatus, log: log)))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}
