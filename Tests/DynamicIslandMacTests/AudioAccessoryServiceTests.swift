import XCTest
@testable import DynamicIslandMac

final class AudioAccessoryServiceTests: XCTestCase {
    func testClassifierDistinguishesAirPodsFamiliesAndOtherHeadphones() {
        XCTAssertEqual(classify("Emirhan's AirPods"), .airPods)
        XCTAssertEqual(classify("AirPods Pro"), .airPodsPro)
        XCTAssertEqual(classify("AirPods Max"), .airPodsMax)
        XCTAssertEqual(classify("Studio Headphones"), .headphones)
        XCTAssertEqual(classify("Beats Solo"), .headphones)
    }

    func testClassifierUsesBluetoothAudioClassWithoutTreatingSpeakersAsHeadphones() {
        XCTAssertEqual(
            AudioAccessoryClassifier.kind(
                name: "Generic Audio",
                deviceClassMajor: 0x04,
                deviceClassMinor: 0x06,
                serviceClassMajor: 0x100,
                isActiveBluetoothOutput: false
            ),
            .headphones
        )
        XCTAssertNil(
            AudioAccessoryClassifier.kind(
                name: "Desk Speaker",
                deviceClassMajor: 0x04,
                deviceClassMinor: 0x05,
                serviceClassMajor: 0x100,
                isActiveBluetoothOutput: false
            )
        )
        XCTAssertNil(
            AudioAccessoryClassifier.kind(
                name: "Magic Mouse",
                deviceClassMajor: 0x05,
                deviceClassMinor: 0x02,
                serviceClassMajor: 0,
                isActiveBluetoothOutput: false
            )
        )
    }

    func testUnclassifiedAudioRequiresCoreAudioConfirmation() {
        XCTAssertNil(
            AudioAccessoryClassifier.kind(
                name: "Living Room Device",
                deviceClassMajor: 0,
                deviceClassMinor: 0,
                serviceClassMajor: 0x100,
                isActiveBluetoothOutput: false
            )
        )
        XCTAssertEqual(
            AudioAccessoryClassifier.kind(
                name: "Living Room Device",
                deviceClassMajor: 0,
                deviceClassMinor: 0,
                serviceClassMajor: 0x100,
                isActiveBluetoothOutput: true
            ),
            .headphones
        )
    }

    func testNameMatchingIgnoresCasePunctuationAndOwnerPrefix() {
        XCTAssertTrue(AudioAccessoryClassifier.namesMatch("Emirhan’s AirPods Pro", "AirPods Pro"))
        XCTAssertTrue(AudioAccessoryClassifier.namesMatch("SONY WH-1000XM5", "Sony WH 1000XM5"))
        XCTAssertFalse(AudioAccessoryClassifier.namesMatch("AirPods Pro", "Desk Speaker"))
    }

    func testInitialSnapshotDoesNotProduceConnectionPopup() {
        var tracker = AudioAccessoryTransitionTracker()

        XCTAssertTrue(tracker.update([snapshot(id: "A")]).isEmpty)
        XCTAssertTrue(tracker.isPrimed)
    }

    func testTrackerEmitsOnlyRealConnectAndDisconnectTransitions() throws {
        var tracker = AudioAccessoryTransitionTracker()
        _ = tracker.update([snapshot(id: "A")])

        let connected = try XCTUnwrap(tracker.update([
            snapshot(id: "A", battery: 88, active: false),
            snapshot(id: "B", name: "AirPods Max", kind: .airPodsMax, active: true)
        ]).only)
        XCTAssertEqual(connected.state, .connected)
        XCTAssertEqual(connected.accessory.id, "B")
        XCTAssertTrue(connected.accessory.isConnected)

        // Battery and active-output metadata are allowed to change silently.
        XCTAssertTrue(tracker.update([
            snapshot(id: "A", battery: 70, active: true),
            snapshot(id: "B", name: "AirPods Max", kind: .airPodsMax, battery: 92, active: false)
        ]).isEmpty)

        let disconnected = try XCTUnwrap(tracker.update([
            snapshot(id: "A", battery: 70, active: true)
        ]).only)
        XCTAssertEqual(disconnected.state, .disconnected)
        XCTAssertEqual(disconnected.accessory.id, "B")
        XCTAssertFalse(disconnected.accessory.isConnected)
        XCTAssertFalse(disconnected.accessory.isActiveOutput)
    }

    func testBatteryMathAcceptsOnlyReliableLogicalRanges() {
        XCTAssertEqual(
            AudioAccessoryBatteryMath.percent(rawValue: 3, logicalMinimum: 0, logicalMaximum: 5),
            60
        )
        XCTAssertEqual(
            AudioAccessoryBatteryMath.percent(rawValue: 73, logicalMinimum: 0, logicalMaximum: 100),
            73
        )
        XCTAssertNil(AudioAccessoryBatteryMath.percent(rawValue: 6, logicalMinimum: 0, logicalMaximum: 5))
        XCTAssertNil(AudioAccessoryBatteryMath.percent(rawValue: 0, logicalMinimum: 0, logicalMaximum: 0))
    }

    func testSystemProfilerParserUsesOnlyConnectedDevicesAndReadsBudCaseLevels() throws {
        let data = try XCTUnwrap(
            """
            {
              "SPBluetoothDataType": [{
                "device_connected": [{
                  "Emirhan (AirPods Pro)": {
                    "device_minorType": "Headphones",
                    "device_batteryLevelLeft": "%80",
                    "device_batteryLevelRight": "%75",
                    "device_batteryLevelCase": "%70"
                  }
                }],
                "device_not_connected": [{
                  "Emirhan (AirPods Pro)": {
                    "device_batteryLevelLeft": "%10",
                    "device_batteryLevelRight": "%10",
                    "device_batteryLevelCase": "%10"
                  }
                }]
              }]
            }
            """.data(using: .utf8)
        )

        let record = try XCTUnwrap(SystemProfilerBluetoothBatteryParser.records(from: data).only)
        XCTAssertEqual(record.name, "Emirhan (AirPods Pro)")
        XCTAssertEqual(record.levels.leftPercent, 80)
        XCTAssertEqual(record.levels.rightPercent, 75)
        XCTAssertEqual(record.levels.casePercent, 70)
        XCTAssertEqual(record.levels.combinedPercent, 75)
    }

    func testSystemProfilerParserReadsMainBatteryAndRejectsInvalidPercentages() throws {
        let data = try XCTUnwrap(
            """
            {
              "SPBluetoothDataType": [{
                "device_connected": [
                  {"AirPods Max": {"device_batteryLevelMain": "%91"}},
                  {"Broken Headset": {"device_batteryLevelMain": "%140"}}
                ]
              }]
            }
            """.data(using: .utf8)
        )

        let records = SystemProfilerBluetoothBatteryParser.records(from: data)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].levels.mainPercent, 91)
        XCTAssertEqual(records[0].levels.combinedPercent, 91)
        XCTAssertNil(records[1].levels.mainPercent)
    }

    func testBatteryMetadataFieldsStaySilentInTransitionTracker() {
        var tracker = AudioAccessoryTransitionTracker()
        _ = tracker.update([snapshot(id: "A", battery: 40)])

        let enriched = AudioAccessorySnapshot(
            id: "A",
            name: "AirPods Pro",
            kind: .airPodsPro,
            batteryPercent: 75,
            batteryLeftPercent: 80,
            batteryRightPercent: 75,
            batteryCasePercent: 70,
            isConnected: true,
            isActiveOutput: true
        )
        XCTAssertTrue(tracker.update([enriched]).isEmpty)
    }

    private func classify(_ name: String) -> AudioAccessoryKind? {
        AudioAccessoryClassifier.kind(
            name: name,
            deviceClassMajor: 0,
            deviceClassMinor: 0,
            serviceClassMajor: 0,
            isActiveBluetoothOutput: false
        )
    }

    private func snapshot(
        id: String,
        name: String = "AirPods Pro",
        kind: AudioAccessoryKind = .airPodsPro,
        battery: Int? = nil,
        active: Bool = false
    ) -> AudioAccessorySnapshot {
        AudioAccessorySnapshot(
            id: id,
            name: name,
            kind: kind,
            batteryPercent: battery,
            batteryLeftPercent: nil,
            batteryRightPercent: nil,
            batteryCasePercent: nil,
            isConnected: true,
            isActiveOutput: active
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
