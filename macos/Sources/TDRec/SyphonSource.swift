import Foundation
import Metal
import CoreVideo
import SyphonBridge

/// Nhận texture từ TouchDesigner qua Syphon và sao chép sang CVPixelBuffer riêng.
///
/// Vì sao phải sao chép: texture Syphon trả về thuộc pool nội bộ của server và
/// sẽ bị GHI ĐÈ ngay khi TD render frame kế. Nếu đưa thẳng cho encoder thì
/// hình sẽ bị rách. Ta blit sang buffer riêng bằng GPU (compute shader) — trên
/// Apple Silicon là unified memory nên không có copy qua PCIe, chi phí ~0.
final class SyphonSource: @unchecked Sendable {

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let hostTime: UInt64        // mach_absolute_time lúc nhận
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLComputePipelineState!
    private var textureCache: CVMetalTextureCache!

    private var client: TDSyphonClient?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// Gọi khi có frame mới đã nằm an toàn trong buffer của ta.
    var onFrame: ((Frame) -> Void)?
    /// Gọi khi phát hiện độ phân giải nguồn thay đổi.
    var onResolutionChange: ((Int, Int) -> Void)?
    /// Gọi khi phải bỏ frame vì pool cạn (writer/đĩa đang tụt lại).
    var onDrop: (() -> Void)?

    private(set) var sourceWidth = 0
    private(set) var sourceHeight = 0

    // Shader copy: dùng compute thay vì blitEncoder vì blit đòi hỏi hai texture
    // cùng pixel format, còn read/write trong compute tự quy đổi BGRA↔RGBA.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void copyTex(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(src.read(gid), gid);
    }
    """

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q

        do {
            let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
            guard let fn = lib.makeFunction(name: "copyTex") else { return nil }
            pipeline = try dev.makeComputePipelineState(function: fn)
        } catch {
            NSLog("TDRec: không tạo được compute pipeline: \(error)")
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess,
              let c = cache else { return nil }
        textureCache = c
    }

    // MARK: - Server list

    static func servers() -> [TDSyphonServer] { TDSyphonClient.availableServers() }
    static func observeServers(_ handler: @escaping () -> Void) {
        TDSyphonClient.observeServerChanges(handler)
    }

    // MARK: - Connect

    func connect(uuid: String) -> Bool {
        disconnect()
        client = TDSyphonClient(serverUUID: uuid, device: device) { [weak self] texture in
            self?.handle(texture: texture)
        }
        return client != nil
    }

    func disconnect() {
        client?.stop()
        client = nil

        // Phải xoá cả kích thước pool. Không xoá thì khi nối lại đúng nguồn cũ,
        // điều kiện "kích thước đổi" trong handle() không bao giờ đúng, nên
        // onResolutionChange không bắn — engine vẫn tưởng chưa nhận frame nào
        // và từ chối cho ghi.
        pool = nil
        poolWidth = 0
        poolHeight = 0
        sourceWidth = 0
        sourceHeight = 0
    }

    // MARK: - Frame path

    private func handle(texture: MTLTexture) {
        let w = texture.width, h = texture.height
        guard w > 0, h > 0 else { return }

        if w != poolWidth || h != poolHeight {
            guard makePool(width: w, height: h) else { return }
            sourceWidth = w; sourceHeight = h
            onResolutionChange?(w, h)
        }

        guard let pool = pool else { return }

        // AllocationThreshold làm pool TRẢ LỖI thay vì cấp phát thêm vô hạn khi
        // writer tụt lại. Không có nó, RAM sẽ phình dần cho tới khi máy đứng.
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: Self.poolCapacity] as CFDictionary
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, pool, aux, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else {
            // Pool cạn = writer đang tụt. Bỏ frame này, KHÔNG chờ — chờ ở đây
            // sẽ block thread Syphon và kéo tụt FPS của TouchDesigner.
            onDrop?()
            return
        }

        guard let dstTex = makeTexture(from: pb) else { return }

        // Nếu nguồn là sRGB, đọc qua view tuyến tính để không bị quy đổi gamma
        // hai lần khi ghi sang buffer non-sRGB.
        let srcTex = linearView(of: texture) ?? texture

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        enc.setComputePipelineState(pipeline)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(dstTex, index: 1)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()

        let t = mach_absolute_time()
        cmd.addCompletedHandler { [weak self] _ in
            self?.onFrame?(Frame(pixelBuffer: pb, hostTime: t))
        }
        cmd.commit()
    }

    private func linearView(of tex: MTLTexture) -> MTLTexture? {
        switch tex.pixelFormat {
        case .bgra8Unorm_srgb: return tex.makeTextureView(pixelFormat: .bgra8Unorm)
        case .rgba8Unorm_srgb: return tex.makeTextureView(pixelFormat: .rgba8Unorm)
        default: return nil
        }
    }

    private func makeTexture(from pb: CVPixelBuffer) -> MTLTexture? {
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let r = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil,
            .bgra8Unorm, w, h, 0, &cvTex)
        guard r == kCVReturnSuccess, let ct = cvTex else { return nil }
        return CVMetalTextureGetTexture(ct)
    }

    /// Pool 12 buffer: đủ hấp thụ đợt giật ngắn của đĩa/encoder (~0.2s @60fps)
    /// mà không ngốn RAM vô tội vạ (10990×1080 BGRA ≈ 47 MB/buffer → ~570 MB).
    static let poolCapacity = 12

    private func makePool(width: Int, height: Int) -> Bool {
        pool = nil
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: Self.poolCapacity
        ]
        var p: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                      poolAttrs as CFDictionary,
                                      attrs as CFDictionary, &p) == kCVReturnSuccess,
              let created = p else { return false }
        pool = created
        poolWidth = width; poolHeight = height
        return true
    }
}
