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
    /// Full frames kept at once. A streaming run stays at a handful, including frame 0 when looping.
    private(set) var peakCachedFrames = 0

    func run(job: ClipJob, queueIndex: Int, queueCount: Int, callbacks: PipelineCallbacks) async throws -> JobResult {
        var job = job
        let started = Date()
        var progress = PipelineProgress()
        progress.queueIndex = queueIndex
        progress.queueCount = queueCount
        try check(callbacks)

        let fitted = job.outputPixelSize()
        var prefix = job.interpolation.model.packagePrefix
        if job.interpolation.uhd {
            callbacks.log("UHD у Practical-RIFE — це scale 0.5, грубіший рух. Окрему збірку не веземо: 4K іде своїм пакетом.")
        }
        if job.interpolation.preferFP32 {
            callbacks.log("FP32-перемикач зі старої збірки не міняє ваги. Згортки FP16, варп FP32.")
        }
        switch job.interpolation.model {
        case .rife425, .rife426, .rife426Heavy, .rife422, .rifeLite:
            break
        case .apple:
            prefix = "RIFE425"
            if AppleFrameRate.isRuntimeSupported {
                callbacks.log("VTFrameRateConversion isSupported. Сесію VTFrameProcessor не відкриваю, беру RIFE 4.25.")
            } else {
                callbacks.log("VTFrameRateConversion isSupported == false на цьому пристрої. Беру RIFE 4.25.")
            }
        }
        if RIFEModel.bundledModels(prefix: prefix).isEmpty {
            callbacks.log("Немає пакетів \(prefix). Беру RIFE 4.25.")
            prefix = "RIFE425"
        }
        let model = try RIFEModel.loadBest(prefix: prefix, containing: fitted.width, height: fitted.height)
        model.augment = job.interpolation.maximumQuality
        var outputSize = fitted
        if fitted.width > model.width || fitted.height > model.height {
            let scale = min(
                Double(model.width) / Double(max(fitted.width, 1)),
                Double(model.height) / Double(max(fitted.height, 1))
            )
            outputSize = (
                width: max(2, Geometry.even(Int((Double(fitted.width) * scale).rounded(.towardZero)))),
                height: max(2, Geometry.even(Int((Double(fitted.height) * scale).rounded(.towardZero))))
            )
            callbacks.log("Пакет \(model.packageName) менший за кадр. Зменшую до \(outputSize.width)×\(outputSize.height).")
        }
        callbacks.log("Вихід \(outputSize.width)×\(outputSize.height), режим \(job.mode == .slowMo ? "сповільнення" : "інтерполяція")")
        callbacks.log("Модель \(model.packageName), compute \(model.computeLabel)")
        if job.interpolation.maximumQuality {
            callbacks.log("Максимальна якість: 4 проходи (кадр, горизонталь, вертикаль, обидва). Близько ×4 часу. Телефон має лишатися відкритим.")
        }

        progress.phase = .analysis
        callbacks.progress(progress, nil)
        let analysis = try await analyze(job: job, outputSize: outputSize, progress: &progress, callbacks: callbacks)
        progress.sourceFrames = analysis.signatures
        progress.sceneCuts = analysis.cuts.count
        progress.duplicates = analysis.duplicates.count
        callbacks.log("Аналіз: \(analysis.signatures) кадрів, \(analysis.cuts.count) сцен, \(analysis.duplicates.count) дублікатів")
        progress.detail = "Готуємо запис"
        callbacks.progress(progress, nil)

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

        let resolved = EncoderSupport.resolved(job.export.codec)
        if let note = resolved.note {
            callbacks.log(note)
        }
        job.export.codec = resolved.codec

        let outputURL = try outputURL(for: job, fps: plan.outputFPS)
        // Compressed passthrough leaves the writer failed: AAC priming has a
        // negative decode timestamp, and the reader reuses the sample memory.
        // Rebuilding PCM keeps the same speed and starts a trimmed clip at zero.
        let audioPlan: AudioPlan = job.export.keepAudio && job.info.hasAudio ? .rebuild : .none
        let pcm = audioPlan == .rebuild ? await decodePCM(job: job, callbacks: callbacks) : []
        let writer = try makeWriter(job: job, url: outputURL, size: outputSize, fps: plan.outputFPS, audio: audioPlan)
        guard writer.writer.startWriting() else {
            let reason = Self.writerDetail(writer.writer, fallback: "AVAssetWriter")
            writer.writer.cancelWriting()
            throw PipelineError.writer(reason)
        }
        var sealed = false
        defer {
            if !sealed { writer.writer.cancelWriting() }
        }
        writer.writer.startSession(atSourceTime: .zero)
        if audioPlan == .passthrough {
            await passthroughAudio(job: job, limit: plan.outputDuration, writer: writer, callbacks: callbacks)
        }
        // Audio goes in alongside the video, never all up front. AVAssetWriter interleaves
        // its inputs: once the audio is about a second ahead of the video it stops being
        // ready, and writing the whole track first used to spin for ~30 s per chunk while
        // the screen still showed the analysis step.
        let feeder: PCMFeeder? = {
            guard audioPlan == .rebuild, !pcm.isEmpty, let input = writer.audio else { return nil }
            return PCMFeeder(pcm: pcm, job: job, plan: plan, request: request, input: input)
        }()
        if audioPlan == .rebuild, pcm.isEmpty {
            callbacks.log("Звук не прочитано, експорт без звуку")
        }

        progress.phase = .interpolation
        progress.frameCount = plan.samples.count
        progress.frameIndex = 0
        progress.fraction = 0
        progress.detail = ""
        callbacks.progress(progress, nil)

        let source = FrameSource(
            url: job.sourceURL,
            window: job.window,
            fps: job.info.fps,
            width: outputSize.width,
            height: outputSize.height
        )
        try await source.start()
        defer { source.stop() }
        var cache: [Int: CVPixelBuffer] = [:]
        var readIndex = 0
        var rateStart = Date()
        var rateFrames = 0

        var written = 0
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
                peakCachedFrames = max(peakCachedFrames, cache.count)
            }
            guard let left = cache[sample.left] ?? cache[max(0, readIndex - 1)] else { break }
            let right = cache[sample.right] ?? left
            let rendered: CVPixelBuffer
            if sample.hold || sample.left == sample.right || sample.timestep < 0.0008 {
                rendered = left
            } else {
                rendered = try model.interpolate(frame0: left, frame1: right, timestep: sample.timestep)
            }
            feeder?.feed(upTo: sample.presentationSeconds + 0.5)
            try await append(rendered, at: sample.presentationSeconds, writer: writer, feeder: feeder)
            written += 1
            if request.loop {
                cache = cache.filter { $0.key == 0 || $0.key >= sample.left }
            } else {
                cache = cache.filter { $0.key >= sample.left }
            }
            peakCachedFrames = max(peakCachedFrames, cache.count)
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

        if let failure = source.failure {
            throw PipelineError.writer("Не вдалося прочитати кадри: \(failure)")
        }
        if written == 0 {
            throw PipelineError.writer("Жоден кадр не записано")
        }
        if written != plan.samples.count {
            throw PipelineError.writer("Записано \(written) з \(plan.samples.count) кадрів")
        }

        progress.phase = .encoding
        progress.fraction = 0.99
        progress.detail = "Завершуємо файл"
        callbacks.progress(progress, nil)
        writer.video.markAsFinished()
        if let feeder {
            try await drain(feeder, writer: writer, callbacks: callbacks)
        }
        writer.audio?.markAsFinished()
        await writer.writer.finishWriting()
        sealed = writer.writer.status == .completed
        if !sealed {
            throw PipelineError.writer(Self.writerDetail(writer.writer, fallback: "finishWriting"))
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress.phase = .finished
        progress.fraction = 1
        progress.eta = 0
        callbacks.progress(progress, nil)
        return JobResult(
            url: outputURL,
            filename: outputURL.lastPathComponent,
            frameCount: written,
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
        defer { source.stop() }
        var fast: [[Float]] = []
        var accurate: [[Float]] = []
        // `expected` is only an estimate (duration × nominal fps). The loop ends when the
        // reader runs out of frames, whether that is before or after the estimate.
        let expected = max(1, job.activeFrameCount)
        var lastSent = Date.distantPast
        while let frame = source.next() {
            try check(callbacks)
            let plane = PixelBuffers.luma(frame, width: 96, height: 96)
            fast.append(LumaGrid.fromLuma(plane, width: 96, height: 96, grid: 8))
            accurate.append(LumaGrid.fromLuma(plane, width: 96, height: 96, grid: 24))
            let shownTotal = max(expected, fast.count + 1)
            progress.fraction = min(0.99, Double(fast.count) / Double(shownTotal))
            progress.frameIndex = fast.count
            progress.frameCount = shownTotal
            if fast.count == 1 {
                // The first decoded frame doubles as the preview until RIFE renders one.
                callbacks.progress(progress, cgImage(frame))
                lastSent = Date()
            } else if Date().timeIntervalSince(lastSent) >= 0.1 {
                callbacks.progress(progress, nil)
                lastSent = Date()
            }
        }
        if let failure = source.failure {
            throw PipelineError.writer("Не вдалося прочитати кадри (\(fast.count) з ≈\(expected)): \(failure)")
        }
        guard !fast.isEmpty else { throw PipelineError.noVideo }
        // Finish the step on the real count, even when the estimate was off.
        progress.fraction = 1
        progress.frameIndex = fast.count
        progress.frameCount = fast.count
        callbacks.progress(progress, nil)
        if fast.count != expected {
            callbacks.log("Аналіз: декодовано \(fast.count) кадрів, оцінка була \(expected)")
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
        let codec = EncoderSupport.resolved(job.export.codec).codec
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

    private func append(_ buffer: CVPixelBuffer, at seconds: Double, writer: WriterBox, feeder: PCMFeeder?) async throws {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let owned = PixelBuffers.make(width: width, height: height) else {
            throw PipelineError.writer("Кадр")
        }
        PixelBuffers.copy(buffer, into: owned)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 60_000)
        var spins = 0
        while !writer.video.isReadyForMoreMediaData {
            // The writer may be holding video back until the audio catches up.
            if let feeder, feeder.feed(upTo: .infinity) {
                continue
            }
            spins += 1
            if spins > 3000 || writer.writer.status == .failed {
                throw PipelineError.writer(Self.writerDetail(writer.writer, fallback: "Кодер не встигає"))
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !writer.adaptor.append(owned, withPresentationTime: time) {
            throw PipelineError.writer(Self.writerDetail(writer.writer, fallback: "append"))
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

    private static func writerDetail(_ writer: AVAssetWriter, fallback: String) -> String {
        let status = writer.status.rawValue
        guard let error = writer.error as NSError? else { return "\(fallback) status=\(status)" }
        return "\(error.localizedDescription) [\(error.domain) \(error.code)] status=\(status)"
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
            let start = CMTime(seconds: max(0, job.window.start), preferredTimescale: 60_000)
            reader.timeRange = CMTimeRange(
                start: start,
                duration: CMTime(seconds: max(0.01, job.window.duration), preferredTimescale: 60_000)
            )
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }
            var origin: CMTime?
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if origin == nil { origin = pts.isNumeric ? pts : .zero }
                let local = CMTimeSubtract(pts, origin ?? .zero).seconds
                if local > limit + 0.05 { break }
                guard let shifted = Self.retimed(sample, subtracting: origin ?? .zero) else { continue }
                var spins = 0
                while !input.isReadyForMoreMediaData && spins < 3000 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    spins += 1
                }
                if !input.append(shifted) { break }
            }
        } catch {
            callbacks.log("Аудіо пропущено: \(error.localizedDescription)")
        }
    }

    /// Sample timestamps from a trimmed reader stay on the source timeline.
    /// Video frames are written from 0, so audio has to move with them.
    private static func retimed(_ sample: CMSampleBuffer, subtracting origin: CMTime) -> CMSampleBuffer? {
        let count = max(CMSampleBufferGetNumSamples(sample), 1)
        var entries = [CMSampleTimingInfo](repeating: .invalid, count: count)
        var needed: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: entries.count,
            arrayToFill: &entries,
            entriesNeededOut: &needed
        ) == noErr else { return nil }
        for index in entries.indices {
            if entries[index].presentationTimeStamp.isNumeric {
                entries[index].presentationTimeStamp = CMTimeSubtract(entries[index].presentationTimeStamp, origin)
            }
            if entries[index].decodeTimeStamp.isNumeric {
                let shifted = CMTimeSubtract(entries[index].decodeTimeStamp, origin)
                // AAC priming sits before the first presentation time. A negative
                // decode timestamp makes AVAssetWriter fail the whole file.
                entries[index].decodeTimeStamp = shifted.seconds < 0 ? .invalid : shifted
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: entries.count,
            sampleTimingArray: &entries,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    /// Writes the rest of the audio after the last video frame. Video is already marked
    /// finished, so the writer no longer holds audio back. Stops with a log line, never hangs.
    private func drain(_ feeder: PCMFeeder, writer: WriterBox, callbacks: PipelineCallbacks) async throws {
        var idle = 0
        while !feeder.isDone {
            try check(callbacks)
            if writer.writer.status == .failed {
                throw PipelineError.writer(Self.writerDetail(writer.writer, fallback: "audio"))
            }
            if feeder.feed(upTo: .infinity) {
                idle = 0
                continue
            }
            if feeder.isDone { break }
            idle += 1
            if idle > 1000 {
                callbacks.log("Аудіо обрізано: кодер звуку не відповідав 10 с")
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if feeder.appendFailed {
            callbacks.log("Аудіо обрізано під час запису")
        }
    }

    /// Rebuilt PCM for the output timeline, handed to the writer a chunk at a time.
    final class PCMFeeder {
        static let rate = 44_100.0
        static let channels = 2
        static let chunk = 4096
        private let pcm: [Int16]
        private let input: AVAssetWriterInput
        private let map: SlowMoMap?
        private let muteSlowed: Bool
        private let cycle: Double
        let total: Int
        private(set) var frame = 0
        private(set) var appendFailed = false

        var isDone: Bool { frame >= total || appendFailed }

        init(pcm: [Int16], job: ClipJob, plan: Plan, request: PlanRequest, input: AVAssetWriterInput) {
            self.pcm = pcm
            self.input = input
            if case .slowMo(let factor, let fragment) = request.kind {
                map = SlowMoMap(clipDuration: request.sourceDuration, fragment: fragment, factor: Double(factor))
            } else {
                map = nil
            }
            muteSlowed = job.slow.fragmentAudio == .mute
            cycle = max(request.sourceDuration, 0.001)
            total = max(0, Int(plan.outputDuration * Self.rate))
        }

        /// Appends chunks that start before `seconds` while the input takes them. Never waits.
        /// Returns true when at least one chunk went in.
        @discardableResult
        func feed(upTo seconds: Double) -> Bool {
            var appended = false
            while !isDone, input.isReadyForMoreMediaData {
                let startSeconds = Double(frame) / Self.rate
                if startSeconds >= seconds { break }
                let count = min(Self.chunk, total - frame)
                let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(Self.rate))
                guard let buffer = VideoPipeline.pcmBuffer(
                    samples(from: frame, count: count),
                    frames: count,
                    channels: Self.channels,
                    rate: Self.rate,
                    pts: pts
                ) else {
                    frame += count
                    continue
                }
                if !input.append(buffer) {
                    appendFailed = true
                    break
                }
                frame += count
                appended = true
            }
            return appended
        }

        private func samples(from start: Int, count: Int) -> [Int16] {
            let channels = Self.channels
            var samples = [Int16](repeating: 0, count: count * channels)
            for i in 0..<count {
                let outputTime = Double(start + i) / Self.rate
                let sourceTime: Double
                if let map {
                    sourceTime = map.sourceTime(at: outputTime)
                    if muteSlowed && map.isSlowed(sourceTime: sourceTime) { continue }
                } else {
                    sourceTime = outputTime.truncatingRemainder(dividingBy: cycle)
                }
                let base = Int((sourceTime * Self.rate).rounded()) * channels
                if base >= 0, base + channels <= pcm.count {
                    for c in 0..<channels {
                        samples[i * channels + c] = pcm[base + c]
                    }
                }
            }
            return samples
        }
    }

    fileprivate static func pcmBuffer(_ samples: [Int16], frames: Int, channels: Int, rate: Double, pts: CMTime) -> CMSampleBuffer? {
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
