import XCTest
@testable import DynamicIslandMac

final class TimeFormattingTests: XCTestCase {
    func testMinuteFormatting() {
        XCTAssertEqual(TimeInterval(0).islandClock, "00:00")
        XCTAssertEqual(TimeInterval(65).islandClock, "01:05")
    }

    func testHourFormatting() {
        XCTAssertEqual(TimeInterval(3_661).islandClock, "1:01:01")
    }

    func testNegativeTimeIsClamped() {
        XCTAssertEqual(TimeInterval(-12).islandClock, "00:00")
    }

    func testTurkishDecimalMediaTimeParsing() {
        XCTAssertEqual("29,316999435425".islandLocalizedTimeInterval, 29.316999435425, accuracy: 0.000_001)
        XCTAssertEqual(" 181,722 ".islandLocalizedTimeInterval, 181.722, accuracy: 0.000_001)
    }

    func testMirroredNotificationDisplayText() {
        let notification = MirroredNotification(
            id: "notification-1",
            appName: "Mesajlar",
            title: "Yeni mesaj",
            subtitle: "Emirhan",
            body: "Merhaba",
            bundleIdentifier: "com.apple.MobileSMS",
            appIconData: nil
        )

        XCTAssertEqual(notification.displayTitle, "Yeni mesaj")
        XCTAssertEqual(notification.displayDetail, "Emirhan · Merhaba")
    }

    func testMirroredNotificationFallsBackToApplicationName() {
        let notification = MirroredNotification(
            id: "notification-2",
            appName: "Takvim",
            title: "",
            subtitle: "",
            body: "Toplantı başlıyor",
            bundleIdentifier: nil,
            appIconData: nil
        )

        XCTAssertEqual(notification.displayTitle, "Takvim")
        XCTAssertEqual(notification.displayDetail, "Toplantı başlıyor")
    }

    func testClockReaderPrefersDynamicIslandTimer() throws {
        let now = Date()
        let root: [String: Any] = [
            "MTTimers": [
                "MTTimers": [
                    timerEntry(id: "external", title: "Mutfak", state: 3, duration: 60, fireDate: now.addingTimeInterval(20)),
                    timerEntry(id: "owned", title: "Dynamic Island", state: 3, duration: 300, fireDate: now.addingTimeInterval(240))
                ]
            ]
        ]

        let readout = ClockActivitySnapshotReader.decode(data: try propertyListData(root), now: now)

        XCTAssertEqual(readout.timer?.identifier, "owned")
        XCTAssertEqual(readout.timer?.state, .running)
        XCTAssertEqual(readout.timer?.remainingAtSnapshot ?? 0, 240, accuracy: 0.01)
    }

    func testClockReaderDecodesPausedTimerInterval() throws {
        let root: [String: Any] = [
            "MTTimers": [
                "MTTimers": [[
                    "$MTTimer": [
                        "MTTimerID": "paused",
                        "MTTimerDuration": 900,
                        "MTTimerState": 2,
                        "MTTimerFireTime": ["$MTTimerTimeInterval": ["MTTimerTimeInterval": 321]]
                    ]
                ]]
            ]
        ]

        let readout = ClockActivitySnapshotReader.decode(data: try propertyListData(root))

        XCTAssertEqual(readout.timer?.state, .paused)
        XCTAssertEqual(readout.timer?.remaining, 321)
    }

    func testPausedClockTimerPrefersFrozenIntervalOverFireDate() throws {
        let now = Date()
        let root: [String: Any] = [
            "MTTimers": [
                "MTTimers": [[
                    "$MTTimer": [
                        "MTTimerID": "paused-with-fire-date",
                        "MTTimerDuration": 900,
                        "MTTimerState": 2,
                        "MTTimerFireTime": [
                            "$MTTimerDate": ["MTTimerTimeDate": now.addingTimeInterval(600)],
                            "$MTTimerTimeInterval": ["MTTimerTimeInterval": 321]
                        ]
                    ]
                ]]
            ]
        ]

        let readout = ClockActivitySnapshotReader.decode(data: try propertyListData(root), now: now)

        XCTAssertEqual(readout.timer?.state, .paused)
        XCTAssertEqual(readout.timer?.remaining, 321)
    }

    func testClockReaderDecodesRunningStopwatch() throws {
        let now = Date()
        let root: [String: Any] = [
            "MTStopwatches": [
                "MTStopwatches": [[
                    "$MTStopwatch": [
                        "MTStopwatchIdentifier": "stopwatch",
                        "MTStopwatchState": 2,
                        "MTStopwatchCurrentInterval": 0.0,
                        "MTStopwatchOffset": 1.0,
                        "MTStopwatchPreviousLapsTotalInterval": 0.5,
                        "MTStopwatchStartDate": now.addingTimeInterval(-5)
                    ]
                ]]
            ]
        ]

        let readout = ClockActivitySnapshotReader.decode(data: try propertyListData(root), now: now)

        XCTAssertEqual(readout.stopwatch?.state, .running)
        XCTAssertEqual(readout.stopwatch?.elapsed ?? 0, 6, accuracy: 0.25)
    }

    func testClockReaderDoesNotDoublePausedStopwatchInterval() throws {
        let root: [String: Any] = [
            "MTStopwatches": [
                "MTStopwatches": [[
                    "$MTStopwatch": [
                        "MTStopwatchIdentifier": "paused-stopwatch",
                        "MTStopwatchState": 1,
                        "MTStopwatchCurrentInterval": 1.99,
                        "MTStopwatchOffset": 2.01,
                        "MTStopwatchPreviousLapsTotalInterval": 0
                    ]
                ]]
            ]
        ]

        let readout = ClockActivitySnapshotReader.decode(data: try propertyListData(root))

        XCTAssertEqual(readout.stopwatch?.state, .paused)
        XCTAssertEqual(readout.stopwatch?.elapsed ?? 0, 2.01, accuracy: 0.01)
    }

    private func timerEntry(id: String, title: String, state: Int, duration: Double, fireDate: Date) -> [String: Any] {
        [
            "$MTTimer": [
                "MTTimerID": id,
                "MTTimerTitle": title,
                "MTTimerState": state,
                "MTTimerDuration": duration,
                "MTTimerFireTime": ["$MTTimerDate": ["MTTimerTimeDate": fireDate]]
            ]
        ]
    }

    private func propertyListData(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
}
