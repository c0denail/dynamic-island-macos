import SwiftUI

struct MiniIslandView: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var media: MediaService
    @EnvironmentObject private var timer: TimerService
    @EnvironmentObject private var clockTimer: ClockTimerService

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
            statusGlyph(activityMode == .stopwatch ? "stopwatch.fill" : "timer", color: timerColor)
        case let .volume(_, isMuted):
            statusGlyph(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", color: IslandPalette.cyan)
        case let .brightness(value):
            statusGlyph(value < 0.34 ? "sun.min.fill" : "sun.max.fill", color: .white)
        case let .notification(notification):
            NotificationAppGlyph(data: notification.appIconData, size: 24)
        case let .message(icon, _, color):
            statusGlyph(icon, color: color)
        case .idle:
            HStack(spacing: 3) {
                Circle().fill(IslandPalette.primary).frame(width: 5, height: 5)
                Circle().fill(IslandPalette.cyan).frame(width: 5, height: 5)
            }
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch island.compactActivity {
        case .media:
            MiniWaveform(isActive: media.isPlaying, color: IslandPalette.primary)
                .frame(width: 28, height: 18)
        case .timer:
            Text(clockTimer.displayedTime(for: activityMode, fallbackDuration: timer.duration).islandClock)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timerColor)
        case let .volume(value, _):
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(IslandPalette.cyan)
        case let .brightness(value):
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        case let .notification(notification):
            Text(notification.displayTitle)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        case let .message(_, title, color):
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func statusGlyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(color.opacity(0.14), in: Circle())
    }

    private var timerColor: Color {
        activityMode == .stopwatch ? IslandPalette.cyan : IslandPalette.orange
    }

    private var activityMode: TimerMode {
        clockTimer.presentationMode(preferred: timer.mode)
    }
}
