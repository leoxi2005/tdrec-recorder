// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Syphon.framework nằm trong ./Frameworks. SPM không có "framework dependency"
// chính thức cho .framework nhị phân của macOS ngoài xcframework, nên ta trỏ
// bằng -F / -framework.
//
// Context.packageDirectory cho đường dẫn thư mục gói lúc build — bắt buộc phải
// dùng cái này thay vì viết cứng đường dẫn, nếu không repo chỉ build được trên
// đúng một máy và CI sẽ hỏng.
let root = Context.packageDirectory
let frameworkSearch = "-F\(root)/Frameworks"

let package = Package(
    name: "TDRec",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SyphonBridge",
            publicHeadersPath: "include",
            cSettings: [ .unsafeFlags([frameworkSearch]) ]
        ),
        .executableTarget(
            name: "TDRec",
            dependencies: ["SyphonBridge"],
            swiftSettings: [ .unsafeFlags([frameworkSearch]) ],
            linkerSettings: [
                .unsafeFlags([
                    frameworkSearch,
                    "-framework", "Syphon",
                    // @executable_path: dùng khi chạy từ trong TDRec.app
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    // đường dẫn gói: dùng khi chạy binary trực tiếp lúc dev
                    "-Xlinker", "-rpath", "-Xlinker", "\(root)/Frameworks",
                ])
            ]
        ),
    ],
    // Ghim che do ngon ngu Swift 5. Cac API AVFoundation/CoreVideo dung o day
    // (callback CVPixelBuffer, completion handler cua AVAssetWriter) chua duoc
    // danh dau Sendable, va muc do chat che cua che do Swift 6 thay doi giua
    // ban 6.0 va 6.3 nen build khong nhat quan giua may va CI.
    // Tinh dung dan ve dong thoi o day duoc bao dam bang khoa tu viet
    // (NSLock, serial queue), khong dua vao kiem tra cua trinh bien dich.
    swiftLanguageModes: [.v5]
)
