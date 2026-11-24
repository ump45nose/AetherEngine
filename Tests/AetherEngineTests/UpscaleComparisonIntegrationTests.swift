#if !targetEnvironment(simulator)
import Testing
import CoreMedia
import CoreVideo
import Metal
@testable import AetherEngine

@Suite("Comparison in the existing upscale pipeline")
struct UpscaleComparisonIntegrationTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func lineArtPublishesTheDecodedFrameTimestamp() throws {
        let plan = try #require(UpscaleRouteDecision.makePlan(
            source: SourceGeometry(width: 320, height: 180, sarNum: 1, sarDen: 1),
            display: .init(width: 640, height: 360), mlScaleFactors: { _, _ in [] }, scaler: .lineArt))
        let upscaler = try #require(FrameUpscaler(plan: plan, frameInterval: 1.0 / 24))
        let control = UpscaleComparisonControl()
        control.split = 0.4
        upscaler.comparisonControl = control
        var input: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &input) == kCVReturnSuccess)
        let buffer = try #require(input)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 64 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<4 {
            let pts = CMTime(value: Int64(frame), timescale: 24)
            let output = try #require(upscaler.upscale(buffer, pts: pts))
            #expect(CVPixelBufferGetWidth(output) == 640)
            #expect(control.frame?.sourceTime == pts.seconds)
        }
        #expect(upscaler.stats.framesUpscaled == 4)
        #expect(upscaler.stats.failures == 0)
    }
}
#endif
