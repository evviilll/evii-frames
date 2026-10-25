import AVFoundation
import CoreLocation
import Foundation
import Photos

enum PhotoSave {
    static func save(url: URL, date: Date?, latitude: Double?, longitude: Double?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PipelineError.writer("Немає доступу, щоб зберегти у Фото.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            request?.creationDate = date
            if let latitude, let longitude {
                request?.location = CLLocation(latitude: latitude, longitude: longitude)
            }
        }
    }
}

enum EncoderSupport {
    static func proResAvailable() -> Bool {
        canWrite(codec: .proRes422)
    }

    static func hevcAvailable() -> Bool {
        canWrite(codec: .hevc)
    }

    /// ProRes and HEVC are not on every simulator. Fall back instead of failing the export.
    static func resolved(_ codec: CodecChoice) -> (codec: CodecChoice, note: String?) {
        if codec == .prores && !proResAvailable() {
            let next: CodecChoice = hevcAvailable() ? .hevc : .h264
            return (next, "ProRes недоступний на цьому пристрої. Записую \(next.title).")
        }
        if codec == .hevc && !hevcAvailable() {
            return (.h264, "HEVC недоступний на цьому пристрої. Записую H.264.")
        }
        return (codec, nil)
    }

    private static func canWrite(codec: AVVideoCodecType) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evii-codec-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        return writer.canAdd(input)
    }
}
