import Foundation

/// Đo nhịp frame đến từ Syphon.
///
/// Tách khỏi RecorderEngine vì frame được ghi nhận trên thread của Metal, còn
/// engine chạy trên main actor — dùng chung biến sẽ vi phạm cách ly actor.
/// Lớp này tự khoá nên an toàn gọi từ thread bất kỳ.
final class FPSMeter: @unchecked Sendable {

    private let lock = NSLock()
    private var ticks: [UInt64] = []
    private var timebase = mach_timebase_info_data_t()
    private let window = 90            // ~1.5 giây @60fps

    init() { mach_timebase_info(&timebase) }

    func mark(_ hostTime: UInt64) {
        lock.lock()
        ticks.append(hostTime)
        if ticks.count > window { ticks.removeFirst(ticks.count - window) }
        lock.unlock()
    }

    /// FPS trung bình trong cửa sổ. Trả 0 nếu frame cuối đã quá cũ (nguồn dừng).
    func current() -> Double {
        lock.lock()
        let snapshot = ticks
        lock.unlock()

        guard snapshot.count >= 2, let first = snapshot.first, let last = snapshot.last else {
            return 0
        }
        // Nguồn đã ngừng phát > 1 giây → báo 0 thay vì giữ số cũ.
        if elapsedSeconds(from: last, to: mach_absolute_time()) > 1.0 { return 0 }

        let secs = elapsedSeconds(from: first, to: last)
        return secs > 0 ? Double(snapshot.count - 1) / secs : 0
    }

    func reset() {
        lock.lock(); ticks.removeAll(); lock.unlock()
    }

    private func elapsedSeconds(from a: UInt64, to b: UInt64) -> Double {
        guard b > a else { return 0 }
        let ns = Double(b - a) * Double(timebase.numer) / Double(timebase.denom)
        return ns / 1_000_000_000
    }
}

/// Bộ đếm nguyên tử tối giản, dùng cho số frame bị bỏ tại nguồn.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
    func reset() { lock.lock(); n = 0; lock.unlock() }
}
