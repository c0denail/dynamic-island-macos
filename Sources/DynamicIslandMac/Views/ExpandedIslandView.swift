import SwiftUI

struct ExpandedIslandView: View {
    @EnvironmentObject private var island: IslandController

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
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 360)
                .background(.black.opacity(0.96), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.7))
                .padding(.top, max(35, island.notchHeight + 3))
                .contentShape(Capsule())
                .onTapGesture { island.activateNotification(notification) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: island.temporaryMessage)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(IslandPalette.primary.opacity(0.16))
                    Image(systemName: "capsule.inset.filled")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IslandPalette.primary)
                }
                .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Dynamic Island")
                        .font(.system(size: 12, weight: .bold))
                    Text("macOS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Spacer()

            Text(Date.now, style: .time)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.46))

            Button(action: island.collapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 27, height: 27)
                    .background(.white.opacity(0.08), in: Circle())
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
                    .foregroundStyle(island.selectedSection == section ? .black : .white.opacity(0.52))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(
                        island.selectedSection == section ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.clear),
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
        .background(.white.opacity(0.065), in: Capsule())
    }
}

private struct OverviewSection: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var media: MediaService
    @EnvironmentObject private var timer: TimerService
    @EnvironmentObject private var system: SystemStatusService

    var body: some View {
        HStack(spacing: 12) {
            MediaCard(compact: true)
                .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                Button {
                    island.open(.timer)
                } label: {
                    HStack(spacing: 10) {
                        ProgressRing(progress: timer.mode == .stopwatch ? nil : timer.progress, color: timerColor, size: 39) {
                            Image(systemName: timer.mode == .focus ? "moon.stars.fill" : "timer")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(timerColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timer.mode.rawValue)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.48))
                            Text(timer.displayedTime.islandClock)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.24))
                    }
                    .padding(12)
                    .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(ScaleButtonStyle())

                HStack(spacing: 8) {
                    QuickStatus(icon: system.isCharging ? "bolt.fill" : "battery.75percent", value: "\(system.batteryPercent)%", color: system.isCharging ? IslandPalette.primary : .white)
                    Button {
                        island.openSystemPanel(.wifi)
                    } label: {
                        QuickStatus(icon: system.isOnline ? "wifi" : "wifi.slash", value: system.networkLabel, color: system.isOnline ? IslandPalette.cyan : .red)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .frame(maxWidth: .infinity)
                    .help("Sistem Wi‑Fi ağlarını göster")
                }

                HStack(spacing: 8) {
                    QuickAction(icon: "doc.on.doc", title: "Özeti kopyala", color: IslandPalette.cyan, action: island.copySystemSummary)
                    QuickAction(icon: "moon.stars", title: "25 dk odak", color: IslandPalette.purple) {
                        timer.setPreset(minutes: 25, mode: .focus)
                        timer.start()
                        island.showMessage(icon: "moon.stars.fill", title: "Odak oturumu başladı", color: IslandPalette.purple)
                    }
                }
            }
            .frame(width: 268)
        }
    }

    private var timerColor: Color {
        timer.mode == .focus ? IslandPalette.purple : IslandPalette.orange
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

private struct QuickAction: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
