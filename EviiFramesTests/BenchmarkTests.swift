import CoreML
import CoreVideo
import XCTest
@testable import EviiFrames

final class BenchmarkTests: XCTestCase {
    func testRIFEBenchmarkWhenModelIsBundled() throws {
        let models = RIFEModel.bundledModels()
        guard !models.isEmpty else {
            print("EVII_BENCH {\"skipped\":true,\"reason\":\"model not in bundle\",\"device\":\"ios-simulator\",\"note\":\"not representative of iPhone\"}")
            throw XCTSkip("RIFE mlmodelc was not bundled. Run tools/convert_rife425.py before building.")
        }
        let smallest = models.min { ($0.h * $0.w) < ($1.h * $1.w) }!
        let model: RIFEModel
        do {
            model = try RIFEModel(url: smallest.url, height: smallest.h, width: smallest.w)
        } catch {
            print("EVII_BENCH {\"skipped\":false,\"error\":\"load: \(error)\",\"device\":\"ios-simulator\",\"note\":\"not representative of iPhone\"}")
            XCTFail("Failed to load \(smallest.url.lastPathComponent): \(error)")
            return
        }

        var frame0: CVPixelBuffer?
        var frame1: CVPixelBuffer?
        CVPixelBufferCreate(nil, smallest.w, smallest.h, kCVPixelFormatType_32BGRA, nil, &frame0)
        CVPixelBufferCreate(nil, smallest.w, smallest.h, kCVPixelFormatType_32BGRA, nil, &frame1)
        guard let frame0, let frame1 else {
            XCTFail("pixel buffer")
            return
        }
        fill(frame0, value: 40)
        fill(frame1, value: 180)

        do {
            _ = try model.interpolate(frame0: frame0, frame1: frame1, timestep: 0.5)
        } catch {
            print("EVII_BENCH {\"model\":\"\(smallest.url.lastPathComponent)\",\"error\":\"\(error)\",\"compute\":\"\(model.computeLabel)\",\"device\":\"ios-simulator\",\"note\":\"not representative of iPhone\"}")
            XCTFail("Prediction failed: \(error)")
            return
        }

        let runs = 2
        let start = Date()
        for _ in 0..<runs {
            _ = try model.interpolate(frame0: frame0, frame1: frame1, timestep: 0.5)
        }
        let seconds = Date().timeIntervalSince(start) / Double(runs)
        let payload = String(
            format: "EVII_BENCH {\"model\":\"%@\",\"height\":%d,\"width\":%d,\"seconds_per_frame\":%.4f,\"runs\":%d,\"compute\":\"%@\",\"device\":\"ios-simulator\",\"note\":\"not representative of iPhone\"}",
            smallest.url.deletingPathExtension().lastPathComponent,
            smallest.h,
            smallest.w,
            seconds,
            runs,
            model.computeLabel
        )
        print(payload)
        XCTAssertGreaterThan(seconds, 0)
    }

    private func fill(_ buffer: CVPixelBuffer, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, Int32(value), height * row)
    }
}
