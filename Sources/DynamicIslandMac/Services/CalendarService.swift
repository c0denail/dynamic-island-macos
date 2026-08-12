import AppKit
import Combine
import EventKit
import Foundation

enum CalendarAccessState: Equatable {
    case notDetermined
    case requesting
    case fullAccess
    case writeOnly
    case denied
    case restricted
}

struct CalendarEventItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
}

struct CalendarMonthDay: Identifiable, Equatable, Sendable {
    var id: Date { date }
    let date: Date
    let isInDisplayedMonth: Bool
}

enum CalendarMonthLayout {
    static func days(
        containing displayedDate: Date,
        calendar sourceCalendar: Calendar = .autoupdatingCurrent
    ) -> [CalendarMonthDay] {
        let calendar = sourceCalendar
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedDate) else { return [] }

        let firstDay = calendar.startOfDay(for: monthInterval.start)
        let weekday = calendar.component(.weekday, from: firstDay)
        let leadingDayCount = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leadingDayCount, to: firstDay) else { return [] }

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return CalendarMonthDay(
                date: date,
                isInDisplayedMonth: calendar.isDate(date, equalTo: displayedDate, toGranularity: .month)
            )
        }
    }
}

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var accessState: CalendarAccessState
    @Published private(set) var events: [CalendarEventItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let permissionStore = EKEventStore()
    private var latestLoadID: UUID?
    private var activeQueryStart: Date?
    private var activeQueryEnd: Date?
    private var lastQueryStart: Date?
    private var lastQueryEnd: Date?
    private var lastRefreshDate: Date?
    private var eventDays: Set<Date> = []

    private init() {
        accessState = Self.mapAuthorizationStatus(EKEventStore.authorizationStatus(for: .event))
    }

    var canReadEvents: Bool { accessState == .fullAccess }

    var nextEvent: CalendarEventItem? {
        let now = Date()
        return events.first { $0.endDate > now }
    }

    func prepareForPresentation(month: Date) {
        refreshAuthorizationStatus()
        switch accessState {
        case .notDetermined:
            requestAccess(month: month)
        case .fullAccess:
            refresh(month: month)
        case .requesting, .writeOnly, .denied, .restricted:
            break
        }
    }

    func refreshAuthorizationStatus() {
        guard accessState != .requesting else { return }
        accessState = Self.mapAuthorizationStatus(EKEventStore.authorizationStatus(for: .event))
        if accessState != .fullAccess {
            latestLoadID = nil
            activeQueryStart = nil
            activeQueryEnd = nil
            events = []
            eventDays = []
            isLoading = false
        }
    }

    func requestAccess(month: Date) {
        guard accessState == .notDetermined else {
            prepareForPresentation(month: month)
            return
        }

        accessState = .requesting
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await permissionStore.requestFullAccessToEvents()
                accessState = Self.mapAuthorizationStatus(EKEventStore.authorizationStatus(for: .event))
                if accessState == .fullAccess {
                    refresh(month: month)
                }
            } catch {
                accessState = Self.mapAuthorizationStatus(EKEventStore.authorizationStatus(for: .event))
                errorMessage = error.localizedDescription
            }
        }
    }

    func refresh(month: Date) {
        refreshAuthorizationStatus()
        guard canReadEvents else { return }

        let calendar = Calendar.autoupdatingCurrent
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return }
        let now = Date()
        let upcomingEnd = calendar.date(byAdding: .day, value: 60, to: now) ?? now.addingTimeInterval(60 * 86_400)
        let queryStart = min(monthInterval.start, calendar.startOfDay(for: now))
        let queryEnd = max(monthInterval.end, upcomingEnd)

        if isLoading, activeQueryStart == queryStart, activeQueryEnd == queryEnd {
            return
        }
        if lastQueryStart == queryStart,
           lastQueryEnd == queryEnd,
           let lastRefreshDate,
           now.timeIntervalSince(lastRefreshDate) < 30 {
            return
        }

        let loadID = UUID()
        latestLoadID = loadID
        activeQueryStart = queryStart
        activeQueryEnd = queryEnd
        isLoading = true
        errorMessage = nil

        Task { [weak self] in
            let loadedEvents = await Task.detached(priority: .utility) {
                let eventStore = EKEventStore()
                let predicate = eventStore.predicateForEvents(
                    withStart: queryStart,
                    end: queryEnd,
                    calendars: nil
                )

                return eventStore.events(matching: predicate)
                    .compactMap { event -> CalendarEventItem? in
                        guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
                        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let sourceCalendar = event.calendar
                        let fallbackID = [
                            sourceCalendar?.calendarIdentifier ?? "calendar",
                            String(startDate.timeIntervalSinceReferenceDate),
                            title.isEmpty ? "Etkinlik" : title
                        ].joined(separator: "|")
                        let occurrenceID = [
                            event.eventIdentifier ?? fallbackID,
                            String(startDate.timeIntervalSinceReferenceDate)
                        ].joined(separator: "|")
                        return CalendarEventItem(
                            id: occurrenceID,
                            title: title.isEmpty ? "Etkinlik" : title,
                            startDate: startDate,
                            endDate: endDate,
                            isAllDay: event.isAllDay,
                            calendarTitle: sourceCalendar?.title ?? "Takvim"
                        )
                    }
                    .sorted { lhs, rhs in
                        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
            }.value

            guard let self, latestLoadID == loadID else { return }
            eventDays = Self.dayIndex(for: loadedEvents, calendar: calendar)
            events = loadedEvents
            activeQueryStart = nil
            activeQueryEnd = nil
            lastQueryStart = queryStart
            lastQueryEnd = queryEnd
            lastRefreshDate = Date()
            isLoading = false
        }
    }

    func events(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> [CalendarEventItem] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.startDate < end && $0.endDate > start }
    }

    func upcomingEvents(limit: Int = 6) -> [CalendarEventItem] {
        let now = Date()
        return Array(events.filter { $0.endDate > now }.prefix(max(0, limit)))
    }

    func hasEvents(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        eventDays.contains(calendar.startOfDay(for: date))
    }

    func openCalendarApplication() {
        let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: calendarURL, configuration: configuration)
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func mapAuthorizationStatus(_ status: EKAuthorizationStatus) -> CalendarAccessState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized, .fullAccess:
            return .fullAccess
        case .writeOnly:
            return .writeOnly
        @unknown default:
            return .denied
        }
    }

    private static func dayIndex(for events: [CalendarEventItem], calendar: Calendar) -> Set<Date> {
        var result = Set<Date>()
        for event in events {
            var day = calendar.startOfDay(for: event.startDate)
            while day < event.endDate {
                result.insert(day)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
                day = nextDay
            }
        }
        return result
    }
}
