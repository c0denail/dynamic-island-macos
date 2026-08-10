import AppKit
import SwiftUI

enum IslandPresentation: String, CaseIterable {
    case mini
    case compact
    case expanded

    var defaultSize: CGSize {
        switch self {
        case .mini: CGSize(width: 190, height: 38)
        case .compact: CGSize(width: 510, height: 42)
        case .expanded: CGSize(width: 680, height: 418)
        }
    }
}

enum IslandSection: String, CaseIterable, Identifiable {
    case overview = "Özet"
    case media = "Medya"
    case timer = "Sayaç"
    case system = "Sistem"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "sparkles"
        case .media: "music.note"
        case .timer: "timer"
        case .system: "macbook"
        }
    }
}

enum SystemPanelDestination: Equatable {
    case wifi
    case bluetooth
}

enum CompactActivity: Equatable {
    case idle
    case media
    case timer
    case volume(value: Float, isMuted: Bool)
    case brightness(value: Float)
    case notification(MirroredNotification)
    case message(icon: String, title: String, color: Color)
}

struct MirroredNotification: Identifiable, Equatable, Sendable {
    let id: String
    let appName: String
    let title: String
    let subtitle: String
    let body: String
    let bundleIdentifier: String?
    let appIconData: Data?

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var displayDetail: String {
        [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum ClockActivityState: Equatable, Sendable {
    case stopped
    case paused
    case running
}

struct ClockTimerSnapshot: Equatable, Sendable {
    let identifier: String
    let duration: TimeInterval
    let title: String
    let state: ClockActivityState
    let fireDate: Date?
    let remainingAtSnapshot: TimeInterval
    let capturedAt: Date

    var remaining: TimeInterval {
        if state == .running, let fireDate {
            return max(0, fireDate.timeIntervalSinceNow)
        }
        return max(0, remainingAtSnapshot)
    }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, (duration - remaining) / duration))
    }
}

struct ClockStopwatchSnapshot: Equatable, Sendable {
    let identifier: String
    let state: ClockActivityState
    let baseElapsed: TimeInterval
    let startDate: Date?
    let capturedAt: Date

    var elapsed: TimeInterval {
        guard state == .running else { return max(0, baseElapsed) }
        return max(0, baseElapsed + Date().timeIntervalSince(capturedAt))
    }
}

enum TimerMode: String, CaseIterable, Identifiable {
    case countdown = "Geri Sayım"
    case stopwatch = "Kronometre"

    var id: String { rawValue }
}

struct IslandPalette {
    static let background = Color(red: 0.018, green: 0.018, blue: 0.023)
    static let surface = Color.white.opacity(0.075)
    static let raisedSurface = Color.white.opacity(0.105)
    static let primary = Color.white
    static let cyan = Color.white
    static let purple = Color.white
    static let orange = Color.white
}

extension TimeInterval {
    var islandClock: String {
        let total = max(0, Int(self.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension String {
    var islandLocalizedTimeInterval: TimeInterval {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return TimeInterval(normalized) ?? 0
    }
}
