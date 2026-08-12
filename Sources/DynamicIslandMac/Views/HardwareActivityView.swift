import Foundation
import SwiftUI

struct HardwareActivityGlyph: View {
    let activity: IslandHardwareActivity
    var size: CGFloat = 28

    @Environment(\.islandHUDColor) private var hudColor

    var body: some View {
        TimelineView(.animation(minimumInterval: IslandAnimationCadence.minimumInterval)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(hudColor.opacity(0.14))

                animatedRing(phase: phase)

                Image(systemName: activity.kind.iconName)
                    .font(.system(size: size * 0.43, weight: .bold))
                    .foregroundStyle(hudColor)
                    .scaleEffect(iconScale(phase: phase))
                    .offset(y: iconOffset(phase: phase))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func animatedRing(phase: TimeInterval) -> some View {
        switch activity.kind {
        case .charging:
            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(hudColor.opacity(0.88), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(phase * 150))
                .padding(2)
        case .airPods, .airPodsMax, .headphones:
            ForEach(0..<2, id: \.self) { index in
                let wave = (sin(phase * 4.8 - Double(index) * 1.2) + 1) / 2
                Circle()
                    .stroke(hudColor.opacity(0.08 + wave * 0.15), lineWidth: 1)
                    .scaleEffect(0.76 + wave * 0.24)
                    .padding(CGFloat(index) * 1.8)
            }
        case .storageConnected:
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(hudColor.opacity(0.82), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(-phase * 125))
                .padding(2)
        case .powerConnected, .powerDisconnected, .storageDisconnected:
            Circle()
                .stroke(hudColor.opacity(0.2), lineWidth: 1)
                .padding(2)
        }
    }

    private func iconScale(phase: TimeInterval) -> CGFloat {
        switch activity.kind {
        case .charging:
            0.94 + CGFloat((sin(phase * 5.2) + 1) * 0.04)
        case .airPods, .airPodsMax, .headphones:
            0.97 + CGFloat((sin(phase * 3.8) + 1) * 0.025)
        case .storageConnected:
            0.96 + CGFloat((sin(phase * 4.2) + 1) * 0.025)
        case .powerConnected, .powerDisconnected, .storageDisconnected:
            1
        }
    }

    private func iconOffset(phase: TimeInterval) -> CGFloat {
        activity.kind == .storageConnected ? CGFloat(sin(phase * 4.2)) * 0.55 : 0
    }
}

struct HardwareActivityStatusView: View {
    let activity: IslandHardwareActivity
    var compact = true

    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: compact ? 4 : 3) {
            HStack(spacing: 6) {
                Text(statusTitle)
                    .font(.system(size: compact ? 7 : 8, weight: .bold))
                    .tracking(compact ? 0.75 : 0.45)
                    .foregroundStyle(textColor.opacity(0.5))

                if let percentage = activity.battery?.preferred {
                    Text("%\(percentage)")
                        .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(textColor)
                }
            }

            if shouldShowBatteryDetails {
                HStack(spacing: 7) {
                    batteryDetail("L", activity.battery?.left)
                    batteryDetail("R", activity.battery?.right)
                    batteryDetail("K", activity.battery?.caseLevel)
                }
            } else if let progress = activity.progress, activity.kind != .storageDisconnected {
                progressBar(progress)
            } else {
                connectionDots
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                revealed = true
            }
        }
        .onChange(of: activity.id) { _, _ in
            revealed = false
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                revealed = true
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: activity.progress)
    }

    private var shouldShowBatteryDetails: Bool {
        guard activity.kind.isAudioAccessory, let battery = activity.battery else { return false }
        return [battery.left, battery.right, battery.caseLevel].compactMap { $0 }.count >= 2
    }

    private var statusTitle: String {
        if activity.kind.isAudioAccessory, activity.isConnected == false { return "BAĞLANTI KESİLDİ" }
        return switch activity.kind {
        case .charging: "ŞARJ OLUYOR"
        case .powerConnected: "GÜÇ BAĞLANDI"
        case .powerDisconnected: "PİL KULLANILIYOR"
        case .airPods, .airPodsMax, .headphones: "BAĞLANDI"
        case .storageConnected: capacityText ?? "DEPOLAMA BAĞLANDI"
        case .storageDisconnected: "BAĞLANTI KESİLDİ"
        }
    }

    private var capacityText: String? {
        guard let total = activity.totalCapacity, total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file).uppercased()
    }

    private func batteryDetail(_ label: String, _ value: Int?) -> some View {
        Group {
            if let value {
                Text("\(label) %\(value)")
            }
        }
        .font(.system(size: compact ? 7 : 8, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(textColor.opacity(0.72))
    }

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(hudColor.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(hudColor)
                        .frame(width: revealed ? max(3, proxy.size.width * min(1, max(0, progress))) : 3)
                }
        }
        .frame(width: compact ? 115 : 86, height: 4)
    }

    private var connectionDots: some View {
        TimelineView(.animation(minimumInterval: IslandAnimationCadence.minimumInterval)) { timeline in
            let active = Int(timeline.date.timeIntervalSinceReferenceDate * 5) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(hudColor.opacity(index == active ? 1 : 0.22))
                        .frame(width: 3.5, height: 3.5)
                }
            }
            .frame(width: compact ? 115 : 86, alignment: .trailing)
        }
    }
}

struct HardwareActivityBanner: View {
    let activity: IslandHardwareActivity

    @EnvironmentObject private var island: IslandController
    @Environment(\.islandTextColor) private var textColor

    var body: some View {
        HStack(spacing: 9) {
            HardwareActivityGlyph(activity: activity, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title)
                    .font(.system(size: 10, weight: .bold))
                Text(activity.subtitle)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            HardwareActivityStatusView(activity: activity, compact: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 390)
        .background(.black.opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(textColor.opacity(0.12), lineWidth: 0.7))
        .contentShape(Capsule())
        .onTapGesture { island.activateHardwareActivity(activity) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.title), \(activity.subtitle)")
    }
}
