import XCTest
@testable import DynamicIslandMac

final class ChargingEventServiceTests: XCTestCase {
    func testInitialSnapshotEstablishesBaselineWithoutEvent() {
        var detector = ChargingConnectionTransitionDetector()
        let initial = snapshot(connected: true, charging: true, percentage: 42, minutesToFull: 58)

        XCTAssertNil(detector.process(initial))
        XCTAssertEqual(detector.previousSnapshot, initial)
    }

    func testConnectionTransitionPublishesConnectedEvent() {
        var detector = ChargingConnectionTransitionDetector()
        _ = detector.process(snapshot(connected: false))

        let result = detector.process(snapshot(connected: true, charging: true))

        XCTAssertEqual(result, .connectedToPower)
    }

    func testDisconnectionTransitionPublishesDisconnectedEvent() {
        var detector = ChargingConnectionTransitionDetector()
        _ = detector.process(snapshot(connected: true, charging: false))

        let result = detector.process(snapshot(connected: false))

        XCTAssertEqual(result, .disconnectedFromPower)
    }

    func testCapacityAndChargingUpdatesDoNotCreateConnectionEvents() {
        var detector = ChargingConnectionTransitionDetector()
        _ = detector.process(snapshot(connected: true, charging: true, percentage: 42, minutesToFull: 58))

        XCTAssertNil(detector.process(
            snapshot(connected: true, charging: true, percentage: 43, minutesToFull: 54)
        ))
        XCTAssertNil(detector.process(
            snapshot(connected: true, charging: false, percentage: 80, minutesToFull: nil)
        ))
    }

    func testResetRequiresANewSilentBaseline() {
        var detector = ChargingConnectionTransitionDetector()
        _ = detector.process(snapshot(connected: false))
        detector.reset()

        XCTAssertNil(detector.process(snapshot(connected: true, charging: true)))
    }

    private func snapshot(
        connected: Bool,
        charging: Bool = false,
        percentage: Int? = 50,
        minutesToFull: Int? = nil
    ) -> ChargingPowerSnapshot {
        ChargingPowerSnapshot(
            isConnectedToAC: connected,
            isCharging: charging,
            batteryPercentage: percentage,
            estimatedMinutesToFull: minutesToFull
        )
    }
}
