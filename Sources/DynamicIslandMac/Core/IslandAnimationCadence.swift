import Foundation

/// Shared animation cadence for the island's time-driven views.
///
/// SwiftUI and Core Animation still synchronize presentation with the current
/// display, so a 60 Hz panel naturally presents 60 frames while ProMotion can
/// use the full 120 Hz budget.
enum IslandAnimationCadence {
    static let preferredFramesPerSecond = 120
    static let minimumInterval = 1.0 / Double(preferredFramesPerSecond)

    static func framesPerSecond(displayMaximum: Int) -> Int {
        min(preferredFramesPerSecond, max(1, displayMaximum))
    }
}
