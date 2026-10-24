import AudioToolbox
import AVFoundation
import CoreImage
import CoreMedia
import Foundation

actor PauseGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var alreadyOpen = false

    func wait() async throws {
        if alreadyOpen {
            alreadyOpen = false
            return
        }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume() {
        alreadyOpen = true
        continuation?.resume()
        continuation = nil
    }

    func cancel() {
        continuation?.resume(throwing: PipelineError.cancelled)
        continuation = nil
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

struct PipelineCallbacks {
    var progress: (PipelineProgress, CGImage?) -> Void
    var log: (String) -> Void
    var isCancelled: () -> Bool
    var pause: PauseGate?
}

final class VideoPipeline {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastPreview = Date.distantPast

    func run(job: ClipJob, queueIndex: Int, queueCount: Int, callbacks: PipelineCallbacks) async throws -> JobResult {
        let started = Date()
        var progress = PipelineProgress()
        progress.queueIndex = queueIndex
        progress.queueCount = queueCount
        try check(callbacks)

        let outputSize = job.outputPixelSize()
        callbacks.log("Вихід \(outputSize.width)×\(outputSize.height), режим \(job.mode == .slowMo ? "сповільнення" : "інтерполяція")")
        if job.interpolation.uhd {
            callbacks.log("UHD: окрему Core ML-модель зі scale 0.5 не зібрано. Лишаю RIFE 4.25.")
        }
        if job.interpolation.preferFP32 {
            callbacks.log("FP32: зібрана модель — FP16. Перемикач у v0.1 не змінює ваги.")
        }
        if job.interpolation.model != .rife425 {
            callbacks.log("\(job.interpolation.model.title) ще не підключена. Беру RIFE 4.25.")
        }

        let bucket = Geometry.bucket(width: outputSize.width, height: outputSize.height)
        let model = try RIFEModel.loadBest(containing: outputSize.width, height: outputSize.height)
        callbacks.log("Модель \(model.width)×\(model.height), compute \(model.computeLabel)")
        if bucket.h != model.height || bucket.w != model.width {
            callbacks.log("Найближча зібрана модель \(model.height)×\(model.width)")
        }

        progress.phase = .analysis
        callbacks.progress(progress, nil)
        let analysis = try await analyze(job: job, outputSize: outputSize, progress: &progress, callbacks: callbacks)
        progress.sourceFrames = analysis.signatures
        progress.sceneCuts = analysis.cuts.count
        progress.duplicates = analysis.duplicates.count
        callbacks.log("Аналіз: \(analysis.signatures) кадрів, \(analysis.cuts.count) сцен, \(analysis.duplicates.count) дублікатів")

        if job.interpolation.style == .stepwise {
            progress.phase = .paused
            progress.detail = "Перевірте сцени й дублікати"
            callbacks.progress(progress, nil)
            try await callbacks.pause?.wait()
            try check(callbacks)
        }

        var request = job.planRequest(
            frames: analysis.signatures,
            cuts: job.interpolation.skipSceneChanges ? Set(analysis.cuts) : [],
            duplicates: Set(analysis.duplicates),
            loopCut: analysis.loopCut
        )
        if !job.interpolation.skipSceneChanges {
            request.cuts = []
            request.loopCut = false
        }
        let plan = Planner.plan(request)
        guard !plan.samples.isEmpty else { throw PipelineError.writer("Порожній план кадрів") }

        let outputURL = try outputURL(for: job, fps: plan.outputFPS)
        let audioPlan: AudioPlan = {
            guard job.export.keepAudio, job.info.hasAudio else { return .none }
            if job.mode == .slowMo || job.export.minimumDuration != nil { return .rebuild }
            return .passthrough
        }()
        let pcm = audioPlan == .rebuild ? await decodePCM(job: job, callbacks: callbacks) : []
        let writer = try makeWriter(job: job, url: outputURL, size: outputSize, fps: plan.outputFPS, audio: audioPlan)
        guard writer.writer.startWriting() else {
            throw PipelineError.writer(writer.writer.error?.localizedDescription ?? "AVAssetWriter")
        }
        writer.writer.startSession(atSourceTime: .zero)
        if audioPlan == .passthrough {
            await passthroughAudio(job: job, limit: plan.outputDuration, writer: writer, callbacks: callbacks)
        } else if audioPlan == .rebuild, !pcm.isEmpty {
            await writePCM(pcm, job: job, plan: plan, request: request, writer: writer, callbacks: callbacks)
        }

        progress.phase = .interpolation
        progress.frameCount = plan.samples.count
        progress.fraction = 0
        callbacks.progress(progress, nil)

        let source = FrameSource(
            url: job.sourceURL,
            window: job.window,
            fps: job.info.fps,
            width: outputSize.width,
            height: outputSize.height
        )
        try await source.start()
        var cache: [Int: CVPixelBuffer] = [:]
        var readIndex = 0
        var rateStart = Date()
        var rateFrames = 0

        for (ordinal, sample) in plan.samples.enumerated() {
            try check(callbacks)
            if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                progress.detail = "Пауза: телефон перегрівся"
                callbacks.progress(progress, nil)
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let need = max(sample.left, sample.right)
            while readIndex <= need {
                guard let frame = source.next() else { break }
                cache[readIndex] = frame
                readIndex += 1
            }
            guard let left = cache[sample.left] ?? cache[max(0, readIndex - 1)] else { break }
            let right = cache[sample.right] ?? left
            let rendered: CVPixelBuffer
            if sample.hold || sample.left == sample.right || sample.timestep < 0.0008 {
                rendered = left
            } else {
                rendered = try model.interpolate(frame0: left, frame1: right, timestep: sample.timestep)
            }
            try await append(rendered, at: sample.presentationSeconds, writer: writer)
            if request.loop {
                cache = cache.filter { $0.key == 0 || $0.key >= sample.left }
            } else {
                cache = cache.filter { $0.key >= sample.left }
            }
            rateFrames += 1
            let elapsed = Date().timeIntervalSince(rateStart)
            if elapsed >= 0.4 {
                progress.framesPerSecond = Double(rateFrames) / elapsed
                rateFrames = 0
                rateStart = Date()
            }
            progress.frameIndex = ordinal + 1
            progress.fraction = Double(ordinal + 1) / Double(plan.samples.count)
            progress.timestep = sample.timestep
            if progress.framesPerSecond > 0.05 {
                progress.eta = Double(plan.samples.count - ordinal - 1) / progress.framesPerSecond
            }
            let preview = Date().timeIntervalSince(lastPreview) > 0.25 ? cgImage(rendered) : nil
            if preview != nil { lastPreview = Date() }
            callbacks.progress(progress, preview)
        }

        progress.phase = .encoding
        progress.fraction = 0.99
        progress.detail = "Завершуємо файл"
        callbacks.progress(progress, nil)
        writer.video.markAsFinished()
        writer.audio?.markAsFinished()
        await writer.writer.finishWriting()
        if writer.writer.status != .completed {
            throw PipelineError.writer(writer.writer.error?.localizedDescription ?? "finishWriting")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress.phase = .finished
        progress.fraction = 1
        progress.eta = 0
        callbacks.progress(progress, nil)
        return JobResult(
            url: outputURL,
            filename: outputURL.lastPathComponent,
            frameCount: plan.samples.count,
            fps: plan.outputFPS,
            duration: displayedDuration(job: job, plan: plan),
            fileSize: bytes,
            elapsed: Date().timeIntervalSince(started),
            width: outputSize.width,
            height: outputSize.height
        )
    }

    private struct Analysis {
        var signatures: Int
        var cuts: [Int]
        var duplicates: [Int]
        var loopCut: Bool
    }

    private func analyze(
        job: ClipJob,
        outputSize: (width: Int, height: Int),
        progress: inout PipelineProgress,
        callbacks: PipelineCallbacks
    ) async throws -> Analysis {
        let source = FrameSource(
            url: job.sourceURL,
            window: job.window,
            fps: job.info.fps,
            width: outputSize.width,
            height: outputSize.height
        )
        try await source.start()
        var fast: [[Float]] = []
        var accurate: [[Float]] = []
        let expected = max(1, job.activeFrameCount)
        while let frame = source.next() {
            try check(callbacks)
            let plane = PixelBuffers.luma(frame, width: 96, height: 96)
            fast.append(LumaGrid.fromLuma(plane, width: 96, height: 96, grid: 8))
            accurate.append(LumaGrid.fromLuma(plane, width: 96, height: 96, grid: 24))
            progress.fraction = min(0.99, Double(fast.count) / Double(expected))
            progress.frameIndex = fast.count
            progress.frameCount = expected
            if fast.count % 5 == 0 { callbacks.progress(progress, nil) }
        }
        let sensitivity = job.interpolation.sceneSensitivity
        let cuts = SceneDetector.cutIndices(signatures: accurate, sensitivity: sensitivity)
        let dedupSigs = job.interpolation.dedup == .fast ? fast : accurate
        var duplicates = Dedup.duplicateIndices(
            signatures: dedupSigs,
            mode: job.interpolation.dedup,
            thresholdPercent: job.interpolation.dedupThresholdPercent
        )
        duplicates.removeAll { cuts.contains($0) }
        var loopCut = false
        if job.interpolation.loop, let first = accurate.first, let last = accurate.last, accurate.count > 1 {
            loopCut = SceneDetector.isCut(last, first, sensitivity: sensitivity)
        }
        return Analysis(signatures: fast.count, cuts: cuts, duplicates: duplicates, loopCut: loopCut)
    }

    private final class WriterBox {
        var writer: AVAssetWriter
        var video: AVAssetWriterInput
        var adaptor: AVAssetWriterInputPixelBufferAdaptor
        var audio: AVAssetWriterInput?
        init(writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, audio: AVAssetWriterInput?) {
            self.writer = writer
            self.video = video
            self.adaptor = adaptor
            self.audio = audio
        }
    }

    private enum AudioPlan {
        case none
        case passthrough
        case rebuild
    }

    private func makeWriter(job: ClipJob, url: URL, size: (width: Int, height: Int), fps: Double, audio: AudioPlan) throws -> WriterBox {
        let container = job.export.resolvedContainer
        let fileType: AVFileType = container == .mp4 ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        if job.export.keepMetadata {
            writer.metadata = metadataItems(job.info)
        }
        var codec = job.export.codec
        if codec == .prores && !EncoderSupport.proResAvailable() {
            codec = .hevc
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(codec: codec, size: size, fps: fps, job: job))
        video.expectsMediaDataInRealTime = false
        guard writer.canAdd(video) else { throw PipelineError.writer("Кодек \(codec.title) недоступний на цьому пристрої") }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ]
        )
        var audioInput: AVAssetWriterInput?
        if audio == .passthrough {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        } else if audio == .rebuild {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        return WriterBox(writer: writer, video: video, adaptor: adaptor, audio: audioInput)
    }

    private func videoSettings(codec: CodecChoice, size: (width: Int, height: Int), fps: Double, job: ClipJob) -> [String: Any] {
        if codec == .prores {
            return [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
            ]
        }
        let bytes = Timing.estimatedBytes(
            width: size.width,
            height: size.height,
            frames: max(2, job.planRequest().sourceFrames),
            quality: job.export.quality,
            codec: codec
        )
        let bitrate = max(500_000, Int(Double(bytes) * 8 / max(job.activeDuration, 0.2)))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: 60,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let codecKey: AVVideoCodecType = codec == .h264 ? .h264 : .hevc
        return [
            AVVideoCodecKey: codecKey,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private func append(_ buffer: CVPixelBuffer, at seconds: Double, writer: WriterBox) async throws {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 60_000)
        var spins = 0
        while !writer.video.isReadyForMoreMediaData {
            spins += 1
            if spins > 3000 { throw PipelineError.writer("Кодер не встигає") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !writer.adaptor.append(buffer, withPresentationTime: time) {
            throw PipelineError.writer(writer.writer.error?.localizedDescription ?? "append")
        }
    }

    private func outputURL(for job: ClipJob, fps: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EviiFrames", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let factor = job.mode == .slowMo ? job.slow.factor : job.interpolation.multiplier
        let name = FilenamePattern.render(
            pattern: job.export.filenamePattern,
            name: job.info.filename,
            fps: fps,
            factor: factor
        )
        let url = directory.appendingPathComponent("\(name).\(job.export.resolvedContainer.fileExtension)")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func metadataItems(_ info: VideoInfo) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let date = info.creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierCreationDate
            item.value = ISO8601DateFormatter().string(from: date) as NSString
            items.append(item)
        }
        if let lat = info.latitude, let lon = info.longitude {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierLocation
            item.value = VideoProbe.iso6709(latitude: lat, longitude: lon) as NSString
            items.append(item)
        }
        return items
    }

    private func cgImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }

    private func displayedDuration(job: ClipJob, plan: Plan) -> Double {
        if job.mode == .slowMo || job.export.minimumDuration != nil {
            return plan.outputDuration
        }
        return job.activeDuration
    }

    private func check(_ callbacks: PipelineCallbacks) throws {
        if callbacks.isCancelled() || Task.isCancelled { throw PipelineError.cancelled }
    }

    private func decodePCM(job: ClipJob, callbacks: PipelineCallbacks) async -> [Int16] {
        let asset = AVURLAsset(url: job.sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        do {
            return try await readPCM(asset: asset, track: track, window: job.window)
        } catch {
            callbacks.log("Аудіо пропущено: \(error.localizedDescription)")
            return []
        }
    }

    private func readPCM(asset: AVURLAsset, track: AVAssetTrack, window: SourceWindow) async throws -> [Int16] {
        let rate = 44_100.0
        let channels = 2
        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: window.start, preferredTimescale: 60_000)
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: max(0.01, window.duration), preferredTimescale: 60_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var pcm = [Int16]()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var data: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data) == noErr,
                  let data else { continue }
            let count = length / MemoryLayout<Int16>.size
            pcm.append(contentsOf: UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self), count: count))
        }
        return pcm
    }

    private func passthroughAudio(job: ClipJob, limit: Double, writer: WriterBox, callbacks: PipelineCallbacks) async {
        guard let input = writer.audio else { return }
        let asset = AVURLAsset(url: job.sourceURL)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if pts > limit + 0.05 { break }
                var spins = 0
                while !input.isReadyForMoreMediaData && spins < 3000 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    spins += 1
                }
                if !input.append(sample) { break }
            }
        } catch {
            callbacks.log("Аудіо пропущено: \(error.localizedDescription)")
        }
    }

    private func writePCM(
        _ pcm: [Int16],
        job: ClipJob,
        plan: Plan,
        request: PlanRequest,
        writer: WriterBox,
        callbacks: PipelineCallbacks
    ) async {
        guard let input = writer.audio else { return }
        let rate = 44_100.0
        let channels = 2
        let map: SlowMoMap? = {
            if case .slowMo(let factor, let fragment) = request.kind {
                return SlowMoMap(clipDuration: request.sourceDuration, fragment: fragment, factor: Double(factor))
            }
            return nil
        }()
        let total = Int(plan.outputDuration * rate)
        let chunk = 4096
        var frame = 0
        while frame < total {
            let count = min(chunk, total - frame)
            var samples = [Int16](repeating: 0, count: count * channels)
            for i in 0..<count {
                let outputTime = Double(frame + i) / rate
                let sourceTime: Double
                let muted: Bool
                if let map {
                    sourceTime = map.sourceTime(at: outputTime)
                    muted = job.slow.fragmentAudio == .mute && map.isSlowed(sourceTime: sourceTime)
                } else {
                    let cycle = max(request.sourceDuration, 0.001)
                    sourceTime = outputTime.truncatingRemainder(dividingBy: cycle)
                    muted = false
                }
                if muted { continue }
                let sourceFrame = Int((sourceTime * rate).rounded())
                let base = sourceFrame * channels
                if base >= 0, base + channels <= pcm.count {
                    for c in 0..<channels {
                        samples[i * channels + c] = pcm[base + c]
                    }
                }
            }
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate))
            if let buffer = Self.pcmBuffer(samples, frames: count, channels: channels, rate: rate, pts: pts) {
                var spins = 0
                while !input.isReadyForMoreMediaData && spins < 3000 {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    spins += 1
                }
                if !input.append(buffer) {
                    callbacks.log("Аудіо обрізано під час запису")
                    break
                }
            }
            frame += count
        }
    }

    private static func pcmBuffer(_ samples: [Int16], frames: Int, channels: Int, rate: Double, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        let byteCount = frames * channels * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }
}
