import XCTest
@testable import EviiFrames

final class TimingTests: XCTestCase {
    func testOutputFPSAndFrameCountMatchTheMockClip() {
        let fps = Timing.outputFPS(sourceFPS: 29.97, multiplier: 4)
        XCTAssertEqual(fps, 119.88, accuracy: 0.001)
        XCTAssertEqual(Timing.interpolatedFrameCount(sourceFrames: 60, multiplier: 4, loop: false), 237)
        XCTAssertEqual(Timing.interpolatedFrameCount(sourceFrames: 60, multiplier: 4, loop: true), 240)
    }

    func testCappedFPSUsesTheCap() {
        let fps = Timing.interpolationOutputFPS(sourceFPS: 24, multiplier: 16, targetFPS: nil, maxFPS: 60)
        XCTAssertEqual(fps, 60, accuracy: 0.001)
        let count = Timing.interpolationFrameCount(sourceFrames: 24, sourceFPS: 24, outputFPS: 60, loop: false)
        // span = 23/24 s, 23/24*60 = 57.5 → 58, plus the first frame.
        XCTAssertEqual(count, 59)
    }

    func testTargetFPSMatchesIntegerMultiplier() {
        let fps = Timing.interpolationOutputFPS(sourceFPS: 29.97, multiplier: 2, targetFPS: 119.88, maxFPS: 120)
        XCTAssertEqual(fps, 119.88, accuracy: 0.001)
        let count = Timing.interpolationFrameCount(sourceFrames: 60, sourceFPS: 29.97, outputFPS: fps, loop: false)
        XCTAssertEqual(count, 237)
    }

    func testWholeClipSlowMoDuration() {
        let duration = Timing.slowMoDuration(clip: 2, fragment: nil, factor: 4)
        XCTAssertEqual(duration, 8, accuracy: 1e-9)
    }

    func testFragmentSlowMoDurationMatchesTheMock() {
        // 2.00 s clip, fragment 0.60...1.50 at x4 → 0.60 + 3.60 + 0.50 = 4.70
        let duration = Timing.slowMoDuration(clip: 2, fragment: 0.6...1.5, factor: 4)
        XCTAssertEqual(duration, 4.7, accuracy: 1e-6)
    }

    func testSlowMoSourceTimeIsPiecewise() {
        let map = SlowMoMap(clipDuration: 2, fragment: 0.6...1.5, factor: 4)
        XCTAssertEqual(map.sourceTime(at: 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(at: 0.6), 0.6, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(at: 1.0), 0.7, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(at: 4.2), 1.5, accuracy: 1e-6)
        XCTAssertEqual(map.sourceTime(at: 4.5), 1.8, accuracy: 1e-6)
        XCTAssertFalse(map.isSlowed(sourceTime: 0.3))
        XCTAssertTrue(map.isSlowed(sourceTime: 0.7))
        XCTAssertFalse(map.isSlowed(sourceTime: 1.8))
    }

    func testRuntimeHintForTheMockClipIsAboutThirtyToSixtySeconds() {
        let hint = Timing.runtimeHint(sourceFrames: 60, outputFrames: 237, width: 1920, height: 1080)
        XCTAssertEqual(hint.low, 30)
        XCTAssertEqual(hint.high, 60)
        XCTAssertEqual(Timing.formatRuntime(low: hint.low, high: hint.high), "≈ 30–60 с")
    }

    func testExportSizeEstimateLandsNearEighteenMegabytes() {
        let bytes = Timing.estimatedBytes(width: 1920, height: 1080, frames: 237, quality: 75, codec: .hevc)
        XCTAssertEqual(Double(bytes), 18_000_000, accuracy: 80_000)
        XCTAssertEqual(Format.megabytes(bytes, approximate: true), "≈ 18 МБ")
    }

    func testFilenameRounds119_88To120() {
        let name = FilenamePattern.render(pattern: "{name}_{fps}fps", name: "IMG_4821", fps: 119.88, factor: 4)
        XCTAssertEqual(name, "IMG_4821_120fps")
    }

    func testClockFormatting() {
        XCTAssertEqual(Format.clock(2), "0:02.00")
        XCTAssertEqual(Format.fps(29.97), "29.97 fps")
        XCTAssertEqual(Format.fps(30), "30 fps")
    }
}
