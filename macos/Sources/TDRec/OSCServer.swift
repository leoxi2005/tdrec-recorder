import Foundation
import Network

/// Server OSC tối giản (UDP) để TouchDesigner điều khiển việc ghi từ xa.
///
/// Địa chỉ hỗ trợ:
///   /tdrec/start  [float audioOffsetSeconds]  — bắt đầu ghi, kèm vị trí nhạc
///   /tdrec/stop                               — dừng và đóng file
///   /tdrec/name   [string]                    — đặt tên cho lần ghi kế tiếp
///
/// Chỉ hỗ trợ các kiểu OSC cần dùng (i, f, s). Đủ cho mục đích điều khiển và
/// tránh kéo cả thư viện OSC vào chỉ để đọc 3 message.
final class OSCServer: @unchecked Sendable {

    enum Argument {
        case int(Int32)
        case float(Float)
        case string(String)

        var asDouble: Double? {
            switch self {
            case .int(let v): return Double(v)
            case .float(let v): return Double(v)
            case .string(let s): return Double(s)
            }
        }
        var asString: String? {
            if case .string(let s) = self { return s }
            return nil
        }
    }

    var onMessage: ((String, [Argument]) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tdrec.osc")
    private(set) var port: UInt16 = 0
    private(set) var isRunning = false

    func start(port requested: UInt16) throws {
        stop()
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: requested) else {
            throw NSError(domain: "TDRec", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Port OSC không hợp lệ: \(requested)"])
        }
        let l = try NWListener(using: params, on: nwPort)

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(on: conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.isRunning = false }
        }
        l.start(queue: queue)

        listener = l
        port = requested
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty { self?.parse(data) }
            if error == nil { self?.receive(on: conn) }
        }
    }

    // MARK: - Parsing

    private func parse(_ data: Data) {
        let bytes = [UInt8](data)
        var i = 0

        // Bundle: bỏ header "#bundle" + timetag rồi đọc từng element.
        if let head = readString(bytes, &i), head == "#bundle" {
            i += 8                                      // timetag
            while i + 4 <= bytes.count {
                let size = Int(readInt32(bytes, &i) ?? 0)
                guard size > 0, i + size <= bytes.count else { return }
                parse(Data(bytes[i..<(i + size)]))
                i += size
            }
            return
        }

        i = 0
        guard let address = readString(bytes, &i) else { return }
        var args: [Argument] = []

        if let tags = readString(bytes, &i), tags.hasPrefix(",") {
            for tag in tags.dropFirst() {
                switch tag {
                case "i":
                    guard let v = readInt32(bytes, &i) else { return }
                    args.append(.int(v))
                case "f":
                    guard let raw = readInt32(bytes, &i) else { return }
                    args.append(.float(Float(bitPattern: UInt32(bitPattern: raw))))
                case "s":
                    guard let s = readString(bytes, &i) else { return }
                    args.append(.string(s))
                case "T": args.append(.int(1))
                case "F": args.append(.int(0))
                default:
                    // Kiểu không hỗ trợ — dừng đọc arg, vẫn phát address đi.
                    break
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(address, args)
        }
    }

    /// Đọc chuỗi null-terminated, con trỏ nhảy tới bội số 4 kế tiếp.
    private func readString(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i < b.count else { return nil }
        var end = i
        while end < b.count && b[end] != 0 { end += 1 }
        guard end < b.count else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        let len = end - i + 1
        i += len + ((4 - len % 4) % 4)
        return s
    }

    private func readInt32(_ b: [UInt8], _ i: inout Int) -> Int32? {
        guard i + 4 <= b.count else { return nil }
        let v = (Int32(b[i]) << 24) | (Int32(b[i+1]) << 16) | (Int32(b[i+2]) << 8) | Int32(b[i+3])
        i += 4
        return v
    }
}
