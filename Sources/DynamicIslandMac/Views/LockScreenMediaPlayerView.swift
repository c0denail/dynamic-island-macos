import SwiftUI

/// A glass media card intended for the lock-screen presentation window.
///
/// The window/coordinator owns placement and visibility. Keeping the view free
/// of AppKit window policy also makes the same presentation reusable as a
/// preferences preview.
struct LockScreenMediaPlayerView: View {
    @EnvironmentObject private var media: MediaService
    @EnvironmentObject private var theme: IslandTheme

    let isPreview: Bool
    let dismissPreview: (() -> Void)?

    init(isPreview: Bool = false, dismissPreview: (() -> Void)? = nil) {
        self.isPreview = isPreview
        self.dismissPreview = dismissPreview
    }

    var body: some View {
        VStack(spacing: 15) {
            nowPlayingHeader

            LiveMediaProgress { elapsed, remaining, progress in
                VStack(spacing: 6) {
                    LockScreenMediaScrubber(
                        progress: progress,
                        elapsed: elapsed,
                        remaining: remaining,
                        isEnabled: media.duration > 0,
                        accentColor: theme.hudColor,
                        textColor: theme.textColor,
                        onCommit: media.seek(to:)
                    )
                }
            }

            playbackControls
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 21)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.textColor)
        .background(cardBackground)
        .clipShape(cardShape)
        .overlay(cardShape.stroke(theme.textColor.opacity(0.16), lineWidth: 0.8))
        .environment(\.islandHUDColor, theme.hudColor)
        .environment(\.islandTextColor, theme.textColor)
        .environment(\.islandHUDContrastingColor, theme.hudContrastingColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kilit ekranı medya oynatıcısı")
    }

    private var nowPlayingHeader: some View {
        HStack(spacing: 17) {
            ArtworkGlyph(size: 82, url: media.artworkURL, data: media.artworkData)
                .overlay(
                    RoundedRectangle(cornerRadius: 20.5, style: .continuous)
                        .stroke(theme.textColor.opacity(0.16), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(media.title)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(media.artist)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textColor.opacity(0.64))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !media.source.isEmpty {
                    Text(media.source.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(theme.textColor.opacity(0.42))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(mediaAccessibilityLabel)

            trailingHeaderControl
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var trailingHeaderControl: some View {
        if isPreview, let dismissPreview {
            Button(action: dismissPreview) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(theme.textColor.opacity(0.09), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(ScaleButtonStyle())
            .foregroundStyle(theme.textColor.opacity(0.72))
            .accessibilityLabel("Önizlemeyi kapat")
        } else {
            MiniWaveform(isActive: media.isPlaying, color: theme.hudColor)
                .frame(width: 31, height: 23)
                .accessibilityHidden(true)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 21) {
            LockScreenMediaControlButton(
                icon: "gobackward.15",
                label: "15 saniye geri sar",
                textColor: theme.textColor,
                action: { media.seek(by: -15) }
            )

            LockScreenMediaControlButton(
                icon: "backward.fill",
                label: "Önceki medya",
                iconSize: 24,
                textColor: theme.textColor,
                action: media.previous
            )

            Button(action: media.playPause) {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 35, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 57, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScaleButtonStyle())
            .foregroundStyle(theme.hudColor)
            .accessibilityLabel(media.isPlaying ? "Duraklat" : "Oynat")

            LockScreenMediaControlButton(
                icon: "forward.fill",
                label: "Sonraki medya",
                iconSize: 24,
                textColor: theme.textColor,
                action: media.next
            )

            LockScreenMediaControlButton(
                icon: "goforward.15",
                label: "15 saniye ileri sar",
                textColor: theme.textColor,
                action: { media.seek(by: 15) }
            )
        }
        .frame(maxWidth: .infinity)
        .disabled(!media.hasActiveSource)
        .opacity(media.hasActiveSource ? 1 : 0.44)
    }

    private var mediaAccessibilityLabel: String {
        guard media.hasActiveSource else { return "Çalan medya yok" }
        let source = media.source.isEmpty ? "" : ", \(media.source)"
        return "\(media.title), \(media.artist)\(source)"
    }

    private var cardBackground: some View {
        ZStack {
            cardShape.fill(.ultraThinMaterial)
            cardShape.fill(Color.black.opacity(0.4))
            cardShape.fill(
                LinearGradient(
                    colors: [
                        theme.hudColor.opacity(0.09),
                        theme.hudColor.opacity(0.025),
                        Color.black.opacity(0.13)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 31, style: .continuous)
    }
}

private struct LockScreenMediaScrubber: View {
    let progress: Double
    let elapsed: TimeInterval
    let remaining: TimeInterval
    let isEnabled: Bool
    let accentColor: Color
    let textColor: Color
    let onCommit: (Double) -> Void

    @State private var draggedProgress: Double?
    @State private var isHovering = false

    private var visibleProgress: Double {
        min(1, max(0, draggedProgress ?? progress))
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let trackHeight: CGFloat = isHovering || draggedProgress != nil ? 7 : 5

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(textColor.opacity(0.22))
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(accentColor.opacity(isEnabled ? 0.96 : 0.32))
                        .frame(width: max(trackHeight, width * visibleProgress), height: trackHeight)

                    if isEnabled, isHovering || draggedProgress != nil {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 11, height: 11)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            .offset(x: max(0, min(width - 11, width * visibleProgress - 5.5)))
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isEnabled else { return }
                            draggedProgress = min(1, max(0, value.location.x / width))
                        }
                        .onEnded { value in
                            guard isEnabled else { return }
                            let finalProgress = min(1, max(0, value.location.x / width))
                            onCommit(finalProgress)
                            draggedProgress = nil
                        }
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .frame(height: 15)

            HStack {
                Text(elapsed.islandClock)
                Spacer()
                Text("−\(remaining.islandClock)")
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(textColor.opacity(0.56))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Medya ilerleme çubuğu")
        .accessibilityValue("\(elapsed.islandClock) geçti, \(remaining.islandClock) kaldı")
        .accessibilityAddTraits(isEnabled ? [] : .isStaticText)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment:
                onCommit(min(1, progress + 0.05))
            case .decrement:
                onCommit(max(0, progress - 0.05))
            @unknown default:
                break
            }
        }
    }
}

private struct LockScreenMediaControlButton: View {
    let icon: String
    let label: String
    var iconSize: CGFloat = 20
    let textColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: 43, height: 43)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .foregroundStyle(textColor.opacity(0.88))
        .accessibilityLabel(label)
    }
}
