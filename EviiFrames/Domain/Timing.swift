import Foundation

/// Time mapping for slow motion. `fragment == nil` slows the whole clip.
struct SlowMoMap: Equatable {
    var clipDuration: Double
    var fragment: ClosedRange<Double>?
    var factor: Double

    var outputDuration: Double {
        let f = max(factor, 1)
        if let fragment {
            let a = min(max(0, fragment.lowerBound), clipDuration)
            let b = min(max(a, fragment.upperBound), clipDuration)
            return a + (b - a) * f + (clipDuration - b)
        }
        return clipDuration * f
    }

    func sourceTime(at outputTime: Double) -> Double {
        let total = outputDuration
        let t = min(max(0, outputTime), total)
        let f = max(factor, 1)
        guard let fragment else { return t / f }
        let a = min(max(0, fragment.lowerBound), clipDuration)
        let b = min(max(a, fragment.upperBound), clipDuration)
        let slowOut = (b - a) * f
        if t <= a { return t }
        if t <= a + slowOut { return a + (t - a) / f }
        return b + (t - (a + slowOut))
    }

    func isSlowed(sourceTime: Double) -> Bool {
        guard factor > 1.001 else { return false }
        guard let fragment else { return true }
        return fragment.contains(sourceTime)
    }
}

enum Timing {
    static let clipLimit = 30.0

    static func outputFPS(sourceFPS: Double, multiplier: Int) -> Double {
        sourceFPS * Double(max(1, multiplier))
    }

    /// Frames produced between the first and last source frame, inclusive.
    /// Looping also fills the gap from the last frame back to the first, so the
    /// count is `sourceFrames * multiplier` instead of `(n - 1) * multiplier + 1`.
    static func interpolatedFrameCount(sourceFrames: Int, multiplier: Int, loop: Bool) -> Int {
        let n = max(0, sourceFrames)
        let m = max(1, multiplier)
        guard n >= 2 else { return max(n, 0) }
        if loop { return n * m }
        return (n - 1) * m + 1
    }

    static func interpolationOutputFPS(
        sourceFPS: Double,
        multiplier: Int,
        targetFPS: Double?,
        maxFPS: Double?
    ) -> Double {
        let ideal = targetFPS ?? (sourceFPS * Double(max(1, multiplier)))
        if let maxFPS, ideal > maxFPS + 0.0001 { return maxFPS }
        return ideal
    }

    static func interpolationFrameCount(
        sourceFrames: Int,
        sourceFPS: Double,
        outputFPS: Double,
        loop: Bool
    ) -> Int {
        let n = sourceFrames
        guard n >= 2, sourceFPS > 0, outputFPS > 0 else { return max(n, 1) }
        if loop {
            let duration = Double(n) / sourceFPS
            let exact = outputFPS / sourceFPS
            let nearest = exact.rounded()
            if abs(exact - nearest) < 0.001, nearest >= 1 {
                return n * Int(nearest)
            }
            return max(n, Int((duration * outputFPS).rounded()))
        }
        let exact = outputFPS / sourceFPS
        let nearest = exact.rounded()
        if abs(exact - nearest) < 0.001, nearest >= 1 {
            return (n - 1) * Int(nearest) + 1
        }
        let span = Double(n - 1) / sourceFPS
        return max(2, Int((span * outputFPS).rounded()) + 1)
    }

    static func slowMoDuration(clip: Double, fragment: ClosedRange<Double>?, factor: Int) -> Double {
        SlowMoMap(clipDuration: clip, fragment: fragment, factor: Double(max(1, factor))).outputDuration
    }

    static func slowMoFrameCount(outputDuration: Double, fps: Double) -> Int {
        guard fps > 0 else { return 1 }
        return max(1, Int((outputDuration * fps).rounded()))
    }

    /// Rough on-device range. 1080p is assumed at about 3–6 generated frames/sec.
    /// This is an estimate, not a measurement.
    static func runtimeHint(sourceFrames: Int, outputFrames: Int, width: Int, height: Int) -> (low: Int, high: Int) {
        let generated = max(1, outputFrames - max(0, sourceFrames))
        let scale = max(0.25, Double(width * height) / (1920.0 * 1080.0))
        let fast = Int(ceil(Double(generated) / 6.0 * scale))
        let slow = Int(ceil(Double(generated) / 3.0 * scale))
        let low = max(1, min(fast, slow))
        let high = max(low, max(fast, slow))
        if high < 15 { return (low, high) }
        let lo = max(10, (low / 10) * 10)
        let hi = max(lo + 10, Int((Double(high) / 10.0).rounded()) * 10)
        return (lo, hi)
    }

    static func formatRuntime(low: Int, high: Int) -> String {
        if high >= 90 {
            return "≈ \(formatMinutes(low))–\(formatMinutes(high))"
        }
        return "≈ \(low)–\(high) с"
    }

    private static func formatMinutes(_ seconds: Int) -> String {
        let m = max(1, Int((Double(seconds) / 60.0).rounded()))
        return "\(m) хв"
    }

    /// Bytes ≈ pixels × (frames − 1) × bits-per-pixel / 8.
    /// HEVC at quality 75 is tuned so 1920×1080 × 237 frames lands near 18 MB.
    static func estimatedBytes(
        width: Int,
        height: Int,
        frames: Int,
        quality: Double,
        codec: CodecChoice
    ) -> Int64 {
        let q = min(100, max(0, quality)) / 100
        let hevc = 0.07 + 0.299 * q
        let bpp: Double
        switch codec {
        case .hevc: bpp = hevc
        case .h264: bpp = hevc * 1.7
        case .prores: bpp = 1.2
        }
        let span = Double(max(1, frames - 1))
        let bytes = Double(max(1, width) * max(1, height)) * span * bpp / 8.0
        return Int64(bytes.rounded())
    }
}

enum Format {
    static func clock(_ seconds: Double, decimals: Int = 2) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        let rem = s - Double(minutes * 60)
        return String(format: "%d:%0\(2 + 1 + decimals).\(decimals)f", minutes, rem)
    }

    static func approxClock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        let rem = s - Double(minutes * 60)
        return String(format: "≈ %d:%04.1f", minutes, rem)
    }

    static func fps(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.015 {
            return String(format: "%.0f fps", rounded)
        }
        return String(format: "%.2f fps", value)
    }

    static func fpsNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.015 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.2f", value)
    }

    static func megabytes(_ bytes: Int64, approximate: Bool = false) -> String {
        let mb = Double(bytes) / 1_000_000
        let text: String
        if mb >= 10 || abs(mb.rounded() - mb) < 0.05 {
            text = String(format: "%.0f МБ", mb.rounded())
        } else {
            text = String(format: "%.1f МБ", mb)
        }
        return approximate ? "≈ \(text)" : text
    }

    static func resolution(_ width: Int, _ height: Int) -> String {
        "\(width)×\(height)"
    }
}

enum FilenamePattern {
    static func render(pattern: String, name: String, fps: Double, factor: Int) -> String {
        let cleaned = name.replacingOccurrences(
            of: #"[\\/:*?"<>|]+"#,
            with: "",
            options: .regularExpression
        )
        let base = cleaned.isEmpty ? "clip" : cleaned
        let fpsText: String
        let nearest = fps.rounded()
        if abs(fps - nearest) < 0.15 {
            fpsText = String(Int(nearest))
        } else {
            fpsText = String(format: "%.2f", fps)
        }
        var result = pattern
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{fps}", with: fpsText)
            .replacingOccurrences(of: "{factor}", with: "\(factor)")
        result = result.replacingOccurrences(
            of: #"[\\/:*?"<>|]+"#,
            with: "",
            options: .regularExpression
        )
        if result.count > 80 { result = String(result.prefix(80)) }
        return result.isEmpty ? base : result
    }
}
