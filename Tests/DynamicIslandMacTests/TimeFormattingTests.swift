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
}
