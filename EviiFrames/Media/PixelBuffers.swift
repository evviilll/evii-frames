import Accelerate
import CoreVideo
import Foundation

enum PixelBuffers {
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    static func copy(_ source: CVPixelBuffer, into destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let dstRow = CVPixelBufferGetBytesPerRow(destination)
        let bytes = min(srcRow, dstRow)
        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(destination) else { return }
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * dstRow), srcBase.advanced(by: row * srcRow), bytes)
        }
    }

    static func scale(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(source)
        let sh = CVPixelBufferGetHeight(source)
        guard let destination = make(width: width, height: height) else { return nil }
        if sw == width && sh == height {
            copy(source, into: destination)
            return destination
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let srcData = CVPixelBufferGetBaseAddress(source),
              let dstData = CVPixelBufferGetBaseAddress(destination) else { return nil }
        var src = vImage_Buffer(
            data: srcData,
            height: vImagePixelCount(sh),
            width: vImagePixelCount(sw),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var dst = vImage_Buffer(
            data: dstData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destination)
        )
        let error = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else { return nil }
        return destination
    }

    /// Rec. 709 luma sampled on a coarse grid. Values are 0...255.
    static func luma(_ source: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(source) else {
            return [UInt8](repeating: 0, count: width * height)
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(source)
        let sw = max(1, CVPixelBufferGetWidth(source))
        let sh = max(1, CVPixelBufferGetHeight(source))
        var plane = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(sh - 1, y * sh / height)
            for x in 0..<width {
                let sx = min(sw - 1, x * sw / width)
                let pixel = bytes.advanced(by: sy * rowBytes + sx * 4)
                let b = Float(pixel[0])
                let g = Float(pixel[1])
                let r = Float(pixel[2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                plane[y * width + x] = UInt8(max(0, min(255, Int(luma.rounded()))))
            }
        }
        return plane
    }
}

final class BundleMarker {}
