import SwiftUI

struct TimerSection: View {
    @EnvironmentObject private var timer: TimerService
    @EnvironmentObject private var clockTimer: ClockTimerService

    var body: some View {
        VStack(spacing: 10) {
            if let nativeTimer = clockTimer.current {
                HStack(spacing: 10) {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(IslandPalette.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("macOS Saat ile canlı senkron")
                            .font(.system(size: 10, weight: .bold))
                        Text(nativeTimer.title)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    Spacer()
                    Text(nativeTimer.remaining.islandClock)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(IslandPalette.orange)
                    Button("Saat'te Aç", action: clockTimer.openClock)
                        .font(.system(size: 9, weight: .bold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(IslandPalette.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            timerControls
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                .onChange(of: timer.mode) { _, _ in timer.reset() }

                HStack(spacing: 8) {
                    PresetButton(title: "5 dk", selected: timer.duration == 300) { timer.setPreset(minutes: 5) }
                    PresetButton(title: "15 dk", selected: timer.duration == 900) { timer.setPreset(minutes: 15) }
                    PresetButton(title: "25 dk", selected: timer.duration == 1500) { timer.setPreset(minutes: 25) }
                    PresetButton(title: "45 dk", selected: timer.duration == 2700) { timer.setPreset(minutes: 45) }
                }

                Text(timer.mode == .stopwatch ? "Tur yerine sıfırla ile yeni bir ölçüm başlatın." : "Sayaç bittiğinde ses ve macOS bildirimi alırsınız.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            ZStack {
                ProgressRing(progress: timer.mode == .stopwatch ? nil : timer.progress, color: timerColor, size: 146) {
                    VStack(spacing: 4) {
                        Image(systemName: timer.mode == .focus ? "moon.stars.fill" : timer.mode == .stopwatch ? "stopwatch.fill" : "timer")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(timerColor)
                        Text(timer.displayedTime.islandClock)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
            }

            VStack(spacing: 10) {
                Button(action: timer.toggle) {
                    Label(timer.isRunning ? "Duraklat" : "Başlat", systemImage: timer.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(timerColor, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(ScaleButtonStyle())

                Button(action: timer.reset) {
                    Label("Sıfırla", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())

                if timer.mode != .stopwatch {
                    Button { timer.add(minutes: 5) } label: {
                        Label("+5 dakika", systemImage: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 112)
        }
    }

    private var timerColor: Color {
        switch timer.mode {
        case .countdown: IslandPalette.orange
        case .stopwatch: IslandPalette.cyan
        case .focus: IslandPalette.purple
        }
    }
}

private struct PresetButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? .white : .white.opacity(0.07), in: Capsule())
                .foregroundStyle(selected ? .black : .white.opacity(0.55))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
