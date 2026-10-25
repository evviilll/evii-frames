import XCTest
@testable import EviiFrames

final class AnalysisTests: XCTestCase {
    func testSceneCutOnSyntheticFrames() {
        let side = 32
        let black = [UInt8](repeating: 0, count: side * side)
        let white = [UInt8](repeating: 255, count: side * side)
        let frames = [black, black, white, white]
        let signatures = frames.map { LumaGrid.fromLuma($0, width: side, height: side, grid: 16) }
        let cuts = SceneDetector.cutIndices(signatures: signatures, sensitivity: 0.40)
        XCTAssertEqual(cuts, [2])
    }

    func testSimilarFramesAreNotACut() {
        let side = 16
        let a = [UInt8](repeating: 40, count: side * side)
        var b = a
        for i in 0..<20 { b[i] = 48 }
        let sa = LumaGrid.fromLuma(a, width: side, height: side, grid: 8)
        let sb = LumaGrid.fromLuma(b, width: side, height: side, grid: 8)
        XCTAssertFalse(SceneDetector.isCut(sa, sb, sensitivity: 0.40))
        XCTAssertTrue(SceneDetector.cutIndices(signatures: [sa, sb, sa], sensitivity: 0.40).isEmpty)
    }

    func testLowSensitivityIgnoresAModerateChange() {
        let a = [Float](repeating: 0, count: 16)
        let b = [Float](repeating: 0.40, count: 16)
        XCTAssertFalse(SceneDetector.isCut(a, b, sensitivity: 0))
        XCTAssertTrue(SceneDetector.isCut(a, b, sensitivity: 1))
    }

    func testDedupOnSyntheticFrames() {
        let side = 16
        let base = [UInt8](repeating: 120, count: side * side)
        var almost = base
        almost[0] = 121
        let other = [UInt8](repeating: 10, count: side * side)
        let signatures = [base, almost, other].map { LumaGrid.fromLuma($0, width: side, height: side, grid: 8) }
        let duplicates = Dedup.duplicateIndices(signatures: signatures, mode: .fast, thresholdPercent: 1.0)
        XCTAssertEqual(duplicates, [1])
        XCTAssertTrue(Dedup.duplicateIndices(signatures: signatures, mode: .off, thresholdPercent: 1.0).isEmpty)
    }

    func testAccurateDedupKeepsALocalChangeThatFastPoolsAway() {
        let fine = 4
        var left = [Float](repeating: 0.2, count: fine * fine)
        var right = left
        right[5] = 1
        let fineStats = DiffStats.make(left, right)
        let coarse = LumaGrid.pool(right, from: fine, to: 2)
        let coarseLeft = LumaGrid.pool(left, from: fine, to: 2)
        let coarseStats = DiffStats.make(coarseLeft, coarse)

        XCTAssertTrue(Dedup.isDuplicate(fineStats, thresholdPercent: 10, mode: .fast))
        XCTAssertFalse(Dedup.isDuplicate(fineStats, thresholdPercent: 10, mode: .accurate))
        XCTAssertTrue(Dedup.isDuplicate(coarseStats, thresholdPercent: 10, mode: .fast))
        XCTAssertLessThan(coarseStats.maxCell, fineStats.maxCell)
    }

    func testIdenticalFramesAreDuplicatesInBothModes() {
        let frame = [Float](repeating: 0.44, count: 64)
        var nudged = frame
        nudged[3] = 0.441
        let stats = DiffStats.make(frame, nudged)
        XCTAssertTrue(Dedup.isDuplicate(stats, thresholdPercent: 1, mode: .fast))
        XCTAssertTrue(Dedup.isDuplicate(stats, thresholdPercent: 1, mode: .accurate))
    }
}
