import Foundation

enum ScreenshotFixtures {
    static let interpID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!
    static let slowID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000002")!
    static let queue2 = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000003")!
    static let queue3 = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000004")!

    static func fileURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_4821_120fps.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        }
        return url
    }

    static func interpolationJob() -> ClipJob {
        var job = base(id: interpID, filename: "IMG_4821", fps: 29.97, duration: 2, frames: 60)
        job.mode = .interpolation
        job.interpolation.multiplier = 4
        job.interpolation.skipSceneChanges = true
        job.interpolation.sceneSensitivity = 0.40
        job.interpolation.dedup = .off
        job.interpolation.dedupThresholdPercent = 1
        job.export.maxFPS = .p120
        job.export.maxResolution = .p1080
        job.export.codec = .hevc
        job.export.container = .mov
        job.export.quality = 75
        job.export.keepAudio = true
        job.export.keepMetadata = true
        return job
    }

    static func slowJob() -> ClipJob {
        var job = base(id: slowID, filename: "IMG_4821", fps: 30, duration: 2, frames: 60)
        job.mode = .slowMo
        job.slow.wholeClip = false
        job.slow.fragmentStart = 0.30
        job.slow.fragmentEnd = 0.75
        job.slow.factor = 4
        job.slow.fragmentAudio = .mute
        return job
    }

    static func queueJobs() -> [ClipJob] {
        var a = interpolationJob()
        a.status = .running
        var b = slowJob()
        b.id = queue2
        b.info.filename = "IMG_1102"
        b.status = .queued
        var c = interpolationJob()
        c.id = queue3
        c.info.filename = "CLIP_08"
        c.interpolation.multiplier = 2
        c.status = .queued
        return [a, b, c]
    }

    static func result() -> JobResult {
        JobResult(
            url: fileURL(),
            filename: "IMG_4821_120fps.mov",
            frameCount: 237,
            fps: 119.88,
            duration: 2,
            fileSize: 18_000_000,
            elapsed: 34,
            width: 1920,
            height: 1080
        )
    }

    static func progress() -> PipelineProgress {
        var progress = PipelineProgress()
        progress.phase = .interpolation
        progress.fraction = 138.0 / 237.0
        progress.frameIndex = 138
        progress.frameCount = 237
        progress.sourceFrames = 60
        progress.sceneCuts = 1
        progress.duplicates = 0
        progress.framesPerSecond = 4.6
        progress.eta = 14
        progress.timestep = 0.50
        progress.queueIndex = 1
        progress.queueCount = 3
        return progress
    }

    static func recents() -> [RecentItem] {
        [
            RecentItem(id: UUID(), title: "x4 · 0.25x", subtitle: "", durationLabel: "0:02", thumbnailJPEG: nil, createdAt: Date()),
            RecentItem(id: UUID(), title: "x8 · 0.125x", subtitle: "", durationLabel: "0:01", thumbnailJPEG: nil, createdAt: Date()),
            RecentItem(id: UUID(), title: "120 fps", subtitle: "", durationLabel: "0:12", thumbnailJPEG: nil, createdAt: Date()),
        ]
    }

    private static func base(id: UUID, filename: String, fps: Double, duration: Double, frames: Int) -> ClipJob {
        let info = VideoInfo(
            filename: filename,
            width: 1920,
            height: 1080,
            fps: fps,
            duration: duration,
            frameCount: frames,
            fileSize: 8_400_000,
            hasAudio: true,
            codecLabel: "HEVC"
        )
        return ClipJob(
            id: id,
            sourceURL: fileURL(),
            info: info,
            window: SourceWindow(start: 0, end: duration),
            mode: .interpolation,
            slow: SlowMoSettings(),
            interpolation: InterpolationSettings(),
            export: ExportSettings(),
            isFixture: true
        )
    }
}
