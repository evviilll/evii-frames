import Foundation

struct PlannedFrame: Equatable {
    var presentationSeconds: Double
    var left: Int
    var right: Int
    var timestep: Float
    var hold: Bool
    var mutedAudio: Bool
}

struct Plan: Equatable {
    var outputFPS: Double
    var outputDuration: Double
    var samples: [PlannedFrame]
}

struct PlanRequest: Equatable {
    enum Kind: Equatable {
        case interpolation
        case slowMo(factor: Int, fragment: ClosedRange<Double>?)
    }

    var sourceFrames: Int
    var sourceFPS: Double
    var sourceDuration: Double
    var kind: Kind = .interpolation
    var multiplier: Int = 4
    var targetFPS: Double? = nil
    var maxFPS: Double? = nil
    var loop: Bool = false
    var cuts: Set<Int> = []
    var duplicates: Set<Int> = []
    var loopCut: Bool = false
    var minimumDuration: Double? = nil
}

enum Planner {
    static func plan(_ request: PlanRequest) -> Plan {
        let frames = max(1, request.sourceFrames)
        let fps = max(request.sourceFPS, 0.0001)
        switch request.kind {
        case .slowMo(let factor, let fragment):
            return slowMo(request, frames: frames, fps: fps, factor: factor, fragment: fragment)
        case .interpolation:
            return interpolation(request, frames: frames, fps: fps)
        }
    }

    static func keyframes(frameCount: Int, duplicates: Set<Int>, cuts: Set<Int>) -> [Int] {
        guard frameCount > 0 else { return [] }
        var keys = [0]
        if frameCount == 1 { return keys }
        for index in 1..<frameCount {
            let duplicate = duplicates.contains(index) && !cuts.contains(index)
            if !duplicate { keys.append(index) }
        }
        return keys
    }

    static func bracket(
        position: Double,
        frameCount: Int,
        keys: [Int],
        cuts: Set<Int>,
        loop: Bool,
        loopCut: Bool
    ) -> (left: Int, right: Int, timestep: Float, hold: Bool) {
        guard frameCount > 1, !keys.isEmpty else { return (0, 0, 0, true) }
        let upper = loop ? Double(frameCount) : Double(frameCount - 1)
        let p = min(max(position, 0), upper)
        var extended = keys
        if loop { extended.append(frameCount) }
        var index = 0
        while index < extended.count, Double(extended[index]) < p - 1e-8 {
            index += 1
        }
        if index <= 0 {
            let key = min(extended[0], frameCount - 1)
            return (key, key, 0, false)
        }
        if index >= extended.count {
            let key = min(keys[keys.count - 1], frameCount - 1)
            return (key, key, 0, true)
        }
        let k0 = extended[index - 1]
        let k1 = extended[index]
        let left = min(k0, frameCount - 1)
        let right = k1 >= frameCount ? 0 : min(k1, frameCount - 1)
        let span = Double(k1 - k0)
        let timestep = span > 0 ? Float((p - Double(k0)) / span) : 0
        let cut: Bool
        if k1 >= frameCount {
            cut = loopCut
        } else {
            cut = cuts.contains { $0 > k0 && $0 <= k1 }
        }
        if cut { return (left, left, 0, true) }
        if timestep <= 0.0008 { return (left, left, 0, false) }
        if timestep >= 0.9992 { return (right, right, 1, false) }
        return (left, right, min(max(timestep, 0), 1), false)
    }

    private static func interpolation(_ request: PlanRequest, frames: Int, fps: Double) -> Plan {
        let outputFPS = Timing.interpolationOutputFPS(
            sourceFPS: fps,
            multiplier: request.multiplier,
            targetFPS: request.targetFPS,
            maxFPS: request.maxFPS
        )
        let count = Timing.interpolationFrameCount(
            sourceFrames: frames,
            sourceFPS: fps,
            outputFPS: outputFPS,
            loop: request.loop
        )
        let keys = keyframes(frameCount: frames, duplicates: request.duplicates, cuts: request.cuts)
        var samples: [PlannedFrame] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let time = Double(index) / outputFPS
            let position: Double
            if request.loop {
                position = (time * fps).truncatingRemainder(dividingBy: Double(frames))
            } else {
                position = min(time * fps, Double(frames - 1))
            }
            let hit = bracket(
                position: position,
                frameCount: frames,
                keys: keys,
                cuts: request.cuts,
                loop: request.loop,
                loopCut: request.loopCut
            )
            samples.append(PlannedFrame(
                presentationSeconds: time,
                left: hit.left,
                right: hit.right,
                timestep: hit.timestep,
                hold: hit.hold,
                mutedAudio: false
            ))
        }
        let cycle = Double(count) / outputFPS
        samples = extend(samples, cycle: cycle, minimum: request.minimumDuration, outputFPS: outputFPS)
        let duration = request.loop ? Double(frames) / fps : Double(max(frames - 1, 1)) / fps
        let shown = request.minimumDuration.map { max($0, duration) } ?? duration
        return Plan(outputFPS: outputFPS, outputDuration: shown, samples: samples)
    }

    private static func slowMo(
        _ request: PlanRequest,
        frames: Int,
        fps: Double,
        factor: Int,
        fragment: ClosedRange<Double>?
    ) -> Plan {
        let duration = max(request.sourceDuration, Double(max(frames - 1, 1)) / fps)
        let map = SlowMoMap(clipDuration: duration, fragment: fragment, factor: Double(max(1, factor)))
        let outputFPS = fps
        var count = Timing.slowMoFrameCount(outputDuration: map.outputDuration, fps: outputFPS)
        if let cap = request.maxFPS, cap + 0.01 < outputFPS {
            count = Timing.slowMoFrameCount(outputDuration: map.outputDuration, fps: cap)
        }
        let usedFPS = (request.maxFPS ?? outputFPS) < outputFPS ? (request.maxFPS ?? outputFPS) : outputFPS
        let keys = keyframes(frameCount: frames, duplicates: request.duplicates, cuts: request.cuts)
        var samples: [PlannedFrame] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let time = Double(index) / usedFPS
            let source = map.sourceTime(at: time)
            let position = min(max(0, source * fps), Double(frames - 1))
            let hit = bracket(
                position: position,
                frameCount: frames,
                keys: keys,
                cuts: request.cuts,
                loop: false,
                loopCut: false
            )
            samples.append(PlannedFrame(
                presentationSeconds: time,
                left: hit.left,
                right: hit.right,
                timestep: hit.timestep,
                hold: hit.hold,
                mutedAudio: map.isSlowed(sourceTime: source)
            ))
        }
        let cycle = samples.isEmpty ? map.outputDuration : Double(samples.count) / usedFPS
        samples = extend(samples, cycle: cycle, minimum: request.minimumDuration, outputFPS: usedFPS)
        let shown = request.minimumDuration.map { max($0, map.outputDuration) } ?? map.outputDuration
        return Plan(outputFPS: usedFPS, outputDuration: shown, samples: samples)
    }

    private static func extend(
        _ samples: [PlannedFrame],
        cycle: Double,
        minimum: Double?,
        outputFPS: Double
    ) -> [PlannedFrame] {
        guard let minimum, cycle > 0.0001, minimum > cycle + 0.001, !samples.isEmpty else {
            return samples
        }
        let copies = Int(ceil(minimum / cycle))
        var all: [PlannedFrame] = []
        all.reserveCapacity(samples.count * copies)
        for copy in 0..<copies {
            let shift = Double(copy) * cycle
            for sample in samples {
                let time = sample.presentationSeconds + shift
                if time >= minimum - (0.25 / outputFPS) { continue }
                var next = sample
                next.presentationSeconds = time
                all.append(next)
            }
        }
        return all.isEmpty ? samples : all
    }
}
