import SwiftUI

struct CompactIslandView: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var media: MediaService
    @EnvironmentObject private var timer: TimerService
    @EnvironmentObject private var clockTimer: ClockTimerService
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor

    var body: some View {
        GeometryReader { proxy in
            let centerWidth = min(island.notchWidth + 10, proxy.size.width - 220)

            HStack(spacing: 0) {
                leftWing
                    .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: centerWidth)

                rightWing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 13)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .fontDesign(.rounded)
    }

    @ViewBuilder
    private var leftWing: some View {
        switch island.compactActivity {
        case .media:
            HStack(spacing: 7) {
                ArtworkGlyph(size: 27, url: media.artworkURL, data: media.artworkData)
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(textColor)
                    Text(media.artist)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.48))
                }
                .lineLimit(1)
            }
        case .timer:
            statusLabel(
                icon: activityMode == .stopwatch ? "stopwatch.fill" : "timer",
                title: activityMode.rawValue,
                subtitle: clockTimer.state(for: activityMode) == .running ? "macOS Saat · Çalışıyor" : "macOS Saat · Duraklatıldı"
            )
        case let .volume(value, isMuted):
            HStack(spacing: 8) {
                Image(systemName: volumeIcon(value: value, isMuted: isMuted))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hudColor)
                Text(isMuted ? "Kapalı" : "%\(Int((value * 100).rounded()))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
            }
        case let .brightness(value):
            HStack(spacing: 8) {
                Image(systemName: brightnessIcon(value: value))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hudColor)
                Text("%\(Int((value * 100).rounded()))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
            }
        case let .notification(notification):
            HStack(spacing: 7) {
                NotificationAppGlyph(data: notification.appIconData, size: 27)
                VStack(alignment: .leading, spacing: 1) {
                    Text(notification.displayTitle)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(textColor)
                    Text(notification.appName)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.48))
                }
                .lineLimit(1)
            }
        case let .message(icon, title, _):
            statusLabel(icon: icon, title: title, subtitle: "Dynamic Island")
        case .idle:
            statusLabel(icon: "capsule.inset.filled", title: "Dynamic Island", subtitle: "macOS")
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        switch island.compactActivity {
        case .media:
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    Text(media.displayedElapsed.islandClock)
                    Text("−\(media.remaining.islandClock)")
                        .foregroundStyle(textColor.opacity(0.42))
                }
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .monospacedDigit()

                whiteProgress(media.progress)
            }
        case .timer:
            VStack(alignment: .trailing, spacing: 4) {
                Text(clockTimer.displayedTime(for: activityMode, fallbackDuration: timer.duration).islandClock)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                whiteProgress(clockTimer.progress(for: activityMode) ?? 1)
            }
        case let .volume(value, isMuted):
            VStack(alignment: .trailing, spacing: 4) {
                Text(isMuted ? "SES KAPALI" : "SES DÜZEYİ")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(textColor.opacity(0.48))
                whiteProgress(isMuted ? 0 : Double(value))
            }
        case let .brightness(value):
            VStack(alignment: .trailing, spacing: 4) {
                Text("EKRAN PARLAKLIĞI")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(textColor.opacity(0.48))
                whiteProgress(Double(value))
            }
        case let .notification(notification):
            HStack(spacing: 7) {
                Text(notification.displayDetail.isEmpty ? "Yeni bildirim" : notification.displayDetail)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.72))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 116, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(textColor.opacity(0.35))
            }
        case .message:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(hudColor)
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Image(systemName: "music.note")
                Image(systemName: "timer")
                Image(systemName: "macbook")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(textColor.opacity(0.55))
        }
    }

    private func statusLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hudColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(textColor)
                Text(subtitle)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.44))
            }
            .lineLimit(1)
        }
    }

    private var activityMode: TimerMode {
        clockTimer.presentationMode(preferred: timer.mode)
    }

    private func whiteProgress(_ progress: Double) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(hudColor.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(hudColor)
                        .frame(width: progress > 0 ? max(3, proxy.size.width * min(1, max(0, progress))) : 0)
                }
        }
        .frame(width: 115, height: 4)
    }

    private func volumeIcon(value: Float, isMuted: Bool) -> String {
        if isMuted || value == 0 { return "speaker.slash.fill" }
        if value < 0.34 { return "speaker.wave.1.fill" }
        if value < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func brightnessIcon(value: Float) -> String {
        value < 0.34 ? "sun.min.fill" : "sun.max.fill"
    }
}
