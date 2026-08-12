import SwiftUI

/// Re-renders only the small media progress subtree at display cadence. The
/// service can keep reconciling system state at its inexpensive 0.8 s poll,
/// while elapsed time and the bar advance smoothly from the local clock.
struct LiveMediaProgress<Content: View>: View {
    @EnvironmentObject private var media: MediaService
    private let content: (TimeInterval, TimeInterval, Double) -> Content

    init(@ViewBuilder content: @escaping (TimeInterval, TimeInterval, Double) -> Content) {
        self.content = content
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: IslandAnimationCadence.minimumInterval,
                paused: !media.isPlaying || media.duration <= 0
            )
        ) { _ in
            content(media.displayedElapsed, media.remaining, media.progress)
        }
    }
}

/// Uses the live dates already carried by Clock snapshots to animate the
/// visible countdown/stopwatch at up to 120 Hz without polling Clock 120 times
/// per second. Polling remains responsible only for external state changes.
struct LiveClockProgress<Content: View>: View {
    @EnvironmentObject private var clockTimer: ClockTimerService
    let mode: TimerMode
    let fallbackDuration: TimeInterval
    private let content: (TimeInterval, Double?) -> Content

    init(
        mode: TimerMode,
        fallbackDuration: TimeInterval,
        @ViewBuilder content: @escaping (TimeInterval, Double?) -> Content
    ) {
        self.mode = mode
        self.fallbackDuration = fallbackDuration
        self.content = content
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: IslandAnimationCadence.minimumInterval,
                paused: clockTimer.state(for: mode) != .running
            )
        ) { _ in
            content(
                clockTimer.displayedTime(for: mode, fallbackDuration: fallbackDuration),
                clockTimer.progress(for: mode)
            )
        }
    }
}

struct ArtworkGlyph: View {
    let size: CGFloat
    var url: URL? = nil
    var data: Data? = nil
    @Environment(\.islandHUDColor) private var hudColor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(hudColor.opacity(0.12))

            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            } else if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.26, weight: .bold))
                    .foregroundStyle(hudColor.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

struct NotificationAppGlyph: View {
    let data: Data?
    let size: CGFloat
    @Environment(\.islandHUDColor) private var hudColor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(hudColor.opacity(0.12))
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "bell.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(hudColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct MiniWaveform: View {
    let isActive: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: isActive ? IslandAnimationCadence.minimumInterval : 1)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<9, id: \.self) { index in
                    let oscillation = abs(sin(phase * 5 + Double(index) * 0.82))
                    Capsule()
                        .fill(color.opacity(0.58 + Double(index % 3) * 0.14))
                        .frame(width: 2, height: isActive ? 4 + oscillation * 15 : 4 + Double(index % 3) * 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProgressRing<Content: View>: View {
    let progress: Double?
    let color: Color
    let size: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.islandHUDColor) private var hudColor

    var body: some View {
        ZStack {
            Circle()
                .stroke(hudColor.opacity(0.14), lineWidth: max(3, size * 0.055))
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.015, 1 - progress))
                    .stroke(color, style: StrokeStyle(lineWidth: max(3, size * 0.055), lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0.04, to: 0.78)
                    .stroke(color, style: StrokeStyle(lineWidth: max(3, size * 0.055), lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            content()
        }
        .frame(width: size, height: size)
    }
}

struct SmallMediaButton: View {
    let icon: String
    var size: CGFloat = 29
    let action: () -> Void
    @Environment(\.islandTextColor) private var textColor

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.35, weight: .bold))
                .frame(width: size, height: size)
                .background(textColor.opacity(0.075), in: Circle())
                .foregroundStyle(textColor.opacity(0.8))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
    }
}
