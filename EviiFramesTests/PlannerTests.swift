import XCTest
@testable import EviiFrames

final class PlannerTests: XCTestCase {
    func testMockInterpolationPlan() {
        var request = PlanRequest(
            sourceFrames: 60,
            sourceFPS: 29.97,
            sourceDuration: 60 / 29.97
        )
        request.multiplier = 4
        request.maxFPS = 120
        let plan = Planner.plan(request)
        XCTAssertEqual(plan.samples.count, 237)
        XCTAssertEqual(plan.outputFPS, 119.88, accuracy: 0.001)
        XCTAssertEqual(plan.samples.first?.presentationSeconds ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(plan.samples.last?.presentationSeconds ?? -1, 236 / 119.88, accuracy: 1e-6)
        assertIncreasing(plan)
        XCTAssertEqual(plan.samples.first?.left, 0)
        XCTAssertEqual(plan.samples.last?.left, 59)
        XCTAssertTrue(plan.samples.last?.hold == false || plan.samples.last?.timestep == 0)
    }

    func testTimestampsStayInsideTheSource() {
        let request = PlanRequest(sourceFrames: 10, sourceFPS: 10, sourceDuration: 1, multiplier: 4)
        let plan = Planner.plan(request)
        XCTAssertEqual(plan.samples.count, 37)
        for sample in plan.samples {
            XCTAssertGreaterThanOrEqual(sample.left, 0)
            XCTAssertLessThan(sample.left, 10)
            XCTAssertGreaterThanOrEqual(sample.right, 0)
            XCTAssertLessThan(sample.right, 10)
            XCTAssertGreaterThanOrEqual(sample.timestep, 0)
            XCTAssertLessThanOrEqual(sample.timestep, 1)
        }
        let midpoint = plan.samples.first { abs($0.presentationSeconds - 0.15) < 1e-9 }
        XCTAssertEqual(midpoint?.left, 1)
        XCTAssertEqual(midpoint?.right, 2)
        XCTAssertEqual(midpoint?.timestep ?? -1, 0.5, accuracy: 0.02)
    }

    func testSceneCutHoldsInsteadOfMorphing() {
        var request = PlanRequest(sourceFrames: 60, sourceFPS: 30, sourceDuration: 2, multiplier: 2)
        request.cuts = [30]
        let plan = Planner.plan(request)
        let crossing = plan.samples.first { abs($0.presentationSeconds - (59.0 / 60.0)) < 1e-9 }
        XCTAssertNotNil(crossing)
        XCTAssertEqual(crossing?.hold, true)
        XCTAssertEqual(crossing?.left, 29)
        XCTAssertEqual(crossing?.right, 29)
    }

    func testDedupInterpolatesAcrossRepeatedFrames() {
        var request = PlanRequest(sourceFrames: 3, sourceFPS: 1, sourceDuration: 2, multiplier: 2)
        request.duplicates = [1]
        let plan = Planner.plan(request)
        XCTAssertEqual(plan.samples.count, 5)
        let middle = plan.samples.first { abs($0.presentationSeconds - 1) < 1e-9 }
        XCTAssertEqual(middle?.left, 0)
        XCTAssertEqual(middle?.right, 2)
        XCTAssertEqual(middle?.timestep ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(middle?.hold, false)
    }

    func testLoopClosesTheLastGap() {
        var request = PlanRequest(sourceFrames: 4, sourceFPS: 4, sourceDuration: 1, multiplier: 2)
        request.loop = true
        let plan = Planner.plan(request)
        XCTAssertEqual(plan.samples.count, 8)
        let closing = plan.samples.last
        XCTAssertEqual(closing?.left, 3)
        XCTAssertEqual(closing?.right, 0)
        XCTAssertEqual(closing?.timestep ?? -1, 0.5, accuracy: 0.05)
    }

    func testLoopCutDoesNotMorph() {
        var request = PlanRequest(sourceFrames: 4, sourceFPS: 4, sourceDuration: 1, multiplier: 2)
        request.loop = true
        request.loopCut = true
        let plan = Planner.plan(request)
        let closing = plan.samples.last
        XCTAssertEqual(closing?.hold, true)
        XCTAssertEqual(closing?.left, 3)
    }

    func testMinimumDurationRepeatsTheTimeline() {
        var request = PlanRequest(sourceFrames: 11, sourceFPS: 10, sourceDuration: 1, multiplier: 2)
        request.minimumDuration = 2.5
        let plan = Planner.plan(request)
        assertIncreasing(plan)
        XCTAssertGreaterThanOrEqual(plan.outputDuration, 2.5)
        XCTAssertLessThan(plan.samples.last?.presentationSeconds ?? 0, 2.5)
        XCTAssertGreaterThan(plan.samples.last?.presentationSeconds ?? 0, 2.3)
        XCTAssertGreaterThan(plan.samples.count, 21)
    }

    func testSlowMoWholeClipTimestamps() {
        var request = PlanRequest(sourceFrames: 60, sourceFPS: 30, sourceDuration: 2, multiplier: 2)
        request.kind = .slowMo(factor: 4, fragment: nil)
        let plan = Planner.plan(request)
        XCTAssertEqual(plan.outputFPS, 30, accuracy: 0.001)
        XCTAssertEqual(plan.outputDuration, 8, accuracy: 1e-6)
        XCTAssertEqual(plan.samples.count, 240)
        let atOne = plan.samples[30]
        XCTAssertEqual(atOne.presentationSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(atOne.left, 7)
        XCTAssertEqual(atOne.right, 8)
        XCTAssertEqual(atOne.timestep, 0.5, accuracy: 0.02)
        XCTAssertTrue(atOne.mutedAudio)
    }

    func testSlowMoFragmentMutesOnlyTheSlowedRange() {
        var request = PlanRequest(sourceFrames: 60, sourceFPS: 30, sourceDuration: 2)
        request.kind = .slowMo(factor: 4, fragment: 0.6...1.5)
        let plan = Planner.plan(request)
        XCTAssertEqual(plan.outputDuration, 4.7, accuracy: 1e-6)
        let early = plan.samples.first { abs($0.presentationSeconds - 0.3) < 0.02 }
        let inside = plan.samples.first { abs($0.presentationSeconds - 1.0) < 0.02 }
        let late = plan.samples.first { abs($0.presentationSeconds - 4.5) < 0.02 }
        XCTAssertEqual(early?.mutedAudio, false)
        XCTAssertEqual(inside?.mutedAudio, true)
        XCTAssertEqual(late?.mutedAudio, false)
    }

    private func assertIncreasing(_ plan: Plan) {
        let times = plan.samples.map(\.presentationSeconds)
        for index in 1..<times.count {
            XCTAssertGreaterThan(times[index], times[index - 1])
        }
    }
}
