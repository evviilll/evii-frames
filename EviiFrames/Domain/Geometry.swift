import Foundation

enum Geometry {
    /// Height × width. Both axes are multiples of 64. That covers scale 32
    /// (4.25 lite) and scale 16 (4.25 / 4.26), and 2176×3840 holds a 4K frame.
    static let buckets: [(h: Int, w: Int)] = [
        (256, 384), (384, 256),
        (384, 640), (640, 384),
        (512, 896), (896, 512),
        (768, 1280), (1280, 768),
        (1088, 1920), (1920, 1088),
        (2176, 3840), (3840, 2176),
    ]

    static func pad(_ value: Int, multiple: Int) -> Int {
        let m = max(1, multiple)
        let remainder = value % m
        if remainder == 0 { return max(value, m) }
        return value + (m - remainder)
    }

    static func even(_ value: Int) -> Int {
        let v = max(2, value)
        return v - (v % 2)
    }

    static func fit(width: Int, height: Int, limit: (Int, Int)?) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        guard let limit else { return (even(width), even(height)) }
        let long = max(limit.0, limit.1)
        let short = min(limit.0, limit.1)
        let wLimit = width >= height ? long : short
        let hLimit = width >= height ? short : long
        let scale = min(1.0, Double(wLimit) / Double(width), Double(hLimit) / Double(height))
        let w = even(Int((Double(width) * scale).rounded(.towardZero)))
        let h = even(Int((Double(height) * scale).rounded(.towardZero)))
        return (max(2, w), max(2, h))
    }

    /// Smallest bucket that contains the frame. If none does, the bucket that
    /// needs the least downscale. `scale` is how the source is resized into it.
    static func bucket(width: Int, height: Int) -> (h: Int, w: Int, scale: Double) {
        let fits = buckets.filter { $0.h >= height && $0.w >= width }
        if let best = fits.min(by: { ($0.h * $0.w) < ($1.h * $1.w) }) {
            return (best.h, best.w, 1)
        }
        var chosen = (h: buckets[0].h, w: buckets[0].w, scale: 0.0)
        for item in buckets {
            let scale = min(Double(item.w) / Double(max(width, 1)), Double(item.h) / Double(max(height, 1)))
            if scale > chosen.scale {
                chosen = (item.h, item.w, scale)
            }
        }
        return chosen
    }
}
