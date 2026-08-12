import XCTest
@testable import DynamicIslandMac

final class IslandAnimationCadenceTests: XCTestCase {
    func testProMotionDisplayUses120FramesPerSecond() {
        XCTAssertEqual(
            IslandAnimationCadence.framesPerSecond(displayMaximum: 120),
            120
        )
        XCTAssertEqual(IslandAnimationCadence.minimumInterval, 1.0 / 120.0)
    }

    func test60HzDisplayKeepsItsNativeCadence() {
        XCTAssertEqual(
            IslandAnimationCadence.framesPerSecond(displayMaximum: 60),
            60
        )
    }

    func testHigherRefreshDisplayIsCappedAt120FramesPerSecond() {
        XCTAssertEqual(
            IslandAnimationCadence.framesPerSecond(displayMaximum: 144),
            120
        )
    }
}
