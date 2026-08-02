#!/usr/bin/env swift
import ImageIO
import UniformTypeIdentifiers
//
//  makeicon.swift — vẽ icon TDRec ra bộ PNG để iconutil đóng thành .icns
//
//  Ý tưởng: nền tối bo góc kiểu app phòng thu, một dải ultrawide nằm ngang
//  (gợi đúng tường 10350×1080 của show), và chấm ghi đỏ đè lên.
//
//  Chạy:  swift tools/makeicon.swift <thư-mục-xuất>
//

import AppKit
import CoreGraphics

func draw(size S: CGFloat) -> CGImage? {
    let w = Int(S), h = Int(S)
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // ── Nền: bo góc kiểu macOS (squircle xấp xỉ bằng bán kính 22.5%) ──
    let inset = S * 0.055
    let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = rect.width * 0.225
    let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()

    // gradient tối, sáng dần lên trên cho có chiều sâu
    let colors = [
        CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1),
        CGColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: S),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }

    // ── Dải ultrawide: ba đoạn gợi hình tường LED đang chạy visual ──
    let stripH = S * 0.105
    let stripY = S * 0.5 - stripH / 2
    let stripX = S * 0.135
    let stripW = S * 0.73

    let segColors = [
        CGColor(red: 0.16, green: 0.55, blue: 0.98, alpha: 1),   // xanh
        CGColor(red: 0.62, green: 0.35, blue: 0.95, alpha: 1),   // tím
        CGColor(red: 1.00, green: 0.72, blue: 0.20, alpha: 1),   // vàng
    ]
    let gap = S * 0.012
    let segW = (stripW - gap * 2) / 3
    for (i, c) in segColors.enumerated() {
        let r = CGRect(x: stripX + CGFloat(i) * (segW + gap), y: stripY,
                       width: segW, height: stripH)
        ctx.setFillColor(c.copy(alpha: 0.85)!)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: stripH * 0.28,
                           cornerHeight: stripH * 0.28, transform: nil))
        ctx.fillPath()
    }

    // ── Chấm ghi: đỏ, có quầng sáng ──
    let dotR = S * 0.112
    let center = CGPoint(x: S / 2, y: S / 2)

    // quầng
    let glowColors = [
        CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.30),
        CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: glowColors, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: dotR * 0.8,
                               endCenter: center, endRadius: dotR * 1.7, options: [])
    }

    // vòng tối lót phía sau: chấm đỏ nằm đè lên dải màu nên cần tách biên
    ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
    let ringR = dotR * 1.30
    ctx.fillEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR,
                               width: ringR * 2, height: ringR * 2))

    ctx.setFillColor(CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - dotR, y: center.y - dotR,
                               width: dotR * 2, height: dotR * 2))

    // điểm sáng nhỏ phía trên cho chấm có khối
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.fillEllipse(in: CGRect(x: center.x - dotR * 0.45,
                               y: center.y + dotR * 0.14,
                               width: dotR * 0.9, height: dotR * 0.62))

    ctx.restoreGState()

    // ── Viền mảnh cho tách khỏi nền sáng ──
    ctx.addPath(bg)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.09))
    ctx.setLineWidth(max(1, S * 0.006))
    ctx.strokePath()

    return ctx.makeImage()
}

// ── Xuất bộ kích thước mà iconutil yêu cầu ──
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "./TDRec.iconset"
try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (px, name) in specs {
    guard let img = draw(size: CGFloat(px)) else {
        print("✗ vẽ hỏng ở \(px)px"); exit(1)
    }
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     "public.png" as CFString, 1, nil) else {
        print("✗ không tạo được \(url.path)"); exit(1)
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
print("✓ đã xuất \(specs.count) ảnh vào \(outDir)")
