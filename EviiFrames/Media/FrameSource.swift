import AVFoundation
import CoreMedia
import Foundation

/// Pulls upright BGRA frames for a time window, scaled to a fixed size.
/// Create a new source for each pass. Frames are copied, so the caller owns them.
final class FrameSource {
    let targetWidth: Int
    let targetHeight: Int
    private let asset: AVURLAsset
    private let window: SourceWindow
    private let fps: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderOutput?
    private(set) var yielded = 0
    private let ceiling: Int
    private var lastFrame: CVPixelBuffer?
    private var exhausted = false
    private var padUntil = 0
    /// Set when the reader stopped with an error instead of running out of frames.
    private(set) var failure: String?
    /// True once the reader has no more samples. The frame count is whatever was decoded,
    /// not the duration × fps estimate.
    var isExhausted: Bool { exhausted }

    init(url: URL, window: SourceWindow, fps: Double, width: Int, height: Int) {
        asset = AVURLAsset(url: url)
        self.window = window
        self.fps = max(fps, 1)
        targetWidth = width
        targetHeight = height
        ceiling = Int(window.duration * self.fps * 3) + 16
    }

    func start() async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw PipelineError.noVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let upright = Self.upright(natural: natural, transform: transform)

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: max(0, window.start), preferredTimescale: 60_000)
        let length = CMTime(seconds: max(0.01, window.duration), preferredTimescale: 60_000)
        reader.timeRange = CMTimeRange(start: start, duration: length)

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        if let composed = Self.compositionOutput(
            track: track,
            upright: upright,
            fps: fps,
            duration: duration,
            settings: settings
        ), reader.canAdd(composed) {
            reader.add(composed)
            output = composed
        } else {
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            trackOutput.alwaysCopiesSampleData = true
            guard reader.canAdd(trackOutput) else { throw PipelineError.noVideo }
            reader.add(trackOutput)
            output = trackOutput
        }
        guard reader.startReading() else {
            throw PipelineError.writer(reader.error?.localizedDescription ?? "Не вдалося прочитати кадри")
        }
        self.reader = reader
        yielded = 0
    }

    /// Releases the decoder early. Safe to call more than once.
    func stop() {
        if reader?.status == .reading {
            reader?.cancelReading()
        }
    }

    func next() -> CVPixelBuffer? {
        guard yielded < ceiling else { return nil }
        if !exhausted {
            if let output, let reader, reader.status == .reading {
                while let sample = output.copyNextSampleBuffer() {
                    guard let image = CMSampleBufferGetImageBuffer(sample),
                          let scaled = PixelBuffers.scale(image, width: targetWidth, height: targetHeight) else { continue }
                    lastFrame = scaled
                    yielded += 1
                    return scaled
                }
            }
            exhausted = true
            if reader?.status == .failed || reader == nil {
                failure = reader?.error?.localizedDescription ?? "AVAssetReader не запущено"
                // A failed read is not padded: the caller reports the error.
                padUntil = yielded
                return nil
            }
            // A variable-rate file can hand back fewer samples than duration × fps.
            // Hold the last frame so the timeline still matches the nominal rate.
            // A constant-rate clip is already within a couple of frames, so it is not padded.
            let nominal = Int((window.duration * self.fps).rounded())
            padUntil = yielded + 3 <= nominal ? nominal : yielded
        }
        if let lastFrame, yielded < padUntil {
            yielded += 1
            guard let copy = PixelBuffers.make(width: targetWidth, height: targetHeight) else { return nil }
            PixelBuffers.copy(lastFrame, into: copy)
            return copy
        }
        return nil
    }

    private static func upright(natural: CGSize, transform: CGAffineTransform) -> (size: CGSize, transform: CGAffineTransform) {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: max(2, abs(rect.width)), height: max(2, abs(rect.height)))
        let fixed = transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (size, fixed)
    }

    private static func compositionOutput(
        track: AVAssetTrack,
        upright: (size: CGSize, transform: CGAffineTransform),
        fps: Double,
        duration: CMTime,
        settings: [String: Any]
    ) -> AVAssetReaderVideoCompositionOutput? {
        let composition = AVMutableVideoComposition()
        composition.renderSize = upright.size
        composition.frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 60_000)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(upright.transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
        output.videoComposition = composition
        output.alwaysCopiesSampleData = true
        return output
    }
}
