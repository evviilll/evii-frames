import AVFoundation
import CoreMedia
import Foundation
import UIKit
import UniformTypeIdentifiers

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("evii-in-\(UUID().uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}

enum VideoProbe {
    static func probe(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw PipelineError.noVideo }
        async let naturalSize = track.load(.naturalSize)
        async let transform = track.load(.preferredTransform)
        async let nominal = track.load(.nominalFrameRate)
        async let assetDuration = asset.load(.duration)
        async let descriptions = track.load(.formatDescriptions)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        async let metadata = asset.load(.metadata)

        let transformed = CGRect(origin: .zero, size: try await naturalSize).applying(try await transform)
        let width = max(2, Int(abs(transformed.width).rounded()))
        let height = max(2, Int(abs(transformed.height).rounded()))
        var fps = Double(try await nominal)
        if fps < 1 { fps = 30 }
        let duration = max(0, try await assetDuration.seconds)
        let frames = max(1, Int((duration * fps).rounded()))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let codec = codecLabel(try await descriptions.first)
        let meta = try await readMetadata(try await metadata)
        let filename = url.deletingPathExtension().lastPathComponent
        return VideoInfo(
            filename: filename.isEmpty ? "Відео" : filename,
            width: width,
            height: height,
            fps: fps,
            duration: duration,
            frameCount: frames,
            fileSize: size,
            hasAudio: !(try await audioTracks).isEmpty,
            codecLabel: codec,
            creationDate: meta.date,
            latitude: meta.lat,
            longitude: meta.lon
        )
    }

    static func posterJPEG(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        let ui = UIImage(cgImage: cg)
        return ui.jpegData(compressionQuality: 0.8)
    }

    private static func codecLabel(_ description: CMFormatDescription?) -> String {
        guard let description else { return "Відео" }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        switch subtype {
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AppleProRes422: return "ProRes"
        default:
            let bytes: [UInt8] = [
                UInt8((subtype >> 24) & 0xff),
                UInt8((subtype >> 16) & 0xff),
                UInt8((subtype >> 8) & 0xff),
                UInt8(subtype & 0xff),
            ]
            let text = String(bytes: bytes, encoding: .ascii) ?? "Відео"
            if text.hasPrefix("ap") { return "ProRes" }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func readMetadata(_ items: [AVMetadataItem]) async throws -> (date: Date?, lat: Double?, lon: Double?) {
        var date: Date?
        var location: String?
        for item in items {
            guard let id = item.identifier else { continue }
            if id == .commonIdentifierCreationDate || id == .quickTimeMetadataCreationDate {
                if let value = try? await item.load(.stringValue) {
                    date = ISO8601DateFormatter().date(from: value) ?? date
                } else if let value = try? await item.load(.dateValue) {
                    date = value
                }
            }
            if id == .commonIdentifierLocation || id == .quickTimeMetadataLocationISO6709 {
                location = (try? await item.load(.stringValue)) ?? location
            }
        }
        let coords = location.flatMap(parseISO6709)
        return (date, coords?.0, coords?.1)
    }

    static func parseISO6709(_ text: String) -> (Double, Double)? {
        let pattern = #"([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let latRange = Range(match.range(at: 1), in: text),
              let lonRange = Range(match.range(at: 2), in: text),
              let lat = Double(text[latRange]),
              let lon = Double(text[lonRange]) else { return nil }
        return (lat, lon)
    }

    static func iso6709(latitude: Double, longitude: Double) -> String {
        String(format: "%+09.4f%+010.4f/", latitude, longitude)
    }
}
