import Combine
import Foundation

@MainActor
final class TimerService: ObservableObject {
    @Published var mode: TimerMode = .countdown
    @Published var duration: TimeInterval = 5 * 60

    func add(minutes: Int) {
        duration = min(86_399, max(60, duration + TimeInterval(minutes * 60)))
    }

    func setPreset(minutes: Int) {
        duration = min(86_399, max(1, TimeInterval(minutes * 60)))
    }
}
