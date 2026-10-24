import Foundation

struct DiffStats: Equatable {
    var mean: Float
    var maxCell: Float

    static func make(_ a: [Float], _ b: [Float]) -> DiffStats {
        let n = min(a.count, b.count)
        guard n > 0 else { return DiffStats(mean: 0, maxCell: 0) }
        var sum: Float = 0
        var peak: Float = 0
        for i in 0..<n {
            let d = abs(a[i] - b[i])
            sum += d
            if d > peak { peak = d }
        }
        return DiffStats(mean: sum / Float(n), maxCell: peak)
    }
}

enum SceneDetector {
    /// Higher sensitivity lowers the cut threshold.
    /// 0 → 0.50 (only a hard cut), 0.40 → 0.332, 1 → 0.08.
    static func threshold(sensitivity: Double) -> Float {
        let s = min(1, max(0, sensitivity))
        return Float(0.50 - 0.42 * s)
    }

    static func isCut(_ a: [Float], _ b: [Float], sensitivity: Double) -> Bool {
        DiffStats.make(a, b).mean >= threshold(sensitivity: sensitivity)
    }

    /// Indices of the frame *after* the cut.
    static func cutIndices(signatures: [[Float]], sensitivity: Double) -> [Int] {
        guard signatures.count >= 2 else { return [] }
        let limit = threshold(sensitivity: sensitivity)
        var cuts: [Int] = []
        for index in 1..<signatures.count {
            if DiffStats.make(signatures[index - 1], signatures[index]).mean >= limit {
                cuts.append(index)
            }
        }
        return cuts
    }
}

enum Dedup {
    /// Fast mode uses the mean of a coarse grid. Accurate mode also rejects a pair
    /// when any cell jumps, so a small local change survives.
    static func isDuplicate(_ stats: DiffStats, thresholdPercent: Double, mode: DedupMode) -> Bool {
        guard mode != .off else { return false }
        let threshold = Float(min(100, max(0, thresholdPercent)) / 100)
        guard stats.mean < threshold else { return false }
        if mode == .accurate, stats.maxCell > threshold * 5 {
            return false
        }
        return true
    }

    static func duplicateIndices(
        signatures: [[Float]],
        mode: DedupMode,
        thresholdPercent: Double
    ) -> [Int] {
        guard mode != .off, signatures.count >= 2 else { return [] }
        var found: [Int] = []
        for index in 1..<signatures.count {
            let stats = DiffStats.make(signatures[index - 1], signatures[index])
            if isDuplicate(stats, thresholdPercent: thresholdPercent, mode: mode) {
                found.append(index)
            }
        }
        return found
    }
}

enum LumaGrid {
    /// Box-filters a luma plane (0...255) into a `grid × grid` map of 0...1.
    static func fromLuma(_ bytes: [UInt8], width: Int, height: Int, grid: Int) -> [Float] {
        guard width > 0, height > 0, grid > 0, bytes.count >= width * height else {
            return [Float](repeating: 0, count: max(1, grid * grid))
        }
        var out = [Float](repeating: 0, count: grid * grid)
        for gy in 0..<grid {
            let y0 = gy * height / grid
            let y1 = max(y0 + 1, (gy + 1) * height / grid)
            for gx in 0..<grid {
                let x0 = gx * width / grid
                let x1 = max(x0 + 1, (gx + 1) * width / grid)
                var sum = 0
                var count = 0
                var y = y0
                while y < y1 {
                    let row = y * width
                    var x = x0
                    while x < x1 {
                        sum += Int(bytes[row + x])
                        count += 1
                        x += 1
                    }
                    y += 1
                }
                out[gy * grid + gx] = count == 0 ? 0 : Float(sum) / Float(count * 255)
            }
        }
        return out
    }

    /// Averages a square grid down to a coarser square grid.
    static func pool(_ values: [Float], from fine: Int, to coarse: Int) -> [Float] {
        guard fine >= coarse, coarse > 0, values.count >= fine * fine else { return values }
        var out = [Float](repeating: 0, count: coarse * coarse)
        for gy in 0..<coarse {
            let y0 = gy * fine / coarse
            let y1 = max(y0 + 1, (gy + 1) * fine / coarse)
            for gx in 0..<coarse {
                let x0 = gx * fine / coarse
                let x1 = max(x0 + 1, (gx + 1) * fine / coarse)
                var sum: Float = 0
                var count = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        sum += values[y * fine + x]
                        count += 1
                    }
                }
                out[gy * coarse + gx] = count == 0 ? 0 : sum / Float(count)
            }
        }
        return out
    }
}
