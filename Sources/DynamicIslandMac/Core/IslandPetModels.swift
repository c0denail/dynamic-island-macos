import CoreGraphics
import Foundation

enum IslandPetKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case byte
    case ember
    case nova
    case moss
    case patch

    var id: String { rawValue }

    static func resolved(_ rawValue: String) -> IslandPetKind {
        IslandPetKind(rawValue: rawValue) ?? .byte
    }

    var title: String {
        switch self {
        case .byte: "Byte"
        case .ember: "Ember"
        case .nova: "Nova"
        case .moss: "Moss"
        case .patch: "Patch"
        }
    }

    var subtitle: String {
        switch self {
        case .byte: "Meraklı kod arkadaşı"
        case .ember: "Kıpır kıpır ateş ruhu"
        case .nova: "Yıldız gezgini"
        case .moss: "Sakin orman dostu"
        case .patch: "Neşeli tamir ustası"
        }
    }

    /// A real opaque support pixel on the lowest visible foot, expressed in
    /// the rendered 34 pt image's center coordinate space. Grounding this
    /// point (rather than an arbitrary center offset) keeps a visible foot on
    /// the island throughout the walk.
    var supportFoot: CGPoint {
        switch self {
        case .byte: CGPoint(x: -1.9921875, y: 14.078125)
        case .ember: CGPoint(x: -3.9401041667, y: 14.078125)
        case .nova: CGPoint(x: -3.6744791667, y: 13.546875)
        case .moss: CGPoint(x: 4.4713541667, y: 14.078125)
        case .patch: CGPoint(x: 1.9921875, y: 14.078125)
        }
    }

    var gaitLeanAmplitude: Double {
        switch self {
        case .byte, .nova, .patch: 2.6
        case .ember, .moss: 2.1
        }
    }

    /// Visible artwork bounds inside the rendered 34 pt square. These values
    /// come from each PNG's alpha>=16 bounding box, so transparent padding is
    /// not mistaken for a clipped mascot near the top of the display.
    var artworkBounds: CGRect {
        let sourceBounds: CGRect
        switch self {
        case .byte: sourceBounds = CGRect(x: 90, y: 33, width: 204, height: 318)
        case .ember: sourceBounds = CGRect(x: 44, y: 33, width: 296, height: 318)
        case .nova: sourceBounds = CGRect(x: 34, y: 39, width: 317, height: 306)
        case .moss: sourceBounds = CGRect(x: 46, y: 34, width: 291, height: 317)
        case .patch: sourceBounds = CGRect(x: 36, y: 33, width: 312, height: 318)
        }

        let renderedSize: CGFloat = 34
        let sourceSize: CGFloat = 384
        let scale = renderedSize / sourceSize
        return CGRect(
            x: sourceBounds.minX * scale - renderedSize / 2,
            y: sourceBounds.minY * scale - renderedSize / 2,
            width: sourceBounds.width * scale,
            height: sourceBounds.height * scale
        )
    }

    fileprivate var behaviorSeed: UInt64 {
        switch self {
        case .byte: 0x4259_5445_5F50_4554
        case .ember: 0x454D_4245_525F_5045
        case .nova: 0x4E4F_5641_5F50_4554
        case .moss: 0x4D4F_5353_5F50_4554
        case .patch: 0x5041_5443_485F_5045
        }
    }
}

/// Actions used by an island pet. Each choreography block opens with a long
/// grounded walk, a sudden roll and a rope drop. The remaining smaller actions
/// are separated by walks so they never flicker randomly between states.
enum PetBehavior: String, CaseIterable, Hashable, Sendable {
    case walk
    case roll
    case ropeSwing
    case hop
    case idle
    case peek
}

/// A renderer-independent snapshot of the pet's current action.
///
/// Offsets are expressed in the route's tangent/outward coordinate system.
/// The view can therefore apply its own travel direction and user-selected
/// speed without changing the deterministic behavior sequence.
struct PetBehaviorSample: Equatable, Sendable {
    let behavior: PetBehavior
    let episodeIndex: Int
    let episodeStart: TimeInterval
    let episodeDuration: TimeInterval
    let episodeProgress: Double
    let routeDistance: Double
    let routeSpeedMultiplier: Double
    let tangentOffset: CGFloat
    let outwardOffset: CGFloat
    let rotationDegrees: Double
    let scale: CGFloat
    let ropeVisibility: CGFloat
    /// Additional distance between the island edge and the pet while the rope
    /// is deployed. Renderers can use this independently from opacity to draw
    /// a visibly longer rope with a fast drop and a slower hanging phase.
    let ropeDrop: CGFloat

    var motionEnvelope: CGFloat {
        CGFloat(pow(sin(.pi * episodeProgress), 2))
    }
}

enum PetBehaviorSchedule {
    private struct Episode: Sendable {
        let behavior: PetBehavior
        let duration: TimeInterval

        var peakRouteSpeedMultiplier: Double {
            switch behavior {
            // The sinusoidal motion envelope has an average value of 0.5.
            // These peaks preserve the intended average travel speed while
            // easing every episode in and out at zero velocity.
            case .walk: 2
            case .roll: 4.8
            case .ropeSwing: 0
            case .hop: 1.2
            case .idle: 0
            case .peek: 0
            }
        }

        var routeDistance: Double {
            duration * peakRouteSpeedMultiplier / 2
        }
    }

    /// Five seeded choreography blocks produce a long, repeatable cycle. Each
    /// block starts with the requested walk -> sudden roll -> rope-drop
    /// sequence, then visits hop, peek and idle in a pet-specific order with a
    /// long recovery walk between those later actions.
    private static let blockCount = 5
    private static let episodeTimelines: [IslandPetKind: [Episode]] = Dictionary(
        uniqueKeysWithValues: IslandPetKind.allCases.map { kind in
            (kind, makeEpisodes(for: kind))
        }
    )

    static func sample(at elapsed: TimeInterval, kind: IslandPetKind) -> PetBehaviorSample {
        let safeElapsed = max(0, elapsed.isFinite ? elapsed : 0)
        let episodes = episodes(for: kind)
        let duration = episodes.reduce(0) { $0 + $1.duration }
        let routeDistancePerCycle = episodes.reduce(0) {
            $0 + $1.routeDistance
        }
        let cycleIndex = Int(floor(safeElapsed / duration))
        let cycleStart = Double(cycleIndex) * duration
        let localTime = safeElapsed - cycleStart

        var elapsedBeforeEpisode: TimeInterval = 0
        var routeBeforeEpisode: Double = 0

        for (localIndex, episode) in episodes.enumerated() {
            let episodeEnd = elapsedBeforeEpisode + episode.duration
            if localTime < episodeEnd || localIndex == episodes.count - 1 {
                let episodeElapsed = min(episode.duration, max(0, localTime - elapsedBeforeEpisode))
                let progress = min(1, max(0, episodeElapsed / episode.duration))
                let globalIndex = cycleIndex * episodes.count + localIndex
                let routeEnvelope = pow(sin(.pi * progress), 2)
                let routeSpeedMultiplier = episode.peakRouteSpeedMultiplier * routeEnvelope
                let routeDistance = Double(cycleIndex) * routeDistancePerCycle
                    + routeBeforeEpisode
                    + integratedRouteDistance(
                        elapsed: episodeElapsed,
                        duration: episode.duration,
                        peakMultiplier: episode.peakRouteSpeedMultiplier
                    )

                return makeSample(
                    behavior: episode.behavior,
                    episodeIndex: globalIndex,
                    episodeStart: cycleStart + elapsedBeforeEpisode,
                    episodeDuration: episode.duration,
                    progress: progress,
                    routeDistance: routeDistance,
                    routeSpeedMultiplier: routeSpeedMultiplier
                )
            }

            elapsedBeforeEpisode = episodeEnd
            routeBeforeEpisode += episode.routeDistance
        }

        // `episodes` is guaranteed to be non-empty. Keep a defensive fallback
        // so this pure function remains total if that implementation changes.
        return makeSample(
            behavior: .idle,
            episodeIndex: 0,
            episodeStart: 0,
            episodeDuration: 4,
            progress: 0,
            routeDistance: 0,
            routeSpeedMultiplier: 0
        )
    }

    static func cycleDuration(for kind: IslandPetKind) -> TimeInterval {
        episodes(for: kind).reduce(0) { $0 + $1.duration }
    }

    private static func integratedRouteDistance(
        elapsed: TimeInterval,
        duration: TimeInterval,
        peakMultiplier: Double
    ) -> Double {
        guard duration > 0, peakMultiplier > 0 else { return 0 }
        let clampedElapsed = min(duration, max(0, elapsed))
        let oscillation = duration * sin(2 * .pi * clampedElapsed / duration) / (4 * .pi)
        return peakMultiplier * (clampedElapsed / 2 - oscillation)
    }

    private static func makeSample(
        behavior: PetBehavior,
        episodeIndex: Int,
        episodeStart: TimeInterval,
        episodeDuration: TimeInterval,
        progress: Double,
        routeDistance: Double,
        routeSpeedMultiplier: Double
    ) -> PetBehaviorSample {
        let p = min(1, max(0, progress))
        let localTime = p * episodeDuration
        // All non-route transforms return to their neutral value at episode
        // boundaries. This keeps position, scale and rope opacity continuous.
        let envelope = pow(sin(.pi * p), 2)

        let tangentOffset: CGFloat
        let outwardOffset: CGFloat
        let rotation: Double
        let scale: CGFloat
        let ropeVisibility: CGFloat
        let ropeDrop: CGFloat

        switch behavior {
        case .walk:
            // Walking advances through routeDistance. Keeping the center on
            // the surface and the scale neutral lets the renderer pivot/squash
            // around the planted foot without lifting the pet off the island.
            tangentOffset = 0
            outwardOffset = 0
            // The production gait rotates around the planted alpha-baseline
            // contact point. Keeping this renderer-independent transform
            // neutral avoids two unrelated gait frequencies fighting each
            // other and producing a visible wobble.
            rotation = 0
            scale = 1
            ropeVisibility = 0
            ropeDrop = 0

        case .roll:
            tangentOffset = 0
            outwardOffset = 0
            // Finish two complete turns. Resetting from 720° to 0° at the
            // episode boundary is visually identical, so the pet rolls in a
            // single direction without snapping or reversing near the end.
            rotation = 720 * p
            scale = CGFloat(1 - 0.08 * envelope)
            ropeVisibility = 0
            ropeDrop = 0

        case .ropeSwing:
            // Deploy quickly, hold at full length, then retract smoothly. The
            // route is stationary for the entire episode; only the hanging
            // motion moves the pet.
            let deployed = smoothStep(min(1, p / 0.18))
                * smoothStep(min(1, (1 - p) / 0.22))
            let swingTime = max(0, localTime - episodeDuration * 0.18)
            let swing = sin(swingTime * .pi * 1.25)
            let drop = CGFloat(27 * deployed)
            tangentOffset = CGFloat(swing * 7.5 * deployed)
            outwardOffset = drop
            rotation = -swing * 16 * deployed
            scale = CGFloat(1 - 0.025 * deployed)
            ropeVisibility = CGFloat(deployed)
            ropeDrop = drop

        case .hop:
            let hop = abs(sin(p * .pi * 3)) * envelope
            tangentOffset = CGFloat(sin(p * .pi * 6) * 0.8 * envelope)
            outwardOffset = CGFloat(hop * 5.2)
            rotation = sin(p * .pi * 6) * 7 * envelope
            scale = CGFloat(1 + hop * 0.075)
            ropeVisibility = 0
            ropeDrop = 0

        case .idle:
            let breath = sin(p * .pi * 4) * envelope
            tangentOffset = CGFloat(breath * 0.25)
            outwardOffset = CGFloat(abs(breath) * 0.35)
            rotation = breath * 1.2
            scale = CGFloat(1 + breath * 0.018)
            ropeVisibility = 0
            ropeDrop = 0

        case .peek:
            let look = sin(p * .pi * 2) * envelope
            tangentOffset = CGFloat(look * 1.5)
            outwardOffset = CGFloat(-6.5 * envelope)
            rotation = look * 5
            scale = CGFloat(1 - 0.16 * envelope)
            ropeVisibility = 0
            ropeDrop = 0
        }

        return PetBehaviorSample(
            behavior: behavior,
            episodeIndex: episodeIndex,
            episodeStart: episodeStart,
            episodeDuration: episodeDuration,
            episodeProgress: p,
            routeDistance: routeDistance,
            routeSpeedMultiplier: routeSpeedMultiplier,
            tangentOffset: tangentOffset,
            outwardOffset: outwardOffset,
            rotationDegrees: rotation,
            scale: scale,
            ropeVisibility: ropeVisibility,
            ropeDrop: ropeDrop
        )
    }

    private static func smoothStep(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func episodes(for kind: IslandPetKind) -> [Episode] {
        episodeTimelines[kind] ?? makeEpisodes(for: kind)
    }

    private static func makeEpisodes(for kind: IslandPetKind) -> [Episode] {
        var generator = SplitMix64(state: kind.behaviorSeed)
        var result: [Episode] = []
        let specialsAfterRope: [PetBehavior] = [.hop, .peek, .idle]
        result.reserveCapacity((3 + specialsAfterRope.count * 2) * blockCount)

        for _ in 0..<blockCount {
            var laterSpecials = specialsAfterRope
            if laterSpecials.count > 1 {
                for index in stride(from: laterSpecials.count - 1, through: 1, by: -1) {
                    let swapIndex = Int(generator.next() % UInt64(index + 1))
                    laterSpecials.swapAt(index, swapIndex)
                }
            }

            result.append(Episode(behavior: .walk, duration: duration(for: .walk, using: &generator)))
            result.append(Episode(behavior: .roll, duration: duration(for: .roll, using: &generator)))
            result.append(Episode(behavior: .ropeSwing, duration: duration(for: .ropeSwing, using: &generator)))

            for special in laterSpecials {
                result.append(Episode(behavior: .walk, duration: duration(for: .walk, using: &generator)))
                result.append(Episode(behavior: special, duration: duration(for: special, using: &generator)))
            }
        }

        return result
    }

    private static func duration(for behavior: PetBehavior, using generator: inout SplitMix64) -> TimeInterval {
        let range: ClosedRange<Int>
        switch behavior {
        case .walk: range = 8_000...13_000
        case .roll: range = 1_150...1_800
        case .ropeSwing: range = 4_800...7_000
        case .hop: range = 1_400...2_300
        case .idle: range = 2_500...4_500
        case .peek: range = 2_000...3_700
        }

        let width = UInt64(range.upperBound - range.lowerBound + 1)
        let milliseconds = range.lowerBound + Int(generator.next() % width)
        return Double(milliseconds) / 1_000
    }

    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
}

enum PetPerimeterSegment: Equatable {
    case left
    case bottom
    case right
}

struct PetPerimeterPose: Equatable {
    let anchor: CGPoint
    let outwardNormal: CGVector
    let tangent: CGVector
    let segment: PetPerimeterSegment
}

struct PetGroundedPlacement: Equatable {
    let center: CGPoint
    let rotationDegrees: Double
}

struct PetGaitPose: Equatable {
    let contactOffset: CGFloat
    let leanDegrees: Double
}

struct PetVisualPlacement: Equatable {
    let center: CGPoint
    let rotationDegrees: Double
}

enum PetGaitGeometry {
    static func pose(
        progress: Double,
        motionEnvelope: CGFloat,
        supportFootX: CGFloat,
        leanAmplitude: Double
    ) -> PetGaitPose {
        let step = sin(min(1, max(0, progress)) * .pi * 14) * Double(motionEnvelope)
        return PetGaitPose(
            contactOffset: supportFootX,
            leanDegrees: step * leanAmplitude
        )
    }
}

enum PetVisualGeometry {
    static func placement(
        for pose: PetPerimeterPose,
        travelTangent: CGVector,
        behavior: PetBehaviorSample,
        kind: IslandPetKind
    ) -> PetVisualPlacement {
        let gait = behavior.behavior == .walk
            ? PetGaitGeometry.pose(
                progress: behavior.episodeProgress,
                motionEnvelope: behavior.motionEnvelope,
                supportFootX: kind.supportFoot.x,
                leanAmplitude: kind.gaitLeanAmplitude
            )
            : PetGaitPose(contactOffset: kind.supportFoot.x, leanDegrees: 0)
        let contactRotation = gait.leanDegrees
            + (behavior.behavior == .walk ? behavior.rotationDegrees : 0)
        let grounded = PetPerimeterGeometry.groundedPlacement(
            for: pose,
            contactExtent: kind.supportFoot.y,
            contactOffset: gait.contactOffset,
            scale: behavior.scale,
            gaitLeanDegrees: contactRotation
        )

        let rawPlacement: PetVisualPlacement
        if behavior.behavior == .ropeSwing {
            let gravityDrop = (1 - max(0, pose.outwardNormal.dy))
                * 10 * behavior.ropeVisibility
            rawPlacement = PetVisualPlacement(
                center: CGPoint(
                    x: grounded.center.x
                        + travelTangent.dx * behavior.tangentOffset
                        + pose.outwardNormal.dx * behavior.outwardOffset,
                    y: grounded.center.y
                        + travelTangent.dy * behavior.tangentOffset
                        + pose.outwardNormal.dy * behavior.outwardOffset
                        + gravityDrop
                ),
                rotationDegrees: grounded.rotationDegrees
                        * Double(1 - behavior.ropeVisibility)
                    + behavior.rotationDegrees
            )
        } else {
            rawPlacement = PetVisualPlacement(
                center: CGPoint(
                    x: grounded.center.x
                        + travelTangent.dx * behavior.tangentOffset
                        + pose.outwardNormal.dx * behavior.outwardOffset,
                    y: grounded.center.y
                        + travelTangent.dy * behavior.tangentOffset
                        + pose.outwardNormal.dy * behavior.outwardOffset
                ),
                rotationDegrees: grounded.rotationDegrees
                    + (behavior.behavior == .walk ? 0 : behavior.rotationDegrees)
            )
        }

        // A rolling or hanging pet may expose a wider diagonal than its normal
        // grounded pose. Keep those free motions below the physical display
        // edge; walking remains untouched so the measured foot stays exactly
        // on the island perimeter.
        guard behavior.behavior != .walk else { return rawPlacement }
        let bounds = visibleArtworkBounds(
            placement: rawPlacement,
            behavior: behavior,
            kind: kind
        )
        let topCorrection = max(0, 1 - bounds.minY)
        guard topCorrection > 0 else { return rawPlacement }
        return PetVisualPlacement(
            center: CGPoint(x: rawPlacement.center.x, y: rawPlacement.center.y + topCorrection),
            rotationDegrees: rawPlacement.rotationDegrees
        )
    }

    /// Axis-aligned bounds of the visible (non-transparent) mascot pixels
    /// after the same scale/rotation transforms used by `IslandPetView`.
    static func visibleArtworkBounds(
        placement: PetVisualPlacement,
        behavior: PetBehaviorSample,
        kind: IslandPetKind
    ) -> CGRect {
        let localBounds = kind.artworkBounds
        let innerScaleX: CGFloat
        let innerScaleY: CGFloat
        if behavior.behavior == .hop, kind == .moss {
            innerScaleX = 1 + 0.06 * behavior.motionEnvelope
            innerScaleY = 1 - 0.06 * behavior.motionEnvelope
        } else {
            innerScaleX = 1
            innerScaleY = 1
        }

        // Moss' hop squash is anchored at the bottom edge of the 34 pt image.
        let bottomAnchor: CGFloat = 17
        let localCorners = [
            CGPoint(x: localBounds.minX, y: localBounds.minY),
            CGPoint(x: localBounds.maxX, y: localBounds.minY),
            CGPoint(x: localBounds.minX, y: localBounds.maxY),
            CGPoint(x: localBounds.maxX, y: localBounds.maxY)
        ].map { point in
            CGPoint(
                x: point.x * innerScaleX * behavior.scale,
                y: (bottomAnchor + (point.y - bottomAnchor) * innerScaleY) * behavior.scale
            )
        }

        let radians = CGFloat(placement.rotationDegrees * .pi / 180)
        let transformed = localCorners.map { point in
            CGPoint(
                x: placement.center.x + cos(radians) * point.x - sin(radians) * point.y,
                y: placement.center.y + sin(radians) * point.x + cos(radians) * point.y
            )
        }
        let xs = transformed.map(\.x)
        let ys = transformed.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return CGRect(origin: placement.center, size: .zero) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum PetPerimeterGeometry {
    /// Maps a normalized progress value to an open U-shaped route. The route
    /// deliberately excludes the top edge so the pet never crosses the notch.
    static func pose(
        progress: Double,
        in rect: CGRect,
        presentation: IslandPresentation = .expanded,
        notchHeight: CGFloat = 34
    ) -> PetPerimeterPose {
        let clamped = min(1, max(0, progress))
        let cornerRadius = min(
            presentation == .expanded ? 34 : rect.height / 2,
            rect.width / 2,
            rect.height / 2
        )
        // Mini and compact islands are capsules that touch the physical top of
        // the display. Starting two points into the lower curve keeps visible
        // mascot pixels on-screen even while the planted-foot gait leans,
        // without introducing a path across the island's top edge.
        let capsuleSafetyInset: CGFloat = presentation == .expanded ? 0 : 5
        let cornerTrim: CGFloat
        if cornerRadius > 0, capsuleSafetyInset > 0 {
            cornerTrim = min(
                0.2,
                1 - sqrt(max(0, 1 - capsuleSafetyInset / cornerRadius))
            )
        } else {
            cornerTrim = 0
        }
        let topInset: CGFloat
        if presentation == .expanded {
            let shoulderY = min(max(30, notchHeight * 0.9), rect.height * 0.24)
            topInset = min(rect.height - cornerRadius, shoulderY + cornerRadius * 0.8)
        } else {
            // A mini/compact island is a capsule. Its usable route begins just
            // below the side midpoint and follows the lower half exactly.
            topInset = cornerRadius + capsuleSafetyInset
        }
        let availableHeight = max(0, rect.height - topInset)
        let sideLength = max(0, availableHeight - cornerRadius)
        let cornerLength = cornerRadius * .pi / 2 * (1 - cornerTrim)
        let bottomLength = max(0, rect.width - cornerRadius * 2)
        let totalLength = max(1, sideLength * 2 + cornerLength * 2 + bottomLength)
        var distance = CGFloat(clamped) * totalLength

        if distance <= sideLength {
            return PetPerimeterPose(
                anchor: CGPoint(x: rect.minX, y: rect.minY + topInset + distance),
                outwardNormal: CGVector(dx: -1, dy: 0),
                tangent: CGVector(dx: 0, dy: 1),
                segment: .left
            )
        }

        distance -= sideLength
        if distance <= cornerLength, cornerRadius > 0 {
            let normalizedT = distance / cornerLength
            let t = cornerTrim + normalizedT * (1 - cornerTrim)
            let start = CGPoint(x: rect.minX, y: rect.maxY - cornerRadius)
            let control = CGPoint(x: rect.minX, y: rect.maxY)
            let end = CGPoint(x: rect.minX + cornerRadius, y: rect.maxY)
            let anchor = quadraticBezier(start: start, control: control, end: end, t: t)
            let tangent = normalized(CGVector(
                dx: 2 * ((1 - t) * (control.x - start.x) + t * (end.x - control.x)),
                dy: 2 * ((1 - t) * (control.y - start.y) + t * (end.y - control.y))
            ))
            return PetPerimeterPose(
                anchor: anchor,
                outwardNormal: CGVector(dx: -tangent.dy, dy: tangent.dx),
                tangent: tangent,
                segment: .left
            )
        }

        distance -= cornerLength
        if distance <= bottomLength {
            return PetPerimeterPose(
                anchor: CGPoint(x: rect.minX + cornerRadius + distance, y: rect.maxY),
                outwardNormal: CGVector(dx: 0, dy: 1),
                tangent: CGVector(dx: 1, dy: 0),
                segment: .bottom
            )
        }

        distance -= bottomLength
        if distance <= cornerLength, cornerRadius > 0 {
            let normalizedT = distance / cornerLength
            let t = normalizedT * (1 - cornerTrim)
            let start = CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY)
            let control = CGPoint(x: rect.maxX, y: rect.maxY)
            let end = CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius)
            let anchor = quadraticBezier(start: start, control: control, end: end, t: t)
            let tangent = normalized(CGVector(
                dx: 2 * ((1 - t) * (control.x - start.x) + t * (end.x - control.x)),
                dy: 2 * ((1 - t) * (control.y - start.y) + t * (end.y - control.y))
            ))
            return PetPerimeterPose(
                anchor: anchor,
                outwardNormal: CGVector(dx: -tangent.dy, dy: tangent.dx),
                tangent: tangent,
                segment: .right
            )
        }

        distance -= cornerLength
        if sideLength == 0, cornerRadius > 0 {
            let t = 1 - cornerTrim
            let start = CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY)
            let control = CGPoint(x: rect.maxX, y: rect.maxY)
            let end = CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius)
            let anchor = quadraticBezier(start: start, control: control, end: end, t: t)
            let tangent = normalized(CGVector(
                dx: 2 * ((1 - t) * (control.x - start.x) + t * (end.x - control.x)),
                dy: 2 * ((1 - t) * (control.y - start.y) + t * (end.y - control.y))
            ))
            return PetPerimeterPose(
                anchor: anchor,
                outwardNormal: CGVector(dx: -tangent.dy, dy: tangent.dx),
                tangent: tangent,
                segment: .right
            )
        }
        return PetPerimeterPose(
            anchor: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius - min(sideLength, distance)),
            outwardNormal: CGVector(dx: 1, dy: 0),
            tangent: CGVector(dx: 0, dy: -1),
            segment: .right
        )
    }

    /// Rotates the avatar so its feet face the island and solves its center
    /// from the real artwork baseline. The resulting foot point is exactly the
    /// route anchor on straight edges and through both rounded corners.
    static func groundedPlacement(
        for pose: PetPerimeterPose,
        contactExtent: CGFloat,
        contactOffset: CGFloat = 0,
        scale: CGFloat = 1,
        gaitLeanDegrees: Double = 0
    ) -> PetGroundedPlacement {
        let routeRotation = atan2(pose.outwardNormal.dx, -pose.outwardNormal.dy) * 180 / .pi
        let rotation = routeRotation + gaitLeanDegrees
        let radians = CGFloat(rotation * .pi / 180)
        let footVector = CGPoint(
            x: (cos(radians) * contactOffset - sin(radians) * contactExtent) * scale,
            y: (sin(radians) * contactOffset + cos(radians) * contactExtent) * scale
        )
        return PetGroundedPlacement(
            center: CGPoint(
                x: pose.anchor.x - footVector.x,
                y: pose.anchor.y - footVector.y
            ),
            rotationDegrees: rotation
        )
    }

    /// Produces a 0...1...0 ping-pong loop so the open U route can repeat
    /// without teleporting across the forbidden top edge.
    static func pingPongProgress(elapsed: TimeInterval, duration: TimeInterval) -> (progress: Double, forward: Bool) {
        let safeDuration = max(1, duration)
        let cycle = (elapsed / safeDuration).truncatingRemainder(dividingBy: 2)
        if cycle <= 1 { return (cycle, true) }
        return (2 - cycle, false)
    }

    private static func quadraticBezier(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let inverse = 1 - t
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
            y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
        )
    }

    private static func normalized(_ vector: CGVector) -> CGVector {
        let length = max(0.0001, hypot(vector.dx, vector.dy))
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }
}
