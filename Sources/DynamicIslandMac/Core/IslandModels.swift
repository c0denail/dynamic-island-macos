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
    case hardware(IslandHardwareActivity)
    case notification(MirroredNotification)
    case message(icon: String, title: String, color: Color)
}

enum IslandHardwareActivityKind: String, Equatable, Sendable {
    case charging
    case powerConnected
    case powerDisconnected
    case airPods
    case airPodsMax
    case headphones
    case storageConnected
    case storageDisconnected

    var iconName: String {
        switch self {
        case .charging: "bolt.fill"
        case .powerConnected: "powerplug.fill"
        case .powerDisconnected: "battery.100percent"
        case .airPods: "airpods"
        case .airPodsMax: "airpodsmax"
        case .headphones: "headphones"
        case .storageConnected: "externaldrive.fill.badge.plus"
        case .storageDisconnected: "externaldrive.fill.badge.minus"
        }
    }

    var isAudioAccessory: Bool {
        self == .airPods || self == .airPodsMax || self == .headphones
    }

    var isStorage: Bool {
        self == .storageConnected || self == .storageDisconnected
    }
}

struct IslandBatteryLevels: Equatable, Sendable {
    let combined: Int?
    let left: Int?
    let right: Int?
    let caseLevel: Int?

    init(combined: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.combined = Self.clamped(combined)
        self.left = Self.clamped(left)
        self.right = Self.clamped(right)
        self.caseLevel = Self.clamped(caseLevel)
    }

    var preferred: Int? {
        if let combined { return combined }
        let buds = [left, right].compactMap { $0 }
        guard !buds.isEmpty else { return caseLevel }
        return Int((Double(buds.reduce(0, +)) / Double(buds.count)).rounded())
    }

    private static func clamped(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }
}

struct IslandHardwareActivity: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String?
    let kind: IslandHardwareActivityKind
    let title: String
    let subtitle: String
    let isConnected: Bool?
    let battery: IslandBatteryLevels?
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let volumeURL: URL?

    init(
        id: String = UUID().uuidString,
        sourceID: String? = nil,
        kind: IslandHardwareActivityKind,
        title: String,
        subtitle: String,
        isConnected: Bool? = nil,
        battery: IslandBatteryLevels? = nil,
        totalCapacity: Int64? = nil,
        availableCapacity: Int64? = nil,
        volumeURL: URL? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.isConnected = isConnected
        self.battery = battery
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.volumeURL = volumeURL
    }

    var progress: Double? {
        if let batteryPercent = battery?.preferred {
            return Double(batteryPercent) / 100
        }
        guard let totalCapacity, totalCapacity > 0, let availableCapacity else { return nil }
        return min(1, max(0, Double(totalCapacity - availableCapacity) / Double(totalCapacity)))
    }

    var duration: TimeInterval {
        kind.isAudioAccessory ? 4.6 : 4.0
    }
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
