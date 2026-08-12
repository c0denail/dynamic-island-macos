import SwiftUI

struct CalendarOverviewCard: View {
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor
    @Environment(\.islandHUDContrastingColor) private var hudContrastingColor
    @StateObject private var calendarService = CalendarService.shared
    @State private var isCalendarPresented = false

    var body: some View {
        Button {
            isCalendarPresented = true
            calendarService.prepareForPresentation(month: Date())
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hudColor)
                    VStack(spacing: -2) {
                        Text(CalendarFormatting.shortMonth(Date()).uppercased())
                            .font(.system(size: 5.5, weight: .heavy))
                        Text("\(Calendar.autoupdatingCurrent.component(.day, from: Date()))")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(hudContrastingColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TAKVİM")
                        .font(.system(size: 7.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(textColor.opacity(0.38))
                    Text(previewTitle)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                    Text(previewDetail)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.42))
                        .lineLimit(1)
                }

                Spacer(minLength: 3)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(textColor.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ScaleButtonStyle())
        .help("Aylık takvimi ve yaklaşan etkinlikleri göster")
        .popover(isPresented: $isCalendarPresented, arrowEdge: .top) {
            CalendarPopoverView(calendarService: calendarService)
        }
        .onAppear {
            calendarService.refreshAuthorizationStatus()
            if calendarService.canReadEvents {
                calendarService.refresh(month: Date())
            }
        }
    }

    private var previewTitle: String {
        switch calendarService.accessState {
        case .notDetermined:
            return "Etkinliklerini göster"
        case .requesting:
            return "Takvim izni bekleniyor"
        case .writeOnly, .denied, .restricted:
            return "Takvim erişimi gerekli"
        case .fullAccess:
            return calendarService.nextEvent?.title ?? "Yaklaşan etkinlik yok"
        }
    }

    private var previewDetail: String {
        guard calendarService.accessState == .fullAccess else {
            return "Aylık görünüm ve yaklaşanlar"
        }
        guard let event = calendarService.nextEvent else {
            return CalendarFormatting.longDate(Date())
        }
        return CalendarFormatting.eventDate(event)
    }
}

private struct CalendarPopoverView: View {
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor
    @Environment(\.islandHUDContrastingColor) private var hudContrastingColor
    @ObservedObject var calendarService: CalendarService
    @State private var displayedMonth = Date()
    @State private var selectedDate = Date()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)

            Divider()
                .overlay(textColor.opacity(0.08))
                .padding(.top, 12)

            Group {
                if calendarService.canReadEvents {
                    calendarContent
                } else {
                    permissionContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 420, height: 500)
        .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        .preferredColorScheme(.dark)
        .onAppear {
            calendarService.prepareForPresentation(month: displayedMonth)
        }
    }

    private var popoverHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(hudColor)
                .frame(width: 31, height: 31)
                .background(hudColor.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Takvim")
                    .font(.system(size: 12, weight: .bold))
                Text("Aylık görünüm ve yaklaşan etkinlikler")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(textColor.opacity(0.42))
            }

            Spacer()

            Button("Bugün") {
                displayedMonth = Date()
                selectedDate = Date()
                calendarService.refresh(month: displayedMonth)
            }
            .font(.system(size: 9, weight: .bold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var calendarContent: some View {
        VStack(spacing: 11) {
            monthHeader

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(textColor.opacity(0.34))
                        .frame(maxWidth: .infinity)
                }

                ForEach(CalendarMonthLayout.days(containing: displayedMonth, calendar: calendar)) { day in
                    calendarDay(day)
                }
            }

            Divider().overlay(textColor.opacity(0.08))

            eventList
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay {
            if calendarService.isLoading && calendarService.events.isEmpty {
                ProgressView("Etkinlikler yükleniyor…")
                    .controlSize(.small)
                    .padding(14)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button(action: { moveMonth(by: -1) }) {
                Image(systemName: "chevron.left")
                    .frame(width: 25, height: 25)
                    .background(textColor.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(CalendarFormatting.monthAndYear(displayedMonth))
                .font(.system(size: 12, weight: .bold))

            Spacer()

            Button(action: { moveMonth(by: 1) }) {
                Image(systemName: "chevron.right")
                    .frame(width: 25, height: 25)
                    .background(textColor.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func calendarDay(_ day: CalendarMonthDay) -> some View {
        let isSelected = calendar.isDate(day.date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day.date)
        let hasEvents = calendarService.hasEvents(on: day.date, calendar: calendar)

        return Button {
            selectedDate = day.date
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day.date))")
                    .font(.system(size: 9.5, weight: isToday || isSelected ? .bold : .medium, design: .rounded))
                Circle()
                    .fill(hasEvents ? hudColor : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .foregroundStyle(isSelected ? hudContrastingColor : textColor.opacity(day.isInDisplayedMonth ? 0.86 : 0.24))
            .frame(maxWidth: .infinity, minHeight: 27)
            .background(isSelected ? hudColor : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hudColor.opacity(0.48), lineWidth: 0.8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(eventListTitle.uppercased())
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(textColor.opacity(0.38))
                Spacer()
                Button("Takvim’i Aç", action: calendarService.openCalendarApplication)
                    .font(.system(size: 8.5, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(textColor.opacity(0.62))
            }

            if visibleEvents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 18, weight: .medium))
                    Text("Yaklaşan etkinlik bulunmuyor.")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(textColor.opacity(0.36))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(visibleEvents) { event in
                            CalendarEventRow(event: event)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var permissionContent: some View {
        VStack(spacing: 13) {
            Image(systemName: permissionIcon)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(hudColor)
                .frame(width: 58, height: 58)
                .background(hudColor.opacity(0.09), in: Circle())

            Text(permissionTitle)
                .font(.system(size: 14, weight: .bold))

            Text(permissionDetail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(textColor.opacity(0.46))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            if calendarService.accessState == .notDetermined {
                Button("Takvim Erişimine İzin Ver") {
                    calendarService.requestAccess(month: displayedMonth)
                }
                .buttonStyle(.borderedProminent)
                .tint(hudColor)
                .foregroundStyle(hudContrastingColor)
            } else if calendarService.accessState == .requesting {
                ProgressView().controlSize(.small)
            } else {
                Button("Takvim İzinlerini Aç", action: calendarService.openCalendarPrivacySettings)
                    .buttonStyle(.bordered)
            }

            if let error = calendarService.errorMessage {
                Text(error)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(24)
    }

    private var selectedDayEvents: [CalendarEventItem] {
        let events = calendarService.events(on: selectedDate, calendar: calendar)
        guard calendar.isDateInToday(selectedDate) else { return events }
        let now = Date()
        return events.filter { $0.endDate > now }
    }

    private var visibleEvents: [CalendarEventItem] {
        let selected = selectedDayEvents
        return selected.isEmpty ? calendarService.upcomingEvents() : selected
    }

    private var eventListTitle: String {
        selectedDayEvents.isEmpty
            ? "Yaklaşan etkinlikler"
            : "\(CalendarFormatting.dayAndMonth(selectedDate)) etkinlikleri"
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let startIndex = max(0, min(6, calendar.firstWeekday - 1))
        return (0..<7).map { symbols[(startIndex + $0) % symbols.count] }
    }

    private var permissionIcon: String {
        calendarService.accessState == .requesting ? "calendar.badge.clock" : "calendar.badge.exclamationmark"
    }

    private var permissionTitle: String {
        switch calendarService.accessState {
        case .notDetermined:
            return "Takvimini Dynamic Island’da gör"
        case .requesting:
            return "Takvim izni bekleniyor"
        case .writeOnly:
            return "Tam takvim erişimi gerekli"
        case .denied:
            return "Takvim erişimi kapalı"
        case .restricted:
            return "Takvim erişimi kısıtlandı"
        case .fullAccess:
            return "Takvim hazır"
        }
    }

    private var permissionDetail: String {
        switch calendarService.accessState {
        case .notDetermined, .requesting:
            return "Aylık takvimi ve yaklaşan etkinlikleri göstermek için macOS Takvim erişimi gerekir."
        case .writeOnly:
            return "Yalnızca ekleme izni etkinlikleri okumaya yetmez. Sistem Ayarları’ndan tam erişim verin."
        case .denied, .restricted:
            return "Sistem Ayarları → Gizlilik ve Güvenlik → Takvimler bölümünden Dynamic Island’a izin verin."
        case .fullAccess:
            return ""
        }
    }

    private func moveMonth(by amount: Int) {
        guard let nextMonth = calendar.date(byAdding: .month, value: amount, to: displayedMonth) else { return }
        displayedMonth = nextMonth
        selectedDate = nextMonth
        calendarService.refresh(month: nextMonth)
    }
}

private struct CalendarEventRow: View {
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor
    let event: CalendarEventItem

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(hudColor)
                .frame(width: 3, height: 29)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text(event.calendarTitle)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(textColor.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(CalendarFormatting.eventDate(event))
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(textColor.opacity(0.52))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(textColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private enum CalendarFormatting {
    private static let locale = Locale(identifier: "tr_TR")

    static func shortMonth(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).month(.abbreviated))
    }

    static func monthAndYear(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).month(.wide).year())
    }

    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).day().month(.wide).weekday(.wide))
    }

    static func dayAndMonth(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).day().month(.wide))
    }

    static func eventDate(_ event: CalendarEventItem) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let dayLabel: String
        if calendar.isDateInToday(event.startDate) {
            dayLabel = "Bugün"
        } else if calendar.isDateInTomorrow(event.startDate) {
            dayLabel = "Yarın"
        } else {
            dayLabel = event.startDate.formatted(.dateTime.locale(locale).day().month(.abbreviated))
        }

        if event.isAllDay { return "\(dayLabel) · Tüm gün" }
        let time = event.startDate.formatted(.dateTime.locale(locale).hour().minute())
        return "\(dayLabel) · \(time)"
    }
}
