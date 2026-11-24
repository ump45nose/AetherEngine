import Foundation
import CoreGraphics

/// One split applied to the original and enhanced outputs of the same decoded frame.
/// This control never opens another stream or owns an audio clock.
public final class UpscaleComparisonControl: @unchecked Sendable {
    public struct Frame: Sendable {
        public let sourceSize: CGSize
        public let targetSize: CGSize
        public let sourceTime: Double
    }
    struct Request: Sendable { let split: Double; let revision: UInt64 }
    private let lock = NSLock()
    private var value: Double?
    private var revision: UInt64 = 0
    private var lastFrame: Frame?
    private var failureReason: String?

    public init() {}
    public var split: Double? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set {
            lock.lock(); defer { lock.unlock() }
            value = newValue.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            revision &+= 1
            lastFrame = nil
            failureReason = nil
        }
    }
    /// Nil until a composite command buffer for the current request completed successfully.
    public var frame: Frame? { lock.lock(); defer { lock.unlock() }; return lastFrame }
    public var unavailableReason: String? { lock.lock(); defer { lock.unlock() }; return failureReason }
    @discardableResult func failed(_ request: Request, reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard request.revision == revision else { return false }
        let changed = failureReason != reason
        failureReason = reason
        lastFrame = nil
        return changed
    }
    var request: Request? {
        lock.lock(); defer { lock.unlock() }
        return value.map { Request(split: $0, revision: revision) }
    }
    func delivered(_ request: Request, source: CGSize, target: CGSize, pts: Double) {
        lock.lock(); defer { lock.unlock() }
        guard request.revision == revision, value != nil else { return }
        failureReason = nil
        lastFrame = Frame(sourceSize: source, targetSize: target, sourceTime: pts)
    }
}

#if !targetEnvironment(simulator)
import CoreVideo
import Metal

/// Appends two plane passes to the upscaler's existing command buffer, within its existing frame budget.
/// The decoded buffer stays read-only; only the enhanced output's left side is replaced. Sampling each
/// original plane in normalized coordinates keeps both sides at the same display size and timestamp.
final class UpscaleComparisonCompositor: @unchecked Sendable {
    private let pipeline: MTLComputePipelineState
    init?(device: MTLDevice) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void comparison(texture2d<float, access::sample> original [[texture(0)]],
                               texture2d<float, access::write> output [[texture(1)]],
                               constant float &split [[buffer(0)]], constant float4 &region [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
            if (p.x >= output.get_width() || p.y >= output.get_height()) return;
            if (float(p.x) >= split * output.get_width()) return;
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 uv = (float2(p) + 0.5f) / float2(output.get_width(), output.get_height());
            output.write(original.sample(s, region.xy + uv * region.zw), p);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "comparison"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.pipeline = pipeline
    }

    func encode(original: CVPixelBuffer, enhanced: CVPixelBuffer, split: Double, sourceRegion: CGRect? = nil, into work: EncodedGPUWork) throws -> EncodedGPUWork {
        enum Failure: Error { case format, texture, encoder }
        let format = CVPixelBufferGetPixelFormatType(original)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard CVPixelBufferGetPixelFormatType(enhanced) == format,
              CVPixelBufferGetPlaneCount(original) == 2, CVPixelBufferGetPlaneCount(enhanced) == 2,
              let lease = work.textures else { throw Failure.format }
        func texture(_ buffer: CVPixelBuffer, _ plane: Int) throws -> MTLTexture {
            var reference: CVMetalTexture?
            let pixel: MTLPixelFormat = plane == 0 ? (tenBit ? .r16Unorm : .r8Unorm) : (tenBit ? .rg16Unorm : .rg8Unorm)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, lease.cache, buffer, nil, pixel,
                CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
                plane, &reference) == kCVReturnSuccess,
                let reference, let texture = CVMetalTextureGetTexture(reference) else { throw Failure.texture }
            lease.hold(reference)
            return texture
        }
        // Build all textures before encoding, so a refused plane leaves the enhanced frame intact.
        let planes = try (0..<2).map { (try texture(original, $0), try texture(enhanced, $0)) }
        guard let encoder = work.commandBuffer.makeComputeCommandEncoder() else { throw Failure.encoder }
        encoder.setComputePipelineState(pipeline)
        var splitValue = Float(split)
        encoder.setBytes(&splitValue, length: MemoryLayout<Float>.size, index: 0)
        let rect = sourceRegion ?? CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(original), height: CVPixelBufferGetHeight(original))
        let width = Float(CVPixelBufferGetWidth(original)), height = Float(CVPixelBufferGetHeight(original))
        var region = SIMD4<Float>(Float(rect.minX) / width, Float(rect.minY) / height,
                                  Float(rect.width) / width, Float(rect.height) / height)
        encoder.setBytes(&region, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        for (input, output) in planes {
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            MetalFrameIO.dispatch(encoder, grid: (output.width, output.height),
                threadgroup: MTLSize(width: 8, height: 8, depth: 1), nonUniform: false)
        }
        encoder.endEncoding()
        lease.hold(original)
        return work
    }
}
#endif
