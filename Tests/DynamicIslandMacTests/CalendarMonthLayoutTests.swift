import XCTest
@testable import DynamicIslandMac

final class CalendarMonthLayoutTests: XCTestCase {
    func testMonthGridUsesSixCompleteWeeksStartingOnConfiguredWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let august = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))

        let days = CalendarMonthLayout.days(containing: august, calendar: calendar)

        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: days.first?.date ?? .distantPast), DateComponents(year: 2026, month: 7, day: 27))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: days.last?.date ?? .distantPast), DateComponents(year: 2026, month: 9, day: 6))
        XCTAssertEqual(days.filter(\.isInDisplayedMonth).count, 31)
        XCTAssertTrue(days.allSatisfy { calendar.component(.hour, from: $0.date) == 0 })
    }

    func testMonthGridHonorsSundayAsFirstWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 1
        let august = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))

        let days = CalendarMonthLayout.days(containing: august, calendar: calendar)

        XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(days.first).date), 1)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: try XCTUnwrap(days.first).date), DateComponents(year: 2026, month: 7, day: 26))
    }
}
