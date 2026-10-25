import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

private final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func mark() {
        lock.lock()
        done = true
        lock.unlock()
    }
    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}

enum ClipFactoryError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "" }
}

/// Synthetic H.264 clips. Real camera files are not in CI; these still go through
/// AVAssetWriter → the app pipeline → AVAssetReader.
enum ClipFactory {
    struct Spec {
        var frames: Int
        var fps: Double = 30
        var width: Int = 160
        var height: Int = 96
        var audio: Bool = false
        var cutAt: Int? = nil
        var duplicateFrames: Set<Int> = []
        var variableTiming: Bool = false
        var pq: Bool = false
        var name: String = "clip"
    }

    static func write(_ spec: Spec) throws -> URL {
        guard spec.frames >= 1, spec.fps > 1, spec.width >= 2, spec.height >= 2 else {
            throw ClipFactoryError.message("Порожня специфікація кліпу")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("evii-qa-\(spec.name)-\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(200_000, spec.width * spec.height * 4),
            AVVideoExpectedSourceFrameRateKey: spec.fps,
        ]
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if spec.pq {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
            ]
        )
        guard writer.canAdd(video) else {
            throw ClipFactoryError.message("H.264 \(spec.width)×\(spec.height) недоступний")
        }
        writer.add(video)
        var audio: AVAssetWriterInput?
        if spec.audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }
        guard writer.startWriting() else {
            writer.cancelWriting()
            throw ClipFactoryError.message(writerDetail(writer, fallback: "startWriting"))
        }
        var completed = false
        defer {
            if !completed { writer.cancelWriting() }
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = makePool(width: spec.width, height: spec.height) else {
            throw ClipFactoryError.message("CVPixelBufferPool")
        }
        let looks = appearances(spec)
        var cursor = 0.0
        // Audio is interleaved with the video like a camera file. Writing all video first
        // stalls once AVAssetWriter wants audio to catch up (about a second in).
        let length = (0..<spec.frames).reduce(0.0) { $0 + gap(spec, index: $1) }
        let tone = audio.map { ToneFeeder(input: $0, duration: length) }
        for index in 0..<spec.frames {
            _ = try tone?.feed(upTo: cursor + 0.3, writer: writer)
            try waitReady(video, writer: writer, feeding: tone)
            guard let buffer = take(pool) else {
                throw ClipFactoryError.message("CVPixelBuffer")
            }
            let look = looks[index]
            fill(buffer, luma: look.luma, barX: look.bar)
            let pts = CMTime(seconds: cursor, preferredTimescale: 60_000)
            if !adaptor.append(buffer, withPresentationTime: pts) {
                throw ClipFactoryError.message(writerDetail(writer, fallback: "append \(index)"))
            }
            cursor += gap(spec, index: index)
            if spec.frames > 200, index % 300 == 0 {
                print("EVII_QA writing \(spec.name) \(index)/\(spec.frames)")
            }
        }
        video.markAsFinished()
        if let audio, let tone {
            while !tone.isDone {
                try waitReady(audio, writer: writer)
                _ = try tone.feed(upTo: .infinity, writer: writer)
            }
            audio.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(seconds: max(cursor, 0.01), preferredTimescale: 60_000))
        let timeout = spec.frames > 200 ? 300.0 : 60.0
        try finish(writer, timeout: timeout)
        completed = true
        return url
    }

    static func writeAudioOnly() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("evii-qa-audio-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 64_000,
        ])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(audio) else { throw ClipFactoryError.message("audio") }
        writer.add(audio)
        guard writer.startWriting() else {
            writer.cancelWriting()
            throw ClipFactoryError.message(writerDetail(writer, fallback: "audio start"))
        }
        var completed = false
        defer {
            if !completed { writer.cancelWriting() }
        }
        writer.startSession(atSourceTime: .zero)
        try writeTone(audio, duration: 0.4, writer: writer)
        audio.markAsFinished()
        try finish(writer, timeout: 30)
        completed = true
        return url
    }

    static func writeEmpty() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("evii-qa-empty-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private struct Look {
        var luma: UInt8
        var bar: Int?
    }

    private static func appearances(_ spec: Spec) -> [Look] {
        var looks: [Look] = []
        for index in 0..<spec.frames {
            if spec.duplicateFrames.contains(index), index > 0 {
                looks.append(looks[index - 1])
            } else if let cut = spec.cutAt, index >= cut {
                looks.append(Look(luma: 245, bar: nil))
            } else if spec.width * spec.height > 80_000 {
                looks.append(Look(luma: UInt8(40 + (index % 20)), bar: nil))
            } else {
                let travel = max(1, spec.width / 2)
                looks.append(Look(luma: 28, bar: (index * 7) % travel))
            }
        }
        return looks
    }

    private static func gap(_ spec: Spec, index: Int) -> Double {
        guard spec.variableTiming else { return 1.0 / spec.fps }
        return index % 4 == 3 ? 0.12 : 0.008
    }

    private static func writerDetail(_ writer: AVAssetWriter, fallback: String) -> String {
        guard let error = writer.error as NSError? else { return "\(fallback) status=\(writer.status.rawValue)" }
        return "\(error.localizedDescription) [\(error.domain) \(error.code)]"
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        return status == kCVReturnSuccess ? pool : nil
    }

    private static func take(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    private static func fill(_ buffer: CVPixelBuffer, luma: UInt8, barX: Int?) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        if barX == nil {
            memset(bytes, Int32(luma), height * row)
            return
        }
        let start = barX ?? 0
        let end = start + max(2, width / 6)
        for y in 0..<height {
            let line = bytes.advanced(by: y * row)
            for x in 0..<width {
                let pixel = line.advanced(by: x * 4)
                let value: UInt8 = (x >= start && x < end) ? 230 : luma
                pixel[0] = value
                pixel[1] = value
                pixel[2] = value
                pixel[3] = 255
            }
        }
    }

    private static func waitReady(_ input: AVAssetWriterInput, writer: AVAssetWriter, feeding tone: ToneFeeder? = nil) throws {
        // RunLoop.run(until:) returns immediately when the loop is idle, so a
        // spin count expires while the writer is still .writing (status 1).
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            if let tone, try tone.feed(upTo: .infinity, writer: writer) {
                continue
            }
            if writer.status == .failed || writer.status == .cancelled {
                throw ClipFactoryError.message(writerDetail(writer, fallback: "кодер зупинився"))
            }
            if Date() >= deadline {
                throw ClipFactoryError.message(writerDetail(writer, fallback: "кодер не встигає"))
            }
            pump(0.02)
        }
    }

    private static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        RunLoop.current.run(mode: .common, before: end)
        let remain = end.timeIntervalSinceNow
        if remain > 0 {
            Thread.sleep(forTimeInterval: remain)
        }
    }

    private static func finish(_ writer: AVAssetWriter, timeout: Double) throws {
        let flag = FinishFlag()
        writer.finishWriting { flag.mark() }
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.isDone && Date() < deadline {
            pump(0.05)
        }
        guard flag.isDone else { throw ClipFactoryError.message("finishWriting timeout") }
        guard writer.status == .completed else {
            throw ClipFactoryError.message(writer.error?.localizedDescription ?? "finishWriting")
        }
    }

    private static func writeTone(_ input: AVAssetWriterInput, duration: Double, writer: AVAssetWriter) throws {
        let rate = 44_100
        let channels = 2
        let total = max(1, Int(duration * Double(rate)))
        let chunk = 2048
        var frame = 0
        while frame < total {
            try waitReady(input, writer: writer)
            let count = min(chunk, total - frame)
            var samples = [Int16](repeating: 0, count: count * channels)
            for i in 0..<count {
                let t = Double(frame + i) / Double(rate)
                let value = Int16(sin(t * 2 * Double.pi * 440) * 6000)
                samples[i * channels] = value
                samples[i * channels + 1] = value
            }
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate))
            guard let buffer = pcm(samples, frames: count, channels: channels, rate: rate, pts: pts) else {
                throw ClipFactoryError.message("PCM")
            }
            if !input.append(buffer) {
                throw ClipFactoryError.message(writer.error?.localizedDescription ?? "audio append")
            }
            frame += count
        }
    }

    fileprivate static func pcm(_ samples: [Int16], frames: Int, channels: Int, rate: Int, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate),
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
        return samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == noErr else {
                return nil
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
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
}

/// A 440 Hz tone handed to the writer a chunk at a time, only while the input takes it.
private final class ToneFeeder {
    private let input: AVAssetWriterInput
    private let total: Int
    private var frame = 0
    private let rate = 44_100
    private let channels = 2
    private let chunk = 2048

    init(input: AVAssetWriterInput, duration: Double) {
        self.input = input
        total = max(1, Int(duration * 44_100))
    }

    var isDone: Bool { frame >= total }

    func feed(upTo seconds: Double, writer: AVAssetWriter) throws -> Bool {
        var appended = false
        while !isDone, input.isReadyForMoreMediaData, Double(frame) / Double(rate) < seconds {
            let count = min(chunk, total - frame)
            var samples = [Int16](repeating: 0, count: count * channels)
            for i in 0..<count {
                let t = Double(frame + i) / Double(rate)
                let value = Int16(sin(t * 2 * Double.pi * 440) * 6000)
                samples[i * channels] = value
                samples[i * channels + 1] = value
            }
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate))
            guard let buffer = ClipFactory.pcm(samples, frames: count, channels: channels, rate: rate, pts: pts) else {
                throw ClipFactoryError.message("PCM")
            }
            if !input.append(buffer) {
                throw ClipFactoryError.message(writer.error?.localizedDescription ?? "audio append")
            }
            frame += count
            appended = true
        }
        return appended
    }
}
