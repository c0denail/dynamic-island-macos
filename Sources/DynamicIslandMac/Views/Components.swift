import SwiftUI

struct ArtworkGlyph: View {
    let size: CGFloat
    var url: URL? = nil
    var data: Data? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(.white.opacity(0.12))

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
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

struct NotificationAppGlyph: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(.white.opacity(0.12))
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "bell.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
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
        TimelineView(.animation(minimumInterval: isActive ? 1.0 / 60.0 : 1)) { context in
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

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.09), lineWidth: max(3, size * 0.055))
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.015, 1 - progress))
                    .stroke(color, style: StrokeStyle(lineWidth: max(3, size * 0.055), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: progress)
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

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.35, weight: .bold))
                .frame(width: size, height: size)
                .background(.white.opacity(0.075), in: Circle())
                .foregroundStyle(.white.opacity(0.8))
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
