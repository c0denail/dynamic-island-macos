import SwiftUI

struct MiniIslandView: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var media: MediaService
    @EnvironmentObject private var timer: TimerService
    @EnvironmentObject private var clockTimer: ClockTimerService
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor

    var body: some View {
        HStack(spacing: 10) {
            leadingStatus
            Spacer(minLength: 72)
            trailingStatus
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fontDesign(.rounded)
    }

    @ViewBuilder
    private var leadingStatus: some View {
        switch island.compactActivity {
        case .media:
            ArtworkGlyph(size: 24)
        case .timer:
            statusGlyph(activityMode == .stopwatch ? "stopwatch.fill" : "timer", color: hudColor)
        case let .volume(_, isMuted):
            statusGlyph(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", color: hudColor)
        case let .brightness(value):
            statusGlyph(value < 0.34 ? "sun.min.fill" : "sun.max.fill", color: hudColor)
        case let .hardware(activity):
            HardwareActivityGlyph(activity: activity, size: 24)
        case let .notification(notification):
            NotificationAppGlyph(data: notification.appIconData, size: 24)
        case let .message(icon, _, color):
            statusGlyph(icon, color: color)
        case .idle:
            HStack(spacing: 3) {
                Circle().fill(hudColor).frame(width: 5, height: 5)
                Circle().fill(hudColor.opacity(0.55)).frame(width: 5, height: 5)
            }
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch island.compactActivity {
        case .media:
            MiniWaveform(isActive: media.isPlaying, color: hudColor)
                .frame(width: 28, height: 18)
        case .timer:
            LiveClockProgress(mode: activityMode, fallbackDuration: timer.duration) { displayedTime, _ in
                Text(displayedTime.islandClock)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
            }
        case let .volume(value, _):
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
        case let .brightness(value):
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
        case let .hardware(activity):
            if let percentage = activity.battery?.preferred {
                Text("\(percentage)%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
            } else {
                Text(activity.isConnected == false ? "Ayrıldı" : (activity.kind.isStorage ? "Disk" : "Bağlı"))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(textColor)
            }
        case let .notification(notification):
            Text(notification.displayTitle)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(textColor)
                .lineLimit(1)
        case let .message(_, title, color):
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(textColor.opacity(0.55))
        }
    }

    private func statusGlyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(color.opacity(0.14), in: Circle())
    }

    private var activityMode: TimerMode {
        clockTimer.presentationMode(preferred: timer.mode)
    }
}
