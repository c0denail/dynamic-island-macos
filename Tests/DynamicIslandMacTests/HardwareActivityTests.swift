import XCTest
@testable import DynamicIslandMac

final class HardwareActivityTests: XCTestCase {
    func testBatteryLevelsPreferCombinedAndAverageIndividualBuds() {
        XCTAssertEqual(IslandBatteryLevels(combined: 73, left: 40, right: 60).preferred, 73)
        XCTAssertEqual(IslandBatteryLevels(left: 41, right: 60).preferred, 51)
        XCTAssertEqual(IslandBatteryLevels(caseLevel: 88).preferred, 88)
    }

    func testBatteryLevelsRejectValuesOutsidePercentageRange() {
        let levels = IslandBatteryLevels(combined: 101, left: -1, right: 62, caseLevel: 140)
        XCTAssertNil(levels.combined)
        XCTAssertNil(levels.left)
        XCTAssertEqual(levels.preferred, 62)
        XCTAssertNil(levels.caseLevel)
    }

    func testStorageProgressRepresentsUsedCapacity() {
        let activity = IslandHardwareActivity(
            kind: .storageConnected,
            title: "Travel",
            subtitle: "USB",
            totalCapacity: 1_000,
            availableCapacity: 250
        )

        XCTAssertEqual(activity.progress ?? -1, 0.75, accuracy: 0.000_1)
    }

    func testHardwareKindsExposeExpectedCategories() {
        XCTAssertTrue(IslandHardwareActivityKind.airPods.isAudioAccessory)
        XCTAssertTrue(IslandHardwareActivityKind.airPodsMax.isAudioAccessory)
        XCTAssertTrue(IslandHardwareActivityKind.headphones.isAudioAccessory)
        XCTAssertFalse(IslandHardwareActivityKind.charging.isAudioAccessory)
        XCTAssertFalse(IslandHardwareActivityKind.powerConnected.isAudioAccessory)
        XCTAssertTrue(IslandHardwareActivityKind.storageConnected.isStorage)
        XCTAssertTrue(IslandHardwareActivityKind.storageDisconnected.isStorage)
    }
}
