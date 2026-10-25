import Foundation

extension ClipJob {
    func planRequest(frames: Int? = nil, cuts: Set<Int> = [], duplicates: Set<Int> = [], loopCut: Bool = false) -> PlanRequest {
        let count = max(1, frames ?? activeFrameCount)
        let duration = max(activeDuration, 0.001)
        let fps = info.fps > 0.5 ? info.fps : Double(max(count - 1, 1)) / duration
        var request = PlanRequest(
            sourceFrames: count,
            sourceFPS: fps,
            sourceDuration: duration,
            multiplier: max(2, interpolation.multiplier),
            targetFPS: interpolation.useTargetFPS ? interpolation.targetFPS : nil,
            maxFPS: export.maxFPS.fps,
            loop: mode == .interpolation && interpolation.loop,
            cuts: cuts,
            duplicates: duplicates,
            loopCut: loopCut,
            minimumDuration: export.minimumDuration
        )
        switch mode {
        case .interpolation:
            request.kind = .interpolation
        case .slowMo:
            let fragment: ClosedRange<Double>? = slow.wholeClip ? nil : slow.fragmentSeconds(duration: duration)
            request.kind = .slowMo(factor: max(2, slow.factor), fragment: fragment)
        }
        return request
    }

    func outputPixelSize() -> (width: Int, height: Int) {
        let fitted = Geometry.fit(width: info.width, height: info.height, limit: export.maxResolution.limit)
        let bucket = Geometry.bucket(width: fitted.width, height: fitted.height)
        if bucket.scale >= 0.999 { return fitted }
        let width = Geometry.even(Int((Double(fitted.width) * bucket.scale).rounded(.towardZero)))
        let height = Geometry.even(Int((Double(fitted.height) * bucket.scale).rounded(.towardZero)))
        return (max(2, width), max(2, height))
    }

    func limitCaption() -> String {
        let fps: String
        if export.maxFPS == .none {
            fps = "без ліміту fps"
        } else {
            fps = "ліміт \(export.maxFPS.title) fps"
        }
        let res = export.maxResolution == .original ? "ориг." : export.maxResolution.title
        return "\(fps) · \(res)"
    }

    var displayName: String {
        let raw = info.filename
        if raw.lowercased().hasSuffix(".mov") || raw.lowercased().hasSuffix(".mp4") {
            return raw
        }
        return raw
    }
}

enum Ukrainian {
    static func scenes(_ count: Int) -> String {
        "\(count) \(plural(count, one: "зміна", few: "зміни", many: "змін")) сцени"
    }

    static func duplicates(_ count: Int) -> String {
        "\(count) \(plural(count, one: "дублікат", few: "дублікати", many: "дублікатів"))"
    }

    static func frames(_ count: Int) -> String {
        "\(count) \(plural(count, one: "кадр", few: "кадри", many: "кадрів"))"
    }

    static func plural(_ count: Int, one: String, few: String, many: String) -> String {
        let n = abs(count) % 100
        let n1 = n % 10
        if n > 10 && n < 20 { return many }
        if n1 == 1 { return one }
        if (2...4).contains(n1) { return few }
        return many
    }
}
