import SwiftUI

struct ExpandedIslandView: View {
    @EnvironmentObject private var island: IslandController
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor
    @Environment(\.islandHUDContrastingColor) private var hudContrastingColor

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, max(34, island.notchHeight + 6))

            sectionPicker
                .padding(.horizontal, 20)
                .padding(.top, 12)

            Group {
                switch island.selectedSection {
                case .overview: OverviewSection()
                case .media: MediaSection()
                case .timer: TimerSection()
                case .system: SystemSection()
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .padding(20)
        }
        .fontDesign(.rounded)
        .overlay(alignment: .top) {
            if case let .notification(notification) = island.temporaryMessage {
                HStack(spacing: 9) {
                    NotificationAppGlyph(data: notification.appIconData, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notification.displayTitle)
                            .font(.system(size: 10, weight: .bold))
                        Text(notification.displayDetail.isEmpty ? notification.appName : notification.displayDetail)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(textColor.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(textColor.opacity(0.35))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 360)
                .background(.black.opacity(0.96), in: Capsule())
                .overlay(Capsule().stroke(textColor.opacity(0.12), lineWidth: 0.7))
                .padding(.top, max(35, island.notchHeight + 3))
                .contentShape(Capsule())
                .onTapGesture { island.activateNotification(notification) }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if case let .hardware(activity) = island.temporaryMessage {
                HardwareActivityBanner(activity: activity)
                    .padding(.top, max(35, island.notchHeight + 3))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: island.temporaryMessage)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(hudColor.opacity(0.16))
                    Image(systemName: "capsule.inset.filled")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(hudColor)
                }
                .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Dynamic Island")
                        .font(.system(size: 12, weight: .bold))
                    Text("macOS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.4))
                }
            }

            Spacer()

            Text(Date.now, style: .time)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(textColor.opacity(0.46))

            Button(action: island.collapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 27, height: 27)
                    .background(textColor.opacity(0.08), in: Circle())
            }
            .buttonStyle(ScaleButtonStyle())
            .help("Adayı küçült")
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(IslandSection.allCases) { section in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        island.selectedSection = section
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.icon)
                        Text(section.rawValue)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(island.selectedSection == section ? hudContrastingColor : textColor.opacity(0.52))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(
                        island.selectedSection == section ? AnyShapeStyle(hudColor) : AnyShapeStyle(Color.clear),
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
            }
        }
        .padding(4)
        .background(textColor.opacity(0.065), in: Capsule())
    }
}

private struct OverviewSection: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var media: MediaService
    @EnvironmentObject private var timer: TimerService
    @EnvironmentObject private var clockTimer: ClockTimerService
    @EnvironmentObject private var system: SystemStatusService
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor

    var body: some View {
        HStack(spacing: 12) {
            MediaCard(compact: true)
                .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                Button {
                    island.open(.timer)
                } label: {
                    LiveClockProgress(mode: activityMode, fallbackDuration: timer.duration) { displayedTime, progress in
                        HStack(spacing: 10) {
                            ProgressRing(progress: progress, color: timerColor, size: 39) {
                                Image(systemName: activityMode == .stopwatch ? "stopwatch.fill" : "timer")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(timerColor)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activityMode.rawValue)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(textColor.opacity(0.48))
                                Text(displayedTime.islandClock)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(textColor.opacity(0.24))
                        }
                        .padding(12)
                        .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .buttonStyle(ScaleButtonStyle())

                HStack(spacing: 8) {
                    QuickStatus(icon: system.isCharging ? "bolt.fill" : "battery.75percent", value: "\(system.batteryPercent)%", color: hudColor)
                    Button {
                        island.openSystemPanel(.wifi)
                    } label: {
                        QuickStatus(icon: system.isOnline ? "wifi" : "wifi.slash", value: system.networkLabel, color: system.isOnline ? hudColor : .red)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .frame(maxWidth: .infinity)
                    .help("Sistem Wi‑Fi ağlarını göster")
                }

                CalendarOverviewCard()
            }
            .frame(width: 268)
        }
    }

    private var timerColor: Color {
        hudColor
    }

    private var activityMode: TimerMode {
        clockTimer.presentationMode(preferred: timer.mode)
    }
}

private struct QuickStatus: View {
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).lineLimit(1)
        }
        .font(.system(size: 9, weight: .bold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
