import SwiftUI

struct MediaSection: View {
    var body: some View {
        MediaCard(compact: false)
    }
}

struct MediaCard: View {
    @EnvironmentObject private var media: MediaService
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 13 : 16) {
            HStack(spacing: 14) {
                ArtworkGlyph(size: compact ? 66 : 78, url: media.artworkURL, data: media.artworkData)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(media.source.isEmpty ? "ŞİMDİ ÇALAN" : media.source.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(IslandPalette.primary)
                        Spacer()
                        if !media.source.isEmpty {
                            Circle()
                                .fill(media.isPlaying ? IslandPalette.primary : .white.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text(media.title)
                        .font(.system(size: compact ? 16 : 20, weight: .bold))
                        .lineLimit(1)
                    Text(media.artist)
                        .font(.system(size: compact ? 10 : 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)

                    if !compact {
                        MiniWaveform(isActive: media.isPlaying, color: IslandPalette.primary)
                            .frame(height: 20)
                            .padding(.top, 4)
                    }
                }
            }

            VStack(spacing: 5) {
                Slider(
                    value: Binding(
                        get: { media.progress },
                        set: { media.seek(to: $0) }
                    ),
                    in: 0...1
                )
                .tint(IslandPalette.primary)
                .controlSize(.mini)

                HStack {
                    Text(media.displayedElapsed.islandClock)
                    Spacer()
                    Text("−\(media.remaining.islandClock)")
                }
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            }

            HStack(spacing: compact ? 13 : 18) {
                if !compact {
                    SmallMediaButton(icon: "gobackward.15") { media.seek(by: -15) }
                }
                SmallMediaButton(icon: "backward.fill", size: compact ? 34 : 39, action: media.previous)
                Button(action: media.playPause) {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 16 : 19, weight: .bold))
                        .frame(width: compact ? 42 : 49, height: compact ? 42 : 49)
                        .background(.white, in: Circle())
                        .foregroundStyle(.black)
                }
                .buttonStyle(ScaleButtonStyle())
                SmallMediaButton(icon: "forward.fill", size: compact ? 34 : 39, action: media.next)
                if !compact {
                    SmallMediaButton(icon: "goforward.15") { media.seek(by: 15) }
                }
            }
        }
        .padding(compact ? 16 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [IslandPalette.primary.opacity(0.105), IslandPalette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}
