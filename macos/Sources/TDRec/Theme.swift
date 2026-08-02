import SwiftUI

/// Bảng màu và kiểu chữ dùng chung.
///
/// Cố định tông tối, không đổi theo giao diện hệ thống: app này chạy trong
/// phòng tối lúc dựng show, nền sáng sẽ chói mắt và làm sai cảm nhận màu của
/// hình đang preview.
enum Theme {

    // Nền
    static let bg        = Color(hex: 0x0B0C0E)
    static let panel     = Color(hex: 0x14161A)
    static let panelHi   = Color(hex: 0x1B1E24)
    static let stroke    = Color(hex: 0x252932)

    // Chữ
    static let text      = Color(hex: 0xE8EAED)
    static let textDim   = Color(hex: 0x8A9099)
    static let textFaint = Color(hex: 0x5A616B)

    // Trạng thái
    static let rec       = Color(hex: 0xFF3B30)
    static let ok        = Color(hex: 0x32D74B)
    static let warn      = Color(hex: 0xFFD60A)
    static let alert     = Color(hex: 0xFF9F0A)
    static let accent    = Color(hex: 0x0A84FF)

    // Chữ số liệu dùng monospace để không nhảy ngang khi giá trị đổi.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF)         / 255,
                  opacity: 1)
    }
}

// MARK: - Thành phần dùng lại

/// Khối nội dung có tiêu đề nhỏ ở trên.
struct Panel<Content: View>: View {
    let title: String
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased())
                    .font(Theme.ui(10, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if let accessory { accessory }
            }
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
        )
    }
}

/// Ô hiển thị một con số kèm nhãn.
struct Metric: View {
    let label: String
    let value: String
    var tint: Color = Theme.text
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.ui(9, .medium))
                .tracking(0.5)
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
            Text(value)
                .font(Theme.mono(wide ? 17 : 14, .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dòng cài đặt: nhãn trái, nội dung phải.
struct Row<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textDim)
                .frame(width: 78, alignment: .leading)
            content
            if let hint {
                Text(hint)
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Dòng thông báo có màu theo mức độ.
struct Notice: View {
    enum Level { case info, good, warn, bad
        var color: Color {
            switch self {
            case .info: return Theme.textDim
            case .good: return Theme.ok
            case .warn: return Theme.warn
            case .bad:  return Theme.rec
            }
        }
        var icon: String {
            switch self {
            case .info: return "info.circle"
            case .good: return "checkmark.seal.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .bad:  return "xmark.octagon.fill"
            }
        }
    }

    let level: Level
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: level.icon)
                .font(.system(size: 10))
                .foregroundStyle(level.color)
                .padding(.top, 1)
            Text(text)
                .font(Theme.ui(11))
                .foregroundStyle(level == .info ? Theme.textDim : level.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Chấm trạng thái có quầng sáng khi đang ghi.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(pulsing && on ? 0.9 : 0.35), radius: pulsing && on ? 7 : 3)
            .opacity(pulsing ? (on ? 1 : 0.45) : 1)
            .animation(pulsing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                       value: on)
            .onAppear { on = true }
    }
}
