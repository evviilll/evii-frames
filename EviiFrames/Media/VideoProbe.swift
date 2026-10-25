import AVFoundation
import CoreMedia
import CoreTransferable
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
        async let minFrame = track.load(.minFrameDuration)
        async let assetDuration = asset.load(.duration)
        async let descriptions = track.load(.formatDescriptions)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        async let metadata = asset.load(.metadata)

        let transformed = CGRect(origin: .zero, size: try await naturalSize).applying(try await transform)
        let rawWidth = max(1, Int(abs(transformed.width).rounded()))
        let rawHeight = max(1, Int(abs(transformed.height).rounded()))
        let pixels = normalizedPixels(width: rawWidth, height: rawHeight)
        let rawFPS = Double(try await nominal)
        let variable = isVariableFrameRate(nominalFPS: rawFPS, minFrameDuration: try await minFrame)
        var fps = rawFPS
        if fps < 1 { fps = 30 }
        let duration = max(0, try await assetDuration.seconds)
        let frames = max(1, Int((duration * fps).rounded()))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let description = try await descriptions.first
        let codec = codecLabel(description)
        let range = description.map(dynamicRange(of:)) ?? .sdr
        let meta = try await readMetadata(try await metadata)
        let filename = url.deletingPathExtension().lastPathComponent
        return VideoInfo(
            filename: filename.isEmpty ? "Відео" : filename,
            width: pixels.width,
            height: pixels.height,
            fps: fps,
            duration: duration,
            frameCount: frames,
            fileSize: size,
            hasAudio: !(try await audioTracks).isEmpty,
            codecLabel: codec,
            creationDate: meta.date,
            latitude: meta.lat,
            longitude: meta.lon,
            dynamicRange: range,
            variableFrameRate: variable,
            dimensionsAdjusted: pixels.adjusted
        )
    }

    static func importNotes(_ info: VideoInfo) -> [String] {
        var notes: [String] = []
        if info.duration > Timing.clipLimit + 0.05 {
            notes.append("Кліп довший за 30 с — взято перші 30 с.")
        }
        switch info.dynamicRange {
        case .sdr:
            break
        case .hdr:
            notes.append("HDR буде зведено до SDR.")
        case .dolbyVision:
            notes.append("Dolby Vision буде зведено до SDR.")
        }
        if info.variableFrameRate {
            notes.append("Змінна частота кадрів буде вирівняна до \(Format.fps(info.fps)).")
        }
        if info.dimensionsAdjusted {
            notes.append("Непарний або дуже малий розмір вирівняно до парних пікселів.")
        }
        return notes
    }

    /// Even dimensions only. A side under 64 px is still encoded, and `adjusted` asks the UI to say so.
    static func normalizedPixels(width: Int, height: Int) -> (width: Int, height: Int, adjusted: Bool) {
        let rawW = max(1, width)
        let rawH = max(1, height)
        let evenW = Geometry.even(rawW)
        let evenH = Geometry.even(rawH)
        let odd = rawW % 2 != 0 || rawH % 2 != 0
        let tiny = evenW < 64 || evenH < 64
        return (evenW, evenH, odd || tiny || evenW != rawW || evenH != rawH)
    }

    /// Peak frame rate more than 35% above nominal means the file is not a steady timeline.
    static func isVariableFrameRate(nominalFPS: Double, minFrameDuration: CMTime) -> Bool {
        guard nominalFPS > 1, minFrameDuration.isNumeric, minFrameDuration.seconds > 0.00001 else { return false }
        return (1.0 / minFrameDuration.seconds) > nominalFPS * 1.35
    }

    static func dynamicRange(fourcc: String, transfer: String?, atomKeys: [String]) -> DynamicRangeKind {
        let dolby: Set<String> = ["dvh1", "dvhe", "dav1", "dvav", "dva1"]
        if dolby.contains(fourcc.lowercased()) || atomKeys.contains(where: { ["dvvC", "dvcC", "dvwC"].contains($0) }) {
            return .dolbyVision
        }
        if let transfer {
            let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
            let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            let folded = transfer.lowercased()
            if transfer == pq || transfer == hlg || folded.contains("2084") || folded.contains("2100") || folded.contains("hlg") || folded.contains("pq") {
                return .hdr
            }
        }
        return .sdr
    }

    private static func dynamicRange(of description: CMFormatDescription) -> DynamicRangeKind {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction).flatMap { value -> String? in
            if let text = value as? String { return text }
            if let text = value as? NSString { return text as String }
            return nil
        }
        var atoms: [String] = []
        if let box = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary {
            atoms = box.allKeys.compactMap { $0 as? String }
        }
        return dynamicRange(fourcc: fourcc(subtype), transfer: transfer, atomKeys: atoms)
    }

    /// A JPEG poster for the clip. AVAssetImageGenerator decodes on its own queue; callers
    /// run this from a detached task so the main thread never waits on it.
    static func posterJPEG(_ url: URL, at seconds: Double = 0.1) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var times = [CMTime(seconds: max(0, seconds) + 0.05, preferredTimescale: 600), .zero]
        if seconds > 0.2 { times.insert(CMTime(seconds: seconds, preferredTimescale: 600), at: 1) }
        for time in times {
            if let cg = try? await generator.image(at: time).image {
                return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
            }
        }
        return nil
    }

    private static func fourcc(_ subtype: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xff),
            UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff),
            UInt8(subtype & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "Відео"
    }

    private static func codecLabel(_ description: CMFormatDescription?) -> String {
        guard let description else { return "Відео" }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        switch subtype {
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AppleProRes422: return "ProRes"
        default:
            let text = fourcc(subtype)
            if text.lowercased().hasPrefix("ap") { return "ProRes" }
            if dynamicRange(fourcc: text, transfer: nil, atomKeys: []) == .dolbyVision { return "Dolby Vision" }
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
