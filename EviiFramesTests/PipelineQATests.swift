import Darwin
import XCTest
@testable import EviiFrames

/// End-to-end exports on synthetic clips. A full 1080p ×8 of 30 s is not inferred:
/// that is thousands of Core ML calls. The long tests cancel after the first generated frame
/// and check that the cache stays a handful of frames and the footprint stays under 5 GiB.
final class PipelineQATests: XCTestCase {
    override func setUp() async throws {
        executionTimeAllowance = 3600
        try XCTSkipIf(RIFEModel.bundledModels().isEmpty, "RIFE 4.25 packages are not in the app bundle")
    }

    func testInterpolationMultipliers() async throws {
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 2, audio: true, name: "x2")
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 4, audio: false, name: "x4")
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 8, audio: false, name: "x8")
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 16, audio: false, name: "x16")
    }

    func testTargetFPSAndCap() async throws {
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 4, targetFPS: 60, audio: false, name: "target60")
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 2, targetFPS: 48, audio: false, name: "target48")
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 8, maxFPS: 120, audio: false, name: "cap120")
    }

    func testMaximumQualityKeepsThePlan() async throws {
        try await expectInterpolation(frames: 8, fps: 30, multiplier: 2, audio: false, name: "tta", maximumQuality: true)
    }

    func testOneAndTwoSecondClips() async throws {
        try await expectInterpolation(frames: 30, fps: 30, multiplier: 2, audio: true, name: "one-second")
        try await expectInterpolation(frames: 60, fps: 30, multiplier: 2, audio: false, name: "two-second")
    }

    func testSixtyFPSPortraitAndLandscape() async throws {
        try await expectInterpolation(frames: 8, fps: 60, width: 160, height: 96, multiplier: 2, audio: false, name: "landscape60")
        try await expectInterpolation(frames: 8, fps: 30, width: 96, height: 160, multiplier: 2, audio: true, name: "portrait")
    }

    func testSlowMoWholeAndFragment() async throws {
        let whole = try ClipFactory.write(ClipFactory.Spec(frames: 8, fps: 30, audio: true, name: "slow-whole"))
        defer { try? FileManager.default.removeItem(at: whole) }
        let info = try await VideoProbe.probe(whole)
        let job = makeJob(url: whole, info: info) {
            $0.mode = .slowMo
            $0.slow.wholeClip = true
            $0.slow.factor = 4
            $0.export.keepAudio = true
        }
        let read = try await yielded(job)
        XCTAssertEqual(read, 8)
        let plan = Planner.plan(job.planRequest(frames: read))
        let run = try await export(job)
        try await assertPlayable(
            name: "slow-whole",
            result: run.result,
            pipeline: run.pipeline,
            expectedFrames: plan.samples.count,
            expectedFPS: plan.outputFPS,
            audio: true,
            windowStart: 0
        )
        XCTAssertEqual(plan.outputDuration, info.duration * 4, accuracy: 0.08)

        let fragmentURL = try ClipFactory.write(ClipFactory.Spec(frames: 8, fps: 30, audio: true, name: "slow-fragment"))
        defer { try? FileManager.default.removeItem(at: fragmentURL) }
        let fragmentInfo = try await VideoProbe.probe(fragmentURL)
        let fragment = makeJob(url: fragmentURL, info: fragmentInfo) {
            $0.mode = .slowMo
            $0.slow.wholeClip = false
            $0.slow.fragmentStart = 0.30
            $0.slow.fragmentEnd = 0.75
            $0.slow.factor = 4
            $0.slow.fragmentAudio = .mute
            $0.export.keepAudio = true
        }
        let fragmentRead = try await yielded(fragment)
        let fragmentPlan = Planner.plan(fragment.planRequest(frames: fragmentRead))
        XCTAssertGreaterThan(fragmentPlan.outputDuration, fragmentInfo.duration)
        let fragmentRun = try await export(fragment)
        try await assertPlayable(
            name: "slow-fragment",
            result: fragmentRun.result,
            pipeline: fragmentRun.pipeline,
            expectedFrames: fragmentPlan.samples.count,
            expectedFPS: fragmentPlan.outputFPS,
            audio: true,
            windowStart: 0
        )
    }

    func testSceneCutDedupAndLoop() async throws {
        let cutURL = try ClipFactory.write(ClipFactory.Spec(frames: 8, fps: 30, cutAt: 4, name: "cut"))
        defer { try? FileManager.default.removeItem(at: cutURL) }
        let cutInfo = try await VideoProbe.probe(cutURL)
        let cutJob = makeJob(url: cutURL, info: cutInfo) {
            $0.interpolation.multiplier = 2
            $0.interpolation.skipSceneChanges = true
            $0.interpolation.sceneSensitivity = 0.4
        }
        let cutRun = try await export(cutJob)
        XCTAssertGreaterThanOrEqual(cutRun.progress.sceneCuts, 1)
        let cutPlan = Planner.plan(cutJob.planRequest(frames: 8, cuts: [4]))
        try await assertPlayable(
            name: "scene-cut",
            result: cutRun.result,
            pipeline: cutRun.pipeline,
            expectedFrames: cutPlan.samples.count,
            expectedFPS: cutPlan.outputFPS,
            audio: false,
            windowStart: 0
        )

        let dupURL = try ClipFactory.write(ClipFactory.Spec(frames: 8, fps: 30, duplicateFrames: [2, 3], name: "dedup"))
        defer { try? FileManager.default.removeItem(at: dupURL) }
        let dupInfo = try await VideoProbe.probe(dupURL)
        let dupJob = makeJob(url: dupURL, info: dupInfo) {
            $0.interpolation.multiplier = 2
            $0.interpolation.dedup = .fast
            $0.interpolation.dedupThresholdPercent = 5
        }
        let dupRun = try await export(dupJob)
        XCTAssertGreaterThanOrEqual(dupRun.progress.duplicates, 1)
        try await assertPlayable(
            name: "dedup",
            result: dupRun.result,
            pipeline: dupRun.pipeline,
            expectedFrames: Timing.interpolationFrameCount(sourceFrames: 8, sourceFPS: dupInfo.fps, outputFPS: dupInfo.fps * 2, loop: false),
            expectedFPS: dupInfo.fps * 2,
            audio: false,
            windowStart: 0
        )

        let loopURL = try ClipFactory.write(ClipFactory.Spec(frames: 8, fps: 30, name: "loop"))
        defer { try? FileManager.default.removeItem(at: loopURL) }
        let loopInfo = try await VideoProbe.probe(loopURL)
        let loopJob = makeJob(url: loopURL, info: loopInfo) {
            $0.interpolation.multiplier = 2
            $0.interpolation.loop = true
            $0.interpolation.skipSceneChanges = true
        }
        let loopRun = try await export(loopJob)
        let loopFPS = Timing.interpolationOutputFPS(sourceFPS: loopInfo.fps, multiplier: 2, targetFPS: nil, maxFPS: nil)
        let loopFrames = Timing.interpolationFrameCount(sourceFrames: 8, sourceFPS: loopInfo.fps, outputFPS: loopFPS, loop: true)
        XCTAssertEqual(loopFrames, 16)
        try await assertPlayable(
            name: "loop",
            result: loopRun.result,
            pipeline: loopRun.pipeline,
            expectedFrames: loopFrames,
            expectedFPS: loopFPS,
            audio: false,
            windowStart: 0
        )
    }

    func testTrimmedAudioStartsAtZero() async throws {
        let url = try ClipFactory.write(ClipFactory.Spec(frames: 24, fps: 30, audio: true, name: "trim"))
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try await VideoProbe.probe(url)
        var job = makeJob(url: url, info: info) {
            $0.interpolation.multiplier = 2
            $0.export.keepAudio = true
        }
        job.window = SourceWindow(start: 0.40, end: min(info.duration, 0.40 + 0.40))
        XCTAssertGreaterThan(job.window.start, 0.2)
        let read = try await yielded(job)
        XCTAssertGreaterThan(read, 4)
        XCTAssertLessThan(read, 24)
        let plan = Planner.plan(job.planRequest(frames: read))
        let run = try await export(job)
        try await assertPlayable(
            name: "trim-audio",
            result: run.result,
            pipeline: run.pipeline,
            expectedFrames: plan.samples.count,
            expectedFPS: plan.outputFPS,
            audio: true,
            windowStart: job.window.start
        )
    }

    func testResolutionLimitAndTinyFrame() async throws {
        let url = try ClipFactory.write(ClipFactory.Spec(frames: 8, fps: 30, width: 160, height: 96, name: "cap"))
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try await VideoProbe.probe(url)
        let job = makeJob(url: url, info: info) {
            $0.export.maxResolution = .p720
            $0.interpolation.multiplier = 2
        }
        let size = job.outputPixelSize()
        XCTAssertEqual(size.width, 160)
        XCTAssertEqual(size.height, 96)
        let run = try await export(job)
        let capped = try XCTUnwrap(run.result)
        XCTAssertEqual(capped.width, 160)
        XCTAssertEqual(capped.height, 96)
        try await assertPlayable(
            name: "resolution-cap",
            result: run.result,
            pipeline: run.pipeline,
            expectedFrames: 15,
            expectedFPS: info.fps * 2,
            audio: false,
            windowStart: 0
        )

        let tinyURL = try ClipFactory.write(ClipFactory.Spec(frames: 6, fps: 30, width: 16, height: 16, name: "tiny"))
        defer { try? FileManager.default.removeItem(at: tinyURL) }
        let tinyInfo = try await VideoProbe.probe(tinyURL)
        XCTAssertTrue(tinyInfo.dimensionsAdjusted)
        XCTAssertEqual(tinyInfo.width, 16)
        XCTAssertEqual(tinyInfo.height, 16)
        let tiny = makeJob(url: tinyURL, info: tinyInfo) { $0.interpolation.multiplier = 2 }
        let tinyRun = try await export(tiny)
        try await assertPlayable(
            name: "tiny",
            result: tinyRun.result,
            pipeline: tinyRun.pipeline,
            expectedFrames: Timing.interpolationFrameCount(sourceFrames: 6, sourceFPS: tinyInfo.fps, outputFPS: tinyInfo.fps * 2, loop: false),
            expectedFPS: tinyInfo.fps * 2,
            audio: false,
            windowStart: 0
        )
    }

    func testHEVCAndProRes() async throws {
        let url = try ClipFactory.write(ClipFactory.Spec(frames: 8, fps: 30, name: "codecs"))
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try await VideoProbe.probe(url)
        let hevcJob = makeJob(url: url, info: info) {
            $0.export.codec = .hevc
            $0.interpolation.multiplier = 2
        }
        let hevc = try await export(hevcJob)
        let hevcResult = try XCTUnwrap(hevc.result)
        let hevcFacts = try await MediaInspect.inspect(hevcResult.url)
        let hevcProbe = try await VideoProbe.probe(hevcResult.url)
        print("EVII_QA hevc requested codec=\(hevcProbe.codecLabel) playable=\(hevcFacts.playable)")
        if EncoderSupport.hevcAvailable() {
            XCTAssertTrue(hevcProbe.codecLabel.contains("HEVC") || hevcProbe.codecLabel.contains("hvc"))
        } else {
            XCTAssertTrue(hevc.logs.contains { $0.contains("HEVC") })
            XCTAssertEqual(hevcProbe.codecLabel, "H.264")
        }
        try await assertPlayable(
            name: "hevc",
            result: hevc.result,
            pipeline: hevc.pipeline,
            expectedFrames: 15,
            expectedFPS: info.fps * 2,
            audio: false,
            windowStart: 0
        )

        let proresJob = makeJob(url: url, info: info) {
            $0.export.codec = .prores
            $0.interpolation.multiplier = 2
        }
        let prores = try await export(proresJob)
        let proresResult = try XCTUnwrap(prores.result)
        let proresProbe = try await VideoProbe.probe(proresResult.url)
        print("EVII_QA prores available=\(EncoderSupport.proResAvailable()) codec=\(proresProbe.codecLabel)")
        if EncoderSupport.proResAvailable() {
            XCTAssertEqual(proresProbe.codecLabel, "ProRes")
        } else {
            XCTAssertTrue(prores.logs.contains { $0.contains("ProRes") })
            XCTAssertTrue(proresProbe.codecLabel == "HEVC" || proresProbe.codecLabel == "H.264")
        }
        let facts = try await MediaInspect.inspect(proresResult.url)
        XCTAssertTrue(facts.playable)
        XCTAssertEqual(facts.videoFrames, proresResult.frameCount)
    }

    func testThirtySecondStreamCancelsWithoutBuffering() async throws {
        let url = try ClipFactory.write(ClipFactory.Spec(frames: 900, fps: 30, width: 96, height: 64, name: "thirty"))
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try await VideoProbe.probe(url)
        let job = makeJob(url: url, info: info) {
            $0.interpolation.multiplier = 8
            $0.window = SourceWindow.full(info)
        }
        XCTAssertLessThanOrEqual(job.window.duration, 30.05)
        let run = try await export(job, cancelAfterInterpolated: 1)
        XCTAssertTrue(run.cancelled)
        XCTAssertGreaterThanOrEqual(run.progress.sourceFrames, 800)
        XCTAssertLessThanOrEqual(run.pipeline.peakCachedFrames, 8)
        print("EVII_QA thirty source=\(run.progress.sourceFrames) peakCache=\(run.pipeline.peakCachedFrames)")
    }

    func testFullHDThirtySecondsX8StaysUnderFiveGigabytes() async throws {
        let url = try ClipFactory.write(ClipFactory.Spec(frames: 900, fps: 30, width: 1920, height: 1080, name: "hd30"))
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try await VideoProbe.probe(url)
        let job = makeJob(url: url, info: info) {
            $0.interpolation.multiplier = 8
            $0.export.maxResolution = .p1080
            $0.export.codec = .h264
            $0.window = SourceWindow.full(info)
        }
        let size = job.outputPixelSize()
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
        let run = try await export(job, cancelAfterInterpolated: 1)
        XCTAssertTrue(run.cancelled)
        XCTAssertGreaterThanOrEqual(run.progress.sourceFrames, 800)
        XCTAssertLessThanOrEqual(run.pipeline.peakCachedFrames, 8, "1080p x8 buffered frames instead of streaming")
        let limit = UInt64(5) * 1024 * 1024 * 1024
        print("EVII_QA hd30 footprint=\(run.peakFootprint) limit=\(limit) peakCache=\(run.pipeline.peakCachedFrames) source=\(run.progress.sourceFrames)")
        XCTAssertGreaterThan(run.peakFootprint, 0)
        XCTAssertLessThan(run.peakFootprint, limit)
    }

    private struct ExportRun {
        var result: JobResult?
        var pipeline: VideoPipeline
        var progress: PipelineProgress
        var logs: [String]
        var cancelled: Bool
        var peakFootprint: UInt64
    }

    private func expectInterpolation(
        frames: Int,
        fps: Double,
        width: Int = 160,
        height: Int = 96,
        multiplier: Int,
        targetFPS: Double? = nil,
        maxFPS: Double? = nil,
        audio: Bool,
        name: String,
        maximumQuality: Bool = false
    ) async throws {
        let url = try ClipFactory.write(ClipFactory.Spec(frames: frames, fps: fps, width: width, height: height, audio: audio, name: name))
        defer { try? FileManager.default.removeItem(at: url) }
        let stored = try await MediaInspect.inspect(url)
        XCTAssertEqual(stored.videoFrames, frames, name)
        XCTAssertTrue(stored.playable, name)
        let info = try await VideoProbe.probe(url)
        let job = makeJob(url: url, info: info) {
            $0.interpolation.multiplier = multiplier
            $0.interpolation.useTargetFPS = targetFPS != nil
            if let targetFPS { $0.interpolation.targetFPS = targetFPS }
            if let maxFPS {
                $0.export.maxFPS = maxFPS >= 240 ? .p240 : (maxFPS >= 120 ? .p120 : .p60)
            }
            $0.export.keepAudio = audio
            $0.interpolation.maximumQuality = maximumQuality
        }
        let read = try await yielded(job)
        XCTAssertEqual(read, frames, "\(name) FrameSource")
        let outputFPS = Timing.interpolationOutputFPS(
            sourceFPS: info.fps,
            multiplier: multiplier,
            targetFPS: targetFPS,
            maxFPS: job.export.maxFPS.fps
        )
        let expected = Timing.interpolationFrameCount(sourceFrames: frames, sourceFPS: info.fps, outputFPS: outputFPS, loop: false)
        let run = try await export(job)
        try await assertPlayable(
            name: name,
            result: run.result,
            pipeline: run.pipeline,
            expectedFrames: expected,
            expectedFPS: outputFPS,
            audio: audio,
            windowStart: 0
        )
    }

    private func makeJob(url: URL, info: VideoInfo, _ body: (inout ClipJob) -> Void) -> ClipJob {
        var job = ClipJob(
            sourceURL: url,
            info: info,
            window: SourceWindow(start: 0, end: info.duration),
            mode: .interpolation,
            slow: SlowMoSettings(),
            interpolation: InterpolationSettings(),
            export: ExportSettings()
        )
        job.export.codec = .h264
        job.export.quality = 60
        job.export.maxResolution = .p1080
        job.export.keepAudio = info.hasAudio
        job.interpolation.model = .rife425
        job.interpolation.multiplier = 2
        job.interpolation.skipSceneChanges = true
        job.interpolation.dedup = .off
        job.interpolation.loop = false
        body(&job)
        return job
    }

    private func yielded(_ job: ClipJob) async throws -> Int {
        let size = job.outputPixelSize()
        let source = FrameSource(
            url: job.sourceURL,
            window: job.window,
            fps: job.info.fps,
            width: size.width,
            height: size.height
        )
        try await source.start()
        var count = 0
        while source.next() != nil { count += 1 }
        return count
    }

    private func export(_ job: ClipJob, cancelAfterInterpolated: Int? = nil) async throws -> ExportRun {
        let pipeline = VideoPipeline()
        let flag = CancelFlag()
        let box = ProgressBox()
        let callbacks = PipelineCallbacks(
            progress: { progress, _ in
                box.progress = progress
                box.peakFootprint = max(box.peakFootprint, ResidentMemory.footprint())
                if let cancelAfterInterpolated, progress.phase == .interpolation, progress.frameIndex >= cancelAfterInterpolated {
                    flag.cancel()
                }
            },
            log: { box.logs.append($0) },
            isCancelled: { flag.isCancelled },
            pause: nil
        )
        do {
            let result = try await pipeline.run(job: job, queueIndex: 1, queueCount: 1, callbacks: callbacks)
            box.peakFootprint = max(box.peakFootprint, ResidentMemory.footprint())
            return ExportRun(result: result, pipeline: pipeline, progress: box.progress, logs: box.logs, cancelled: false, peakFootprint: box.peakFootprint)
        } catch PipelineError.cancelled {
            return ExportRun(result: nil, pipeline: pipeline, progress: box.progress, logs: box.logs, cancelled: true, peakFootprint: box.peakFootprint)
        }
    }

    private func assertPlayable(
        name: String,
        result: JobResult?,
        pipeline: VideoPipeline,
        expectedFrames: Int,
        expectedFPS: Double,
        audio: Bool,
        windowStart: Double
    ) async throws {
        let result = try XCTUnwrap(result, name)
        XCTAssertEqual(result.frameCount, expectedFrames, name)
        XCTAssertEqual(result.fps, expectedFPS, accuracy: 0.25, name)
        XCTAssertLessThanOrEqual(pipeline.peakCachedFrames, 8, name)
        let facts = try await MediaInspect.inspect(result.url)
        XCTAssertTrue(facts.playable, name)
        XCTAssertEqual(facts.videoFrames, expectedFrames, name)
        XCTAssertEqual(facts.width, result.width, name)
        XCTAssertEqual(facts.height, result.height, name)
        if expectedFrames > 1 {
            let measured = Double(expectedFrames - 1) / max(facts.span, 0.0001)
            XCTAssertEqual(measured, expectedFPS, accuracy: max(1.5, expectedFPS * 0.04), name)
        }
        XCTAssertEqual(facts.duration, result.duration, accuracy: max(0.15, 2.0 / expectedFPS), "\(name) duration")
        if audio {
            XCTAssertTrue(facts.hasAudio, name)
            let start = try XCTUnwrap(facts.firstAudioPTS, name)
            XCTAssertLessThan(start, windowStart > 0.2 ? 0.08 : 0.15, "\(name) audio pts \(start)")
            XCTAssertGreaterThanOrEqual(start, -0.02, name)
            let audioSpan = try XCTUnwrap(facts.audioSpan, name)
            XCTAssertEqual(audioSpan, facts.span, accuracy: 0.35, "\(name) audio sync")
        }
        let payload = "{\"name\":\"\(name)\",\"frames\":\(facts.videoFrames),\"fps\":\(String(format: "%.3f", result.fps)),\"span\":\(String(format: "%.3f", facts.span)),\"audio\":\(audio),\"peakCache\":\(pipeline.peakCachedFrames),\"elapsed\":\(String(format: "%.2f", result.elapsed))}"
        print("EVII_QA \(payload)")
    }

    private final class ProgressBox {
        var progress = PipelineProgress()
        var logs: [String] = []
        var peakFootprint: UInt64 = 0
    }
}

enum ResidentMemory {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        // TASK_VM_INFO_COUNT is a C macro the iOS SDK does not expose to Swift.
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
