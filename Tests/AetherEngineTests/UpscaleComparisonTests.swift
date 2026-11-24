#if !targetEnvironment(simulator)
import Testing
import CoreMedia
import CoreVideo
import Metal
@testable import AetherEngine

@Suite("Same decoded frame comparison")
struct UpscaleComparisonTests {
    @Test func splitIsBoundedAndOldCompletionCannotPublish() {
        let control = UpscaleComparisonControl()
        control.split = 2
        #expect(control.split == 1)
        let old = control.request!
        control.split = 0.3
        control.delivered(old, source: .init(width: 2, height: 2), target: .init(width: 4, height: 4), pts: 8)
        #expect(control.frame == nil)
        control.split = .nan
        #expect(control.split == nil)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func compositeUsesOriginalLeftAndEnhancedRight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let compositor = try #require(UpscaleComparisonCompositor(device: device))
        for tenBit in [false, true] {
            let source = try frame(width: 8, height: 4, tenBit: tenBit, value: 0.25)
            let target = try frame(width: 16, height: 8, tenBit: tenBit, value: 0.75)
            let command = try #require(queue.makeCommandBuffer())
            let io = try #require(MetalFrameIO(device: device))
            let work = EncodedGPUWork(commandBuffer: command, textures: io.lease(), failure: { _, _ in TestFailure.gpu })
            _ = try compositor.encode(original: source, enhanced: target, split: 0.5, into: work)
            _ = try work.commitAndWait()
            CVPixelBufferLockBaseAddress(target, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(target, .readOnly) }
            let address = try #require(CVPixelBufferGetBaseAddressOfPlane(target, 0))
            if tenBit {
                let pixels = address.assumingMemoryBound(to: UInt16.self)
                #expect(abs(Int(pixels[1]) - 16384) < 128)
                #expect(abs(Int(pixels[14]) - 49152) < 128)
            } else {
                let pixels = address.assumingMemoryBound(to: UInt8.self)
                #expect(abs(Int(pixels[1]) - 64) <= 1)
                #expect(abs(Int(pixels[14]) - 191) <= 1)
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func comparisonAt4KStaysWithinExisting24fpsBudget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let io = try #require(MetalFrameIO(device: device))
        let compositor = try #require(UpscaleComparisonCompositor(device: device))
        let source = try frame(width: 1920, height: 1080, tenBit: false, value: 0.25)
        let target = try frame(width: 3840, height: 2160, tenBit: false, value: 0.75)
        var costs: [Double] = []
        for _ in 0..<48 {
            let command = try #require(queue.makeCommandBuffer())
            let work = EncodedGPUWork(commandBuffer: command, textures: io.lease(), failure: { _, _ in TestFailure.gpu })
            _ = try compositor.encode(original: source, enhanced: target, split: 0.5, into: work)
            costs.append(try work.commitAndWait())
        }
        let mean = costs.reduce(0, +) / Double(costs.count)
        // The engine's existing 48-frame window, 90% of the 24 fps interval; unchanged.
        #expect(mean < 1000.0 / 24 * 0.9)
        print(String(format: "[Comparison] 1080p -> 4K composition only: 48 frames, mean %.3f ms, max %.3f ms", mean, costs.max()!))
    }

    private enum TestFailure: Error { case buffer, gpu }
    private func frame(width: Int, height: Int, tenBit: Bool, value: Double) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard CVPixelBufferCreate(nil, width, height, format,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &result) == kCVReturnSuccess, let result else { throw TestFailure.buffer }
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        for plane in 0..<2 {
            let address = CVPixelBufferGetBaseAddressOfPlane(result, plane)!
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane)
            if tenBit { address.assumingMemoryBound(to: UInt16.self).initialize(repeating: UInt16(value * 65535), count: bytes / 2) }
            else { address.assumingMemoryBound(to: UInt8.self).initialize(repeating: UInt8(value * 255), count: bytes) }
        }
        return result
    }
}
#endif
