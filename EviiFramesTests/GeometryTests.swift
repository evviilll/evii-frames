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
        XCTAssertEqual(uhd.h, 2176)
        XCTAssertEqual(uhd.w, 3840)
        XCTAssertEqual(uhd.scale, 1, accuracy: 1e-9)

        let portrait4k = Geometry.bucket(width: 2160, height: 3840)
        XCTAssertEqual(portrait4k.h, 3840)
        XCTAssertEqual(portrait4k.w, 2176)
        XCTAssertEqual(portrait4k.scale, 1, accuracy: 1e-9)
    }

    func testPackagePrefixesDoNotCollapse() {
        let lite = RIFEModel.parsePackageName("RIFE425L_256x384")
        XCTAssertEqual(lite?.prefix, "RIFE425L")
        XCTAssertEqual(lite?.h, 256)
        XCTAssertEqual(lite?.w, 384)
        let heavy = RIFEModel.parsePackageName("RIFE426H_3840x2176")
        XCTAssertEqual(heavy?.prefix, "RIFE426H")
        XCTAssertEqual(heavy?.h, 3840)
        XCTAssertEqual(heavy?.w, 2176)
        let base = RIFEModel.parsePackageName("RIFE425_1088x1920")
        XCTAssertEqual(base?.prefix, "RIFE425")
        XCTAssertNil(RIFEModel.parsePackageName("UHD_256x384"))
    }
}
