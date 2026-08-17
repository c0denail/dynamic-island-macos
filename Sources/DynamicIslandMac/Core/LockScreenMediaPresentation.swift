import CoreGraphics
import Foundation

/// Pure presentation policy shared by the lock-session observer and the lock-screen card.
/// AppKit-specific notification and window handling deliberately live outside this type.
struct LockScreenMediaPresentationState: Equatable, Sendable {
    enum Session: Equatable, Sendable {
        case unknown
        case unlocked
        case locked
    }

    enum SessionEvent: Equatable, Sendable {
        case lockDetected
        case unlockDetected
    }

    struct LayoutMetrics: Equatable, Sendable {
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let obstacleClearance: CGFloat
        let preferredVerticalCenter: CGFloat
        let minimumCardSize: CGSize

        static let `default` = LayoutMetrics(
            horizontalPadding: 32,
            verticalPadding: 28,
            obstacleClearance: 20,
            // CGRect uses AppKit's bottom-origin screen coordinates here. Keeping
            // the card below the midpoint mirrors the supplied lock-screen layout.
            preferredVerticalCenter: 0.40,
            minimumCardSize: CGSize(width: 320, height: 170)
        )
    }

    private(set) var session: Session
    var isSessionActive: Bool
    var isPreviewing: Bool
    var isEnabled: Bool
    var hasActiveMedia: Bool

    init(
        session: Session = .unknown,
        isSessionActive: Bool = true,
        isPreviewing: Bool = false,
        isEnabled: Bool = true,
        hasActiveMedia: Bool = false
    ) {
        self.session = session
        self.isSessionActive = isSessionActive
        self.isPreviewing = isPreviewing
        self.isEnabled = isEnabled
        self.hasActiveMedia = hasActiveMedia
    }

    var isLocked: Bool {
        session == .locked
    }

    var shouldShow: Bool {
        Self.shouldShow(
            isLocked: isLocked,
            isPreviewing: isPreviewing,
            isEnabled: isEnabled,
            hasActiveMedia: hasActiveMedia,
            isSessionActive: isSessionActive
        )
    }

    mutating func apply(_ event: SessionEvent) {
        switch event {
        case .lockDetected:
            session = .locked
        case .unlockDetected:
            session = .unlocked
        }
    }

    /// Preview is intentionally independent of runtime eligibility so Settings can
    /// render a sample while the Mac is unlocked or the feature is disabled.
    static func shouldShow(
        isLocked: Bool,
        isPreviewing: Bool,
        isEnabled: Bool,
        hasActiveMedia: Bool,
        isSessionActive: Bool = true
    ) -> Bool {
        isSessionActive && (isPreviewing || (isEnabled && isLocked && hasActiveMedia))
    }

    /// Produces a responsive, centered lock-screen card inside the usable portion
    /// of a display. Invalid visible frames fall back to the screen frame.
    static func cardFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        cardSize: CGSize
    ) -> CGRect {
        cardFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            cardSize: cardSize,
            avoiding: [],
            metrics: .default
        ) ?? .zero
    }

    /// Places the card without intersecting caller-supplied reserved regions. The
    /// caller can pass observed clock, authentication, or accessibility UI frames;
    /// this model does not assume where any macOS login element is located.
    static func cardFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        cardSize: CGSize,
        avoiding reservedFrames: [CGRect],
        metrics: LayoutMetrics = .default
    ) -> CGRect? {
        guard let container = layoutContainer(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ) else {
            return nil
        }

        let horizontalInset = min(max(0, metrics.horizontalPadding), container.width / 2)
        let verticalInset = min(max(0, metrics.verticalPadding), container.height / 2)
        let safeFrame = container.insetBy(dx: horizontalInset, dy: verticalInset)
        guard safeFrame.width > 0, safeFrame.height > 0,
              cardSize.width > 0, cardSize.height > 0 else {
            return nil
        }

        let desiredSize = CGSize(
            width: min(cardSize.width, safeFrame.width),
            height: min(cardSize.height, safeFrame.height)
        )
        let minimumSize = CGSize(
            width: min(desiredSize.width, max(1, metrics.minimumCardSize.width)),
            height: min(desiredSize.height, max(1, metrics.minimumCardSize.height))
        )
        let clearance = max(0, metrics.obstacleClearance)
        let obstacles = reservedFrames
            .map(\.standardized)
            .filter { !$0.isNull && !$0.isEmpty && $0.intersects(container) }
            .map { $0.insetBy(dx: -clearance, dy: -clearance) }

        // Prefer the requested size. Smaller candidates are considered only when
        // no collision-free placement exists, preserving legibility on large Macs.
        for size in candidateSizes(from: desiredSize, through: minimumSize) {
            if let frame = bestFrame(
                of: size,
                inside: safeFrame,
                avoiding: obstacles,
                preferredVerticalCenter: metrics.preferredVerticalCenter
            ) {
                return frame
            }
        }

        return nil
    }

    private static func layoutContainer(
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        let screen = screenFrame.standardized
        guard !screen.isNull, !screen.isEmpty else { return nil }

        let visible = visibleFrame.standardized
        guard !visible.isNull, !visible.isEmpty else { return screen }

        let intersection = screen.intersection(visible)
        return intersection.isNull || intersection.isEmpty ? screen : intersection
    }

    private static func candidateSizes(from desired: CGSize, through minimum: CGSize) -> [CGSize] {
        let stepCount = 10
        return (0...stepCount).map { index in
            let progress = CGFloat(index) / CGFloat(stepCount)
            return CGSize(
                width: desired.width + (minimum.width - desired.width) * progress,
                height: desired.height + (minimum.height - desired.height) * progress
            )
        }.reduce(into: []) { result, size in
            guard result.last != size else { return }
            result.append(size)
        }
    }

    private static func bestFrame(
        of size: CGSize,
        inside safeFrame: CGRect,
        avoiding obstacles: [CGRect],
        preferredVerticalCenter: CGFloat
    ) -> CGRect? {
        let minimumCenterX = safeFrame.minX + size.width / 2
        let maximumCenterX = safeFrame.maxX - size.width / 2
        let minimumCenterY = safeFrame.minY + size.height / 2
        let maximumCenterY = safeFrame.maxY - size.height / 2
        guard minimumCenterX <= maximumCenterX, minimumCenterY <= maximumCenterY else {
            return nil
        }

        let verticalFraction = min(1, max(0, preferredVerticalCenter))
        let preferredCenter = CGPoint(
            x: safeFrame.midX,
            y: min(
                maximumCenterY,
                max(minimumCenterY, safeFrame.minY + safeFrame.height * verticalFraction)
            )
        )

        var candidateXs = [preferredCenter.x, minimumCenterX, maximumCenterX]
        var candidateYs = [preferredCenter.y, minimumCenterY, maximumCenterY]
        for obstacle in obstacles {
            candidateXs.append(obstacle.minX - size.width / 2)
            candidateXs.append(obstacle.maxX + size.width / 2)
            candidateYs.append(obstacle.minY - size.height / 2)
            candidateYs.append(obstacle.maxY + size.height / 2)
        }

        candidateXs = uniqueClamped(candidateXs, lower: minimumCenterX, upper: maximumCenterX)
        candidateYs = uniqueClamped(candidateYs, lower: minimumCenterY, upper: maximumCenterY)

        let normalizationWidth = max(1, safeFrame.width)
        let normalizationHeight = max(1, safeFrame.height)
        var best: (frame: CGRect, score: CGFloat)?

        for centerX in candidateXs {
            for centerY in candidateYs {
                let frame = CGRect(
                    x: centerX - size.width / 2,
                    y: centerY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                guard contains(frame, in: safeFrame),
                      !obstacles.contains(where: { frame.intersects($0) }) else {
                    continue
                }

                let horizontalDistance = abs(centerX - preferredCenter.x) / normalizationWidth
                let verticalDistance = abs(centerY - preferredCenter.y) / normalizationHeight
                // Horizontal centering is visually more important than a small
                // vertical adjustment around a reserved lock-screen element.
                let score = horizontalDistance * 1.75 + verticalDistance
                if best == nil || score < best!.score {
                    best = (frame, score)
                }
            }
        }

        return best?.frame
    }

    private static func uniqueClamped(
        _ values: [CGFloat],
        lower: CGFloat,
        upper: CGFloat
    ) -> [CGFloat] {
        values.reduce(into: []) { result, value in
            guard value.isFinite else { return }
            let clamped = min(upper, max(lower, value))
            guard !result.contains(where: { abs($0 - clamped) < 0.5 }) else { return }
            result.append(clamped)
        }
    }

    private static func contains(_ frame: CGRect, in container: CGRect) -> Bool {
        let tolerance: CGFloat = 0.001
        return frame.minX >= container.minX - tolerance
            && frame.maxX <= container.maxX + tolerance
            && frame.minY >= container.minY - tolerance
            && frame.maxY <= container.maxY + tolerance
    }
}
