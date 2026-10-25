import AVFoundation
import CoreMedia
import XCTest
@testable import EviiFrames

/// Files the Photos picker cannot hand to a UI test: empty, audio-only, HDR, Dolby, VFR, odd and tiny sizes.
final class ProbeQATests: XCTestCase {
    func testImportNotesForLongHDRVFRAndTiny() {
        var info = VideoInfo(
            filename: "clip",
            width: 14,
            height: 8,
            fps: 29.97,
            duration: 40,
            frameCount: 1200,
            fileSize: 10,
            hasAudio: false,
            codecLabel: "HEVC",
            dynamicRange: .hdr,
            variableFrameRate: true,
            dimensionsAdjusted: true
        )
        let notes = VideoProbe.importNotes(info)
        XCTAssertTrue(notes.contains { $0.contains("30 с") })
        XCTAssertTrue(notes.contains { $0.contains("HDR") && $0.contains("SDR") })
        XCTAssertTrue(notes.contains { $0.contains("Змінна частота") })
        XCTAssertTrue(notes.contains { $0.contains("парних") })
        info.dynamicRange = .dolbyVision
        info.duration = 2
        info.variableFrameRate = false
        info.dimensionsAdjusted = false
        let dolby = VideoProbe.importNotes(info)
        XCTAssertEqual(dolby.count, 1)
        XCTAssertTrue(dolby[0].contains("Dolby Vision"))
    }

    func testWindowClampsToThirtySeconds() {
        let info = VideoInfo(
            filename: "long",
            width: 1920,
            height: 1080,
            fps: 30,
            duration: 44,
            frameCount: 1320,
            fileSize: 1,
            hasAudio: true,
            codecLabel: "H.264"
        )
        let window = SourceWindow.full(info)
        XCTAssertEqual(window.start, 0, accuracy: 0.0001)
        XCTAssertEqual(window.duration, 30, accuracy: 0.0001)
    }

    func testResolutionCapsStayEven() {
        let fullHD = pixels(3840, 2160, .p1080)
        XCTAssertEqual(fullHD.width, 1920)
        XCTAssertEqual(fullHD.height, 1080)
        let portrait = pixels(2160, 3840, .p1080)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
        let hd = pixels(1920, 1080, .p720)
        XCTAssertEqual(hd.width, 1280)
        XCTAssertEqual(hd.height, 720)
        let bucket = Geometry.bucket(width: fullHD.width, height: fullHD.height)
        XCTAssertLessThanOrEqual(bucket.h, 1088)
        XCTAssertLessThanOrEqual(bucket.w, 1920)
    }

    func testOddDimensionsBecomeEven() {
        let odd = VideoProbe.normalizedPixels(width: 15, height: 9)
        XCTAssertEqual(odd.width, 14)
        XCTAssertEqual(odd.height, 8)
        XCTAssertTrue(odd.adjusted)
        let tiny = VideoProbe.normalizedPixels(width: 16, height: 16)
        XCTAssertEqual(tiny.width, 16)
        XCTAssertEqual(tiny.height, 16)
        XCTAssertTrue(tiny.adjusted)
        let normal = VideoProbe.normalizedPixels(width: 160, height: 96)
        XCTAssertFalse(normal.adjusted)
    }

    func testDynamicRangeAndVFRClassifiers() {
        let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        XCTAssertEqual(VideoProbe.dynamicRange(fourcc: "hvc1", transfer: pq, atomKeys: []), .hdr)
        XCTAssertEqual(VideoProbe.dynamicRange(fourcc: "avc1", transfer: hlg, atomKeys: []), .hdr)
        XCTAssertEqual(VideoProbe.dynamicRange(fourcc: "dvh1", transfer: nil, atomKeys: []), .dolbyVision)
        XCTAssertEqual(VideoProbe.dynamicRange(fourcc: "hvc1", transfer: nil, atomKeys: ["dvvC"]), .dolbyVision)
        XCTAssertEqual(VideoProbe.dynamicRange(fourcc: "avc1", transfer: nil, atomKeys: []), .sdr)
        XCTAssertTrue(VideoProbe.isVariableFrameRate(nominalFPS: 30, minFrameDuration: CMTime(seconds: 0.008, preferredTimescale: 60_000)))
        XCTAssertFalse(VideoProbe.isVariableFrameRate(nominalFPS: 30, minFrameDuration: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 60_000)))
        XCTAssertFalse(VideoProbe.isVariableFrameRate(nominalFPS: 0, minFrameDuration: CMTime(seconds: 0.01, preferredTimescale: 600)))
    }

    func testEmptyAndAudioOnlyFailClearly() async throws {
        let empty = try ClipFactory.writeEmpty()
        defer { try? FileManager.default.removeItem(at: empty) }
        do {
            _ = try await VideoProbe.probe(empty)
            XCTFail("порожній файл відкрився")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let audio = try ClipFactory.writeAudioOnly()
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            _ = try await VideoProbe.probe(audio)
            XCTFail("файл без відео відкрився")
        } catch PipelineError.noVideo {
        } catch {
            XCTFail("очікував відсутність відеодоріжки, отримав \(error)")
        }
    }

    func testHDRTagDolbyNoteAndVariableTiming() async throws {
        do {
            let pqURL = try ClipFactory.write(ClipFactory.Spec(frames: 4, fps: 30, width: 160, height: 96, pq: true, name: "pq"))
            defer { try? FileManager.default.removeItem(at: pqURL) }
            let pq = try await VideoProbe.probe(pqURL)
            print("EVII_QA hdr file range=\(pq.dynamicRange.rawValue) codec=\(pq.codecLabel)")
            XCTAssertEqual(pq.dynamicRange, .hdr, "PQ transfer was stripped or not classified")
            XCTAssertTrue(VideoProbe.importNotes(pq).contains { $0.contains("HDR") })
        } catch {
            XCTFail("PQ clip: \(error)")
        }

        let vfrURL = try ClipFactory.write(ClipFactory.Spec(frames: 12, fps: 30, width: 160, height: 96, variableTiming: true, name: "vfr"))
        defer { try? FileManager.default.removeItem(at: vfrURL) }
        let vfr = try await VideoProbe.probe(vfrURL)
        let facts = try await MediaInspect.inspect(vfrURL)
        print("EVII_QA vfr flagged=\(vfr.variableFrameRate) fps=\(vfr.fps) minDelta=\(facts.minDelta) frames=\(facts.videoFrames)")
        if facts.minDelta > 0, vfr.fps > 1, (1.0 / facts.minDelta) > vfr.fps * 1.35 {
            XCTAssertTrue(vfr.variableFrameRate)
        }
        let source = FrameSource(
            url: vfrURL,
            window: SourceWindow(start: 0, end: vfr.duration),
            fps: vfr.fps,
            width: 64,
            height: 48
        )
        try await source.start()
        var yielded = 0
        while source.next() != nil { yielded += 1 }
        let expected = max(1, Int((vfr.duration * vfr.fps).rounded()))
        XCTAssertGreaterThan(yielded, 0)
        XCTAssertLessThanOrEqual(abs(yielded - expected), 2, "VFR was not conformed to nominal fps (got \(yielded), expected \(expected))")
        XCTAssertTrue(facts.playable)
    }

    func testOddEncoderIsRejectedOrNormalized() async throws {
        do {
            let url = try ClipFactory.write(ClipFactory.Spec(frames: 2, fps: 30, width: 15, height: 9, name: "odd"))
            defer { try? FileManager.default.removeItem(at: url) }
            let info = try await VideoProbe.probe(url)
            XCTAssertEqual(info.width % 2, 0)
            XCTAssertEqual(info.height % 2, 0)
            XCTAssertTrue(info.dimensionsAdjusted)
        } catch {
            let size = VideoProbe.normalizedPixels(width: 15, height: 9)
            XCTAssertEqual(size.width, 14)
            XCTAssertEqual(size.height, 8)
            print("EVII_QA odd encoder rejected: \(error)")
        }
    }

    private func pixels(_ width: Int, _ height: Int, _ cap: MaxResolution) -> (width: Int, height: Int) {
        let info = VideoInfo(
            filename: "size",
            width: width,
            height: height,
            fps: 30,
            duration: 1,
            frameCount: 30,
            fileSize: 1,
            hasAudio: false,
            codecLabel: "H.264"
        )
        var job = ClipJob(
            sourceURL: URL(fileURLWithPath: "/tmp/unused.mov"),
            info: info,
            window: SourceWindow(start: 0, end: 1),
            mode: .interpolation,
            slow: SlowMoSettings(),
            interpolation: InterpolationSettings(),
            export: ExportSettings()
        )
        job.export.maxResolution = cap
        return job.outputPixelSize()
    }
}
