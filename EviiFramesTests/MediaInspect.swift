import AVFoundation
import CoreMedia
import Foundation
@testable import EviiFrames

struct MediaFacts {
    var videoFrames: Int
    var span: Double
    var minDelta: Double
    var width: Int
    var height: Int
    var nominalFPS: Double
    var duration: Double
    var playable: Bool
    var hasAudio: Bool
    var firstAudioPTS: Double?
    var audioSpan: Double?
}

enum MediaInspect {
    static func inspect(_ url: URL) async throws -> MediaFacts {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw PipelineError.noVideo }
        async let natural = track.load(.naturalSize)
        async let transform = track.load(.preferredTransform)
        async let nominal = track.load(.nominalFrameRate)
        let oriented = CGRect(origin: .zero, size: try await natural).applying(try await transform)
        let video = try await readVideo(asset: asset, track: track)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var firstAudio: Double?
        var audioSpan: Double?
        if let audio = audioTracks.first {
            let measured = try await readAudio(asset: asset, track: audio)
            firstAudio = measured.first
            audioSpan = measured.span
        }
        return MediaFacts(
            videoFrames: video.count,
            span: video.span,
            minDelta: video.minDelta,
            width: max(1, Int(abs(oriented.width).rounded())),
            height: max(1, Int(abs(oriented.height).rounded())),
            nominalFPS: Double(try await nominal),
            duration: duration,
            playable: playable,
            hasAudio: !audioTracks.isEmpty,
            firstAudioPTS: firstAudio,
            audioSpan: audioSpan
        )
    }

    private static func readVideo(asset: AVURLAsset, track: AVAssetTrack) async throws -> (count: Int, span: Double, minDelta: Double) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PipelineError.noVideo }
        reader.add(output)
        guard reader.startReading() else {
            throw PipelineError.writer(reader.error?.localizedDescription ?? "inspect")
        }
        var count = 0
        var first: CMTime?
        var previous: CMTime?
        var last: CMTime?
        var minDelta = Double.greatestFiniteMagnitude
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if first == nil { first = pts }
            if let previous, pts.isNumeric, previous.isNumeric {
                let delta = CMTimeSubtract(pts, previous).seconds
                if delta > 0.00001 { minDelta = min(minDelta, delta) }
            }
            previous = pts
            last = pts
            count += 1
        }
        if reader.status == .failed {
            throw PipelineError.writer(reader.error?.localizedDescription ?? "inspect failed")
        }
        let span: Double
        if let first, let last, count > 1 {
            span = max(0, CMTimeSubtract(last, first).seconds)
        } else {
            span = 0
        }
        if minDelta == Double.greatestFiniteMagnitude { minDelta = 0 }
        return (count, span, minDelta)
    }

    private static func readAudio(asset: AVURLAsset, track: AVAssetTrack) async throws -> (first: Double?, span: Double?) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return (nil, nil) }
        reader.add(output)
        guard reader.startReading() else { return (nil, nil) }
        var first: CMTime?
        var last: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric else { continue }
            if first == nil { first = pts }
            last = pts
        }
        guard let first, let last else { return (nil, nil) }
        return (first.seconds, max(0, CMTimeSubtract(last, first).seconds))
    }
}
