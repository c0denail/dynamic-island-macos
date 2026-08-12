import SwiftUI

struct TimerSection: View {
    @EnvironmentObject private var timer: TimerService
    @EnvironmentObject private var clockTimer: ClockTimerService
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor
    @Environment(\.islandHUDContrastingColor) private var hudContrastingColor

    var body: some View {
        VStack(spacing: 10) {
            synchronizationHeader
            timerControls

            if !clockTimer.isAccessibilityTrusted {
                HStack(spacing: 10) {
                    Image(systemName: "figure.wave.circle.fill")
                    Text("Saat denetimi için Dynamic Island’ın Erişilebilirlik iznini yenileyin.")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("İzni Yenile") { clockTimer.requestAccessibilityAccess() }
                        .font(.system(size: 9, weight: .bold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .foregroundStyle(.orange)
            }

            if let error = clockTimer.lastError {
                Text(error)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var synchronizationHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: timer.mode == .stopwatch ? "stopwatch.fill" : "clock.fill")
                .foregroundStyle(timerColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("macOS Saat ile canlı")
                    .font(.system(size: 10, weight: .bold))
                Text(activityDetail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(textColor.opacity(0.42))
                    .lineLimit(1)
            }

            Spacer()

            if clockTimer.isActive(timer.mode) {
                Text(clockTimer.displayedTime(for: timer.mode, fallbackDuration: timer.duration).islandClock)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(timerColor)
            }

            Button("Saat'te Aç") { clockTimer.openClock(mode: timer.mode) }
                .font(.system(size: 9, weight: .bold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(timerColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var timerControls: some View {
        HStack(spacing: 18) {
            VStack(spacing: 10) {
                Picker("Tür", selection: $timer.mode) {
                    ForEach(TimerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if timer.mode == .countdown {
                    HStack(spacing: 8) {
                        PresetButton(title: "5 dk", selected: timer.duration == 300) { timer.setPreset(minutes: 5) }
                        PresetButton(title: "15 dk", selected: timer.duration == 900) { timer.setPreset(minutes: 15) }
                        PresetButton(title: "25 dk", selected: timer.duration == 1500) { timer.setPreset(minutes: 25) }
                        PresetButton(title: "45 dk", selected: timer.duration == 2700) { timer.setPreset(minutes: 45) }
                    }
                    .disabled(clockTimer.current != nil)

                    Text(clockTimer.current == nil ? "Başlatınca sayaç macOS Saat uygulamasında oluşturulur." : "Sayaç Clock’tan canlı okunuyor; süreyi değiştirmek için önce sıfırlayın.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.38))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Başlat, durdur ve sıfırla işlemleri doğrudan macOS Saat kronometresiyle eşitlenir.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.38))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)

            ProgressRing(progress: clockTimer.progress(for: timer.mode), color: timerColor, size: 146) {
                VStack(spacing: 4) {
                    Image(systemName: timer.mode == .stopwatch ? "stopwatch.fill" : "timer")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(timerColor)
                    Text(clockTimer.displayedTime(for: timer.mode, fallbackDuration: timer.duration).islandClock)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            VStack(spacing: 10) {
                Button {
                    clockTimer.toggle(mode: timer.mode, duration: timer.duration)
                } label: {
                    HStack(spacing: 6) {
                        if clockTimer.isPerformingAction {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: primaryIcon)
                        }
                        Text(primaryTitle)
                    }
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(timerColor, in: Capsule())
                    .foregroundStyle(hudContrastingColor)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(clockTimer.isPerformingAction)

                Button {
                    clockTimer.reset(mode: timer.mode)
                } label: {
                    Label("Sıfırla", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(textColor.opacity(0.09), in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(!clockTimer.isActive(timer.mode) || clockTimer.isPerformingAction)
            }
            .frame(width: 112)
        }
    }

    private var activityDetail: String {
        guard clockTimer.isActive(timer.mode) else {
            return timer.mode == .stopwatch ? "Saat kronometresi hazır" : "Seçilen süre: \(timer.duration.islandClock)"
        }
        let status = clockTimer.state(for: timer.mode) == .running ? "Çalışıyor" : "Duraklatıldı"
        if timer.mode == .countdown, let current = clockTimer.current {
            return "\(current.title) · \(status)"
        }
        return "Saat Kronometresi · \(status)"
    }

    private var primaryTitle: String {
        switch clockTimer.state(for: timer.mode) {
        case .running: "Duraklat"
        case .paused: "Devam Et"
        case .stopped: "Başlat"
        }
    }

    private var primaryIcon: String {
        switch clockTimer.state(for: timer.mode) {
        case .running: "pause.fill"
        case .paused, .stopped: "play.fill"
        }
    }

    private var timerColor: Color {
        hudColor
    }
}

private struct PresetButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.islandHUDColor) private var hudColor
    @Environment(\.islandTextColor) private var textColor
    @Environment(\.islandHUDContrastingColor) private var hudContrastingColor

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? hudColor : textColor.opacity(0.07), in: Capsule())
                .foregroundStyle(selected ? hudContrastingColor : textColor.opacity(0.55))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
