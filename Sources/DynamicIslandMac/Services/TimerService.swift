import AppKit
import Combine
import UserNotifications

@MainActor
final class TimerService: ObservableObject {
    @Published var mode: TimerMode = .countdown
    @Published var isRunning = false
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 5 * 60

    private var ticker: AnyCancellable?
    private var lastTick = Date()

    var displayedTime: TimeInterval {
        switch mode {
        case .stopwatch: elapsed
        case .countdown, .focus: max(0, duration - elapsed)
        }
    }

    var progress: Double {
        guard mode != .stopwatch, duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var accentName: String {
        switch mode {
        case .countdown: "turuncu"
        case .stopwatch: "camgöbeği"
        case .focus: "mor"
        }
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        if mode != .stopwatch, displayedTime <= 0 { elapsed = 0 }
        lastTick = Date()
        isRunning = true
        ensureTicker()
        requestNotificationPermission()
    }

    func pause() {
        consumeTimeSinceLastTick()
        isRunning = false
    }

    func reset() {
        isRunning = false
        elapsed = 0
    }

    func add(minutes: Int) {
        duration = max(60, duration + TimeInterval(minutes * 60))
    }

    func setPreset(minutes: Int, mode newMode: TimerMode? = nil) {
        if let newMode { mode = newMode }
        duration = TimeInterval(minutes * 60)
        elapsed = 0
        isRunning = false
    }

    func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func ensureTicker() {
        guard ticker == nil else { return }
        ticker = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                self?.tick(now: now)
            }
    }

    private func tick(now: Date) {
        guard isRunning else {
            lastTick = now
            return
        }

        elapsed += now.timeIntervalSince(lastTick)
        lastTick = now

        if mode != .stopwatch, elapsed >= duration {
            elapsed = duration
            isRunning = false
            finish()
        }
    }

    private func consumeTimeSinceLastTick() {
        guard isRunning else { return }
        let now = Date()
        elapsed += now.timeIntervalSince(lastTick)
        lastTick = now
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func finish() {
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = mode == .focus ? "Odak oturumu tamamlandı" : "Sayaç tamamlandı"
        content.body = "Dynamic Island sayacınız sona erdi."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
