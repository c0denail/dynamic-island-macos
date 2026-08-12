import CoreGraphics
import Foundation

enum IslandPetKind: String, CaseIterable, Identifiable {
    case orbit
    case neko
    case boo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orbit: "Orbit"
        case .neko: "Neko"
        case .boo: "Boo"
        }
    }

    var subtitle: String {
        switch self {
        case .orbit: "Mini robot"
        case .neko: "Ada kedisi"
        case .boo: "Uçan hayalet"
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
        let topInset: CGFloat
        if presentation == .expanded {
            let shoulderY = min(max(30, notchHeight * 0.9), rect.height * 0.24)
            topInset = min(rect.height - cornerRadius, shoulderY + cornerRadius * 0.8)
        } else {
            // A mini/compact island is a capsule. Starting at its side midpoint
            // follows the lower half exactly and never enters the top edge.
            topInset = cornerRadius
        }
        let availableHeight = max(0, rect.height - topInset)
        let sideLength = max(0, availableHeight - cornerRadius)
        let cornerLength = cornerRadius * .pi / 2
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
            let t = distance / cornerLength
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
            let t = distance / cornerLength
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
        return PetPerimeterPose(
            anchor: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius - min(sideLength, distance)),
            outwardNormal: CGVector(dx: 1, dy: 0),
            tangent: CGVector(dx: 0, dy: -1),
            segment: .right
        )
    }

    static func hangingCenter(for pose: PetPerimeterPose, swing: CGFloat = 0) -> CGPoint {
        let downwardNormal = max(0, pose.outwardNormal.dy)
        let ropeLength = 11 + downwardNormal * 2
        let gravityDrop = (1 - downwardNormal) * 8
        return CGPoint(
            x: pose.anchor.x + pose.outwardNormal.dx * (ropeLength + 13) + pose.tangent.dx * swing,
            y: pose.anchor.y + pose.outwardNormal.dy * (ropeLength + 13) + pose.tangent.dy * swing + gravityDrop
        )
    }

    static func avatarRotation(for pose: PetPerimeterPose) -> Double {
        Double(pose.outwardNormal.dx * 5)
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
