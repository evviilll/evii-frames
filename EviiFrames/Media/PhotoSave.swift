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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evii-prores-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        return writer.canAdd(input)
    }
}
