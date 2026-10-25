import CoreML
import CoreVideo
import Foundation

struct BundledRIFE: Equatable {
    var url: URL
    var h: Int
    var w: Int
}

/// RIFE 4.25 Core ML wrapper. Each package is traced at one HxW, a multiple of 64.
/// Smaller frames are edge-padded into that canvas and cropped back out.
final class RIFEModel {
    let height: Int
    let width: Int
    let computeLabel: String
    private let model: MLModel
    private let frame0: MLMultiArray
    private let frame1: MLMultiArray
    private let timestep: MLMultiArray

    static func bundledModels() -> [BundledRIFE] {
        let bundle = Bundle(for: BundleMarker.self)
        guard let enumerator = FileManager.default.enumerator(
            at: bundle.bundleURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var found: [BundledRIFE] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension
            guard ext == "mlmodelc" || ext == "mlpackage" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("RIFE425_") else { continue }
            let size = name.dropFirst("RIFE425_".count)
            let parts = size.split(separator: "x")
            guard parts.count == 2, let h = Int(parts[0]), let w = Int(parts[1]) else { continue }
            if found.contains(where: { $0.h == h && $0.w == w }) { continue }
            found.append(BundledRIFE(url: url, h: h, w: w))
        }
        return found
    }

    static func loadBest(containing width: Int, height: Int) throws -> RIFEModel {
        let models = bundledModels()
        guard !models.isEmpty else {
            throw PipelineError.modelMissing("RIFE425_\(height)x\(width).mlmodelc")
        }
        let fits = models.filter { $0.h >= height && $0.w >= width }
        let choice = fits.min { ($0.h * $0.w) < ($1.h * $1.w) }
            ?? models.max { ($0.h * $0.w) < ($1.h * $1.w) }!
        return try RIFEModel(url: choice.url, height: choice.h, width: choice.w)
    }

    init(url: URL, height: Int, width: Int) throws {
        self.height = height
        self.width = width
        // A16 Neural Engine, 6 GB. Prefer the ANE without also reserving the GPU.
        // `.all` is the fallback when an op (grid_sample) is rejected by the ANE.
        let units: [MLComputeUnits] = [.cpuAndNeuralEngine, .all, .cpuAndGPU, .cpuOnly]
        var last: Error = PipelineError.modelMissing(url.lastPathComponent)
        var loaded: (MLModel, String)?
        for unit in units {
            let config = MLModelConfiguration()
            config.computeUnits = unit
            config.allowLowPrecisionAccumulationOnGPU = true
            do {
                let model = try MLModel(contentsOf: url, configuration: config)
                loaded = (model, label(unit))
                break
            } catch {
                last = error
            }
        }
        guard let loaded else { throw last }
        model = loaded.0
        computeLabel = loaded.1
        frame0 = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        frame1 = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        timestep = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .float32)
    }

    func interpolate(frame0: CVPixelBuffer, frame1: CVPixelBuffer, timestep: Float) throws -> CVPixelBuffer {
        let contentW = CVPixelBufferGetWidth(frame0)
        let contentH = CVPixelBufferGetHeight(frame0)
        guard contentW == CVPixelBufferGetWidth(frame1), contentH == CVPixelBufferGetHeight(frame1) else {
            throw PipelineError.writer("Кадри різного розміру")
        }
        guard contentW <= width, contentH <= height else {
            throw PipelineError.writer("Кадр \(contentW)×\(contentH) більший за модель \(width)×\(height)")
        }
        write(frame0, into: self.frame0)
        write(frame1, into: self.frame1)
        self.timestep.dataPointer.assumingMemoryBound(to: Float.self)[0] = timestep
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "frame0": MLFeatureValue(multiArray: self.frame0),
            "frame1": MLFeatureValue(multiArray: self.frame1),
            "timestep": MLFeatureValue(multiArray: self.timestep),
        ])
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            throw PipelineError.modelFailed(error.localizedDescription)
        }
        guard let output = result.featureValue(for: "output")?.multiArrayValue else {
            throw PipelineError.modelFailed("Модель не повернула кадр")
        }
        guard let buffer = read(output, width: contentW, height: contentH) else {
            throw PipelineError.modelFailed("Не вдалося зібрати кадр")
        }
        return buffer
    }

    private func write(_ buffer: CVPixelBuffer, into array: MLMultiArray) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let sw = CVPixelBufferGetWidth(buffer)
        let sh = CVPixelBufferGetHeight(buffer)
        let strides = array.strides.map(\.intValue)
        let plane = strides.count > 1 ? strides[1] : height * width
        let rowStride = strides.count > 2 ? strides[2] : width
        let colStride = strides.count > 3 ? strides[3] : 1
        let dest = array.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<height {
            let sy = min(y, max(0, sh - 1))
            for x in 0..<width {
                let sx = min(x, max(0, sw - 1))
                let pixel = bytes.advanced(by: sy * rowBytes + sx * 4)
                let offset = y * rowStride + x * colStride
                dest[offset] = Float(pixel[2]) / 255
                dest[plane + offset] = Float(pixel[1]) / 255
                dest[plane * 2 + offset] = Float(pixel[0]) / 255
            }
        }
    }

    private func read(_ array: MLMultiArray, width: Int, height: Int) -> CVPixelBuffer? {
        guard let buffer = PixelBuffers.make(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let strides = array.strides.map(\.intValue)
        let plane = strides.count > 1 ? strides[1] : self.height * self.width
        let rowStride = strides.count > 2 ? strides[2] : self.width
        let colStride = strides.count > 3 ? strides[3] : 1
        let src = array.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<height {
            let row = bytes.advanced(by: y * rowBytes)
            for x in 0..<width {
                let offset = y * rowStride + x * colStride
                let r = min(max(src[offset], 0), 1)
                let g = min(max(src[plane + offset], 0), 1)
                let b = min(max(src[plane * 2 + offset], 0), 1)
                let pixel = row.advanced(by: x * 4)
                pixel[0] = UInt8(max(0, min(255, Int((b * 255).rounded()))))
                pixel[1] = UInt8(max(0, min(255, Int((g * 255).rounded()))))
                pixel[2] = UInt8(max(0, min(255, Int((r * 255).rounded()))))
                pixel[3] = 255
            }
        }
        return buffer
    }
}

private func label(_ unit: MLComputeUnits) -> String {
    switch unit {
    case .all: return "all"
    case .cpuAndGPU: return "cpuAndGPU"
    case .cpuOnly: return "cpuOnly"
    case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
    @unknown default: return "unknown"
    }
}

enum PipelineError: LocalizedError {
    case noVideo
    case modelMissing(String)
    case modelFailed(String)
    case writer(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideo:
            return "У файлі немає відеодоріжки."
        case .modelMissing(let name):
            return "Немає моделі \(name). Зберіть її скриптом tools/convert_rife425.py і перезберіть застосунок."
        case .modelFailed(let reason):
            return "RIFE зупинився: \(reason)"
        case .writer(let reason):
            return "Не вдалося закодувати відео. \(reason)"
        case .cancelled:
            return "Скасовано."
        }
    }
}
