import XCTest
@testable import EviiFrames

final class GeometryTests: XCTestCase {
    func testPadToMultipleOf64() {
        XCTAssertEqual(Geometry.pad(1080, multiple: 64), 1088)
        XCTAssertEqual(Geometry.pad(1920, multiple: 64), 1920)
        XCTAssertEqual(Geometry.pad(720, multiple: 64), 768)
    }

    func testFit720p() {
        let size = Geometry.fit(width: 1920, height: 1080, limit: (1280, 720))
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    func testOriginalIsUnchangedAndEven() {
        let size = Geometry.fit(width: 1919, height: 1080, limit: nil)
        XCTAssertEqual(size.width, 1918)
        XCTAssertEqual(size.height, 1080)
    }

    func testBucketsForCommonVideoSizes() {
        let hd = Geometry.bucket(width: 1920, height: 1080)
        XCTAssertEqual(hd.h, 1088)
        XCTAssertEqual(hd.w, 1920)
        XCTAssertEqual(hd.scale, 1, accuracy: 1e-9)

        let portrait = Geometry.bucket(width: 1080, height: 1920)
        XCTAssertEqual(portrait.h, 1920)
        XCTAssertEqual(portrait.w, 1088)

        let small = Geometry.bucket(width: 640, height: 360)
        XCTAssertEqual(small.h, 384)
        XCTAssertEqual(small.w, 640)

        let uhd = Geometry.bucket(width: 3840, height: 2160)
        XCTAssertEqual(uhd.h, 1088)
        XCTAssertEqual(uhd.w, 1920)
        XCTAssertEqual(uhd.scale, 0.5, accuracy: 0.01)
    }
}
