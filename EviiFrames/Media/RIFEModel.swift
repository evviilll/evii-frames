import CoreML
import CoreVideo
import Foundation

struct BundledRIFE: Equatable {
    var url: URL
    var h: Int
    var w: Int
    var prefix: String
}

/// RIFE 4.25 Core ML wrapper. Each package is traced at one HxW, a multiple of 64.
/// Smaller frames are edge-padded into that canvas and cropped back out.
final class RIFEModel {
    let height: Int
    let width: Int
    let computeLabel: String
    let packageName: String
    /// Identity plus horizontal, vertical, and both flips. About four times the work.
    var augment = false
    private let model: MLModel
    private let frame0: MLMultiArray
    private let frame1: MLMultiArray
    private let timestep: MLMultiArray

    /// Longer prefixes first so `RIFE425L` is not read as `RIFE425`.
    static let packagePrefixes = ["RIFE426H", "RIFE425L", "RIFE425", "RIFE426", "RIFE422"]

    static func parsePackageName(_ name: String) -> (prefix: String, h: Int, w: Int)? {
        guard let prefix = packagePrefixes.first(where: { name.hasPrefix($0 + "_") }) else { return nil }
        let size = name.dropFirst(prefix.count + 1)
        let parts = size.split(separator: "x")
        guard parts.count == 2, let h = Int(parts[0]), let w = Int(parts[1]) else { return nil }
        return (prefix, h, w)
    }

    static func bundledModels(prefix: String? = nil) -> [BundledRIFE] {
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
            guard let parsed = parsePackageName(name) else { continue }
            if let prefix, parsed.prefix != prefix { continue }
            if found.contains(where: { $0.prefix == parsed.prefix && $0.h == parsed.h && $0.w == parsed.w }) { continue }
            found.append(BundledRIFE(url: url, h: parsed.h, w: parsed.w, prefix: parsed.prefix))
        }
        return found
    }

    static func loadBest(prefix: String, containing width: Int, height: Int) throws -> RIFEModel {
        let models = bundledModels(prefix: prefix)
        guard !models.isEmpty else {
            throw PipelineError.modelMissing("\(prefix)_\(height)x\(width).mlmodelc")
        }
        let fits = models.filter { $0.h >= height && $0.w >= width }
        let choice: BundledRIFE
        if let best = fits.min(by: { ($0.h * $0.w) < ($1.h * $1.w) }) {
            choice = best
        } else {
            choice = models.max { scale($0, width: width, height: height) < scale($1, width: width, height: height) }!
        }
        return try RIFEModel(url: choice.url, height: choice.h, width: choice.w)
    }

    static func loadBest(containing width: Int, height: Int) throws -> RIFEModel {
        try loadBest(prefix: "RIFE425", containing: width, height: height)
    }

    private static func scale(_ model: BundledRIFE, width: Int, height: Int) -> Double {
        min(Double(model.w) / Double(max(width, 1)), Double(model.h) / Double(max(height, 1)))
    }

    init(url: URL, height: Int, width: Int) throws {
        self.height = height
        self.width = width
        // A16, 6 GB. Convolutions are FP16. The warp and the bilinear resize are
        // FP32 resamples. Neural Engine, then GPU, then .all, then CPU.
        let units: [MLComputeUnits] = [.cpuAndNeuralEngine, .cpuAndGPU, .all, .cpuOnly]
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
        packageName = url.deletingPathExtension().lastPathComponent
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
        self.timestep.dataPointer.assumingMemoryBound(to: Float.self)[0] = timestep
        if !augment {
            let output = try predict(frame0: frame0, frame1: frame1, flipH: false, flipV: false)
            guard let buffer = read(output, width: contentW, height: contentH) else {
                throw PipelineError.modelFailed("Не вдалося зібрати кадр")
            }
            return buffer
        }
        // One model stays resident. The four passes are sequential.
        let passes = [(false, false), (true, false), (false, true), (true, true)]
        var sum = [Float](repeating: 0, count: contentW * contentH * 3)
        for (flipH, flipV) in passes {
            let output = try predict(frame0: frame0, frame1: frame1, flipH: flipH, flipV: flipV)
            sum.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                contribute(output, into: base, contentW: contentW, contentH: contentH, flipH: flipH, flipV: flipV)
            }
        }
        let count = Float(passes.count)
        for index in sum.indices { sum[index] /= count }
        guard let buffer = PixelBuffers.make(width: contentW, height: contentH) else {
            throw PipelineError.modelFailed("Не вдалося зібрати кадр")
        }
        writeAverage(sum, into: buffer, contentW: contentW, contentH: contentH)
        return buffer
    }

    private func predict(frame0: CVPixelBuffer, frame1: CVPixelBuffer, flipH: Bool, flipV: Bool) throws -> MLMultiArray {
        write(frame0, into: self.frame0, flipH: flipH, flipV: flipV)
        write(frame1, into: self.frame1, flipH: flipH, flipV: flipV)
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
        return output
    }

    private func write(_ buffer: CVPixelBuffer, into array: MLMultiArray, flipH: Bool = false, flipV: Bool = false) {
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
            let sourceY = flipV ? (sh - 1 - sy) : sy
            for x in 0..<width {
                let sx = min(x, max(0, sw - 1))
                let sourceX = flipH ? (sw - 1 - sx) : sx
                let pixel = bytes.advanced(by: sourceY * rowBytes + sourceX * 4)
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

    private func contribute(
        _ array: MLMultiArray,
        into sum: UnsafeMutablePointer<Float>,
        contentW: Int,
        contentH: Int,
        flipH: Bool,
        flipV: Bool
    ) {
        let strides = array.strides.map(\.intValue)
        let plane = strides.count > 1 ? strides[1] : height * width
        let rowStride = strides.count > 2 ? strides[2] : width
        let colStride = strides.count > 3 ? strides[3] : 1
        let src = array.dataPointer.assumingMemoryBound(to: Float.self)
        let area = contentW * contentH
        for y in 0..<contentH {
            let my = flipV ? (contentH - 1 - y) : y
            for x in 0..<contentW {
                let mx = flipH ? (contentW - 1 - x) : x
                let offset = my * rowStride + mx * colStride
                let dest = y * contentW + x
                sum[dest] += src[offset]
                sum[area + dest] += src[plane + offset]
                sum[area * 2 + dest] += src[plane * 2 + offset]
            }
        }
    }

    private func writeAverage(_ sum: [Float], into buffer: CVPixelBuffer, contentW: Int, contentH: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let area = contentW * contentH
        for y in 0..<contentH {
            let row = bytes.advanced(by: y * rowBytes)
            for x in 0..<contentW {
                let dest = y * contentW + x
                let r = min(max(sum[dest], 0), 1)
                let g = min(max(sum[area + dest], 0), 1)
                let b = min(max(sum[area * 2 + dest], 0), 1)
                let pixel = row.advanced(by: x * 4)
                pixel[0] = UInt8(max(0, min(255, Int((b * 255).rounded()))))
                pixel[1] = UInt8(max(0, min(255, Int((g * 255).rounded()))))
                pixel[2] = UInt8(max(0, min(255, Int((r * 255).rounded()))))
                pixel[3] = 255
            }
        }
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
