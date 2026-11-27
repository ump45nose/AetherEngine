import Foundation
import Testing
@testable import AetherEngine

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ExternalSubtitleReceiptTests {
    private func write(_ text: String, suffix: String = "srt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func successFailureAndBitmap() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let good = try write("1\n00:00:01,000 --> 00:00:10,000\nOld track\n\n")
        let bad = try write("not a subtitle")
        let bitmap = try Issue921SidecarBitmapDrainTests.writeSup(sets: 2)
        defer {
            for url in [good, bad, bitmap] { try? FileManager.default.removeItem(at: url) }
        }
        let a = engine.addExternalSubtitleTrack(.init(url: good))
        let b = engine.addExternalSubtitleTrack(.init(url: bad))
        let picture = engine.addExternalSubtitleTrack(.init(url: bitmap))
        let first = await engine.selectExternalSubtitleWithReceipt(id: a.id, sourceGeneration: 12, requestID: 1)
        #expect(first.outcome == .selected)
        #expect(first.sourceGeneration == 12 && first.requestID == 1)
        #expect(engine.subtitleCues.first?.text == "Old track")
        let second = await engine.selectExternalSubtitleWithReceipt(id: b.id, sourceGeneration: 12, requestID: 2)
        #expect(second.outcome == .failed)
        #expect(engine.activeSubtitleTrackIndex == a.id)
        #expect(engine.subtitleCues.first?.text == "Old track")
        #expect(!engine.isLoadingSubtitles)
        let third = await engine.selectExternalSubtitleWithReceipt(id: picture.id, sourceGeneration: 12, requestID: 3)
        #expect(third.outcome == .selected)
        #expect(engine.activeSubtitleTrackIndex == picture.id)
        #expect(engine.sidecarBitmapSources[.primary] != nil)
        let fourth = await engine.selectExternalSubtitleWithReceipt(id: b.id, sourceGeneration: 12, requestID: 4)
        #expect(fourth.outcome == .failed)
        #expect(engine.activeSubtitleTrackIndex == picture.id)
        #expect(engine.sidecarBitmapSources[.primary] != nil)
    }

    @Test func supersededDecodeCannotPublish() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let file = try write("1\n00:00:01,000 --> 00:00:10,000\nTrack\n\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let track = engine.addExternalSubtitleTrack(.init(url: file))
        let origin = try #require(HeldHTTPOrigin())
        defer { origin.stop() }
        let old = engine.addExternalSubtitleTrack(.init(url: origin.url("/old.srt")))
        let newer = engine.addExternalSubtitleTrack(.init(url: origin.url("/newer.srt")))
        let first = Task { @MainActor in
            await engine.selectExternalSubtitleWithReceipt(id: old.id, sourceGeneration: 3, requestID: 7)
        }
        // Advance the load while the first selection is suspended on HTTP.
        try await waitFor { origin.heldRequests(for: "/old.srt") > 0 }
        engine.loadGeneration &+= 1
        let result = await first.value
        #expect(result.outcome == .superseded)
        #expect(engine.activeSubtitleTrackIndex == nil)
        let second = Task { @MainActor in
            await engine.selectExternalSubtitleWithReceipt(id: newer.id, sourceGeneration: 4, requestID: 8)
        }
        try await waitFor { origin.heldRequests(for: "/newer.srt") > 0 }
        engine.cancelExternalSubtitleSelection(sourceGeneration: 4, requestID: 8)
        origin.release()
        let third = await engine.selectExternalSubtitleWithReceipt(id: track.id, sourceGeneration: 4, requestID: 9)
        #expect(await second.value.outcome == .superseded)
        #expect(third.outcome == .selected)
        #expect(engine.activeSubtitleTrackIndex == track.id)
    }
}
