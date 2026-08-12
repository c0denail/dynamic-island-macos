import SwiftUI

@MainActor
final class IslandPetLayout: ObservableObject {
    @Published private(set) var islandSize: CGSize = IslandPresentation.mini.defaultSize
    @Published private(set) var presentation: IslandPresentation = .mini
    @Published private(set) var notchHeight: CGFloat = 34
    @Published private(set) var isSuspended = false

    func update(islandSize: CGSize, presentation: IslandPresentation, notchHeight: CGFloat) {
        guard self.islandSize != islandSize || self.presentation != presentation || self.notchHeight != notchHeight else { return }
        self.islandSize = islandSize
        self.presentation = presentation
        self.notchHeight = notchHeight
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
    }
}

struct IslandPetOverlayView: View {
    @ObservedObject var layout: IslandPetLayout
    @AppStorage("islandPetEnabled") private var isPetEnabled = true
    @AppStorage("islandPetKind") private var selectedPet = IslandPetKind.orbit.rawValue
    @AppStorage("islandPetSpeed") private var petSpeed = 1.0

    private let sideMargin: CGFloat = 44
    private let bottomMargin: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            if isPetEnabled && !layout.isSuspended {
                // The pet travels smoothly at 30 Hz while its small gait shapes
                // remain inexpensive. This avoids competing with the panel's
                // 60 Hz resize animation and lowers idle CPU/GPU usage.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    let routeDuration = 17.5 / max(0.55, min(1.8, petSpeed))
                    let travel = PetPerimeterGeometry.pingPongProgress(elapsed: elapsed, duration: routeDuration)
                    let islandRect = CGRect(
                        x: (proxy.size.width - layout.islandSize.width) / 2,
                        y: 0,
                        width: layout.islandSize.width,
                        height: layout.islandSize.height
                    )
                    let pose = PetPerimeterGeometry.pose(
                        progress: travel.progress,
                        in: islandRect,
                        presentation: layout.presentation,
                        notchHeight: layout.notchHeight
                    )
                    let gait = elapsed * 7.5
                    let swing = sin(elapsed * 3.2) * 3.4
                    let petCenter = PetPerimeterGeometry.hangingCenter(for: pose, swing: swing)

                    petAndRope(
                        pose: pose,
                        petCenter: petCenter,
                        gait: gait,
                        movingForward: travel.forward
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(layout.isSuspended ? 0 : 1)
    }

    @ViewBuilder
    private func petAndRope(
        pose: PetPerimeterPose,
        petCenter: CGPoint,
        gait: Double,
        movingForward: Bool
    ) -> some View {
        let direction: CGFloat = movingForward ? 1 : -1
        let tangent = CGVector(dx: pose.tangent.dx * direction, dy: pose.tangent.dy * direction)

        ZStack {
            Path { path in
                path.move(to: pose.anchor)
                let control = CGPoint(
                    x: (pose.anchor.x + petCenter.x) / 2 + tangent.dx * 2.5,
                    y: (pose.anchor.y + petCenter.y) / 2 + tangent.dy * 2.5
                )
                path.addQuadCurve(to: petCenter, control: control)
            }
            .stroke(
                Color.white.opacity(0.42),
                style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
            )

            Circle()
                .fill(Color.white.opacity(0.72))
                .frame(width: 3.5, height: 3.5)
                .position(pose.anchor)

            IslandPetAvatar(
                kind: IslandPetKind(rawValue: selectedPet) ?? .orbit,
                gait: gait,
                horizontalDirection: tangent.dx
            )
            .frame(width: 28, height: 28)
            .rotationEffect(.degrees(PetPerimeterGeometry.avatarRotation(for: pose)))
            .position(petCenter)
        }
    }
}

struct IslandPetAvatar: View {
    let kind: IslandPetKind
    let gait: Double
    let horizontalDirection: CGFloat

    var body: some View {
        Group {
            switch kind {
            case .orbit: OrbitPet(gait: gait)
            case .neko: NekoPet(gait: gait)
            case .boo: BooPet(gait: gait)
            }
        }
        .scaleEffect(x: horizontalDirection < 0 ? -1 : 1, y: 1)
        .offset(y: sin(gait * 2) * 0.9)
    }
}

private struct OrbitPet: View {
    let gait: Double

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 24, height: 20)
                .overlay(Capsule().stroke(Color.white.opacity(0.84), lineWidth: 1.2))

            HStack(spacing: 5) {
                Circle().fill(Color.white).frame(width: 3.5, height: 3.5)
                Circle().fill(Color.white).frame(width: 3.5, height: 3.5)
            }
            .offset(y: -1)

            Capsule()
                .fill(Color.white.opacity(0.74))
                .frame(width: 7, height: 1.6)
                .offset(y: 5)

            HStack(spacing: 9) {
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 3, height: 7)
                    .rotationEffect(.degrees(sin(gait) * 22))
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 3, height: 7)
                    .rotationEffect(.degrees(-sin(gait) * 22))
            }
            .offset(y: 11)
        }
    }
}

private struct NekoPet: View {
    let gait: Double

    var body: some View {
        ZStack {
            CatHeadShape()
                .fill(Color.white.opacity(0.16))
                .overlay(CatHeadShape().stroke(Color.white.opacity(0.88), lineWidth: 1.2))
                .frame(width: 25, height: 24)

            HStack(spacing: 5) {
                Capsule().fill(Color.white).frame(width: 2.4, height: 4)
                Capsule().fill(Color.white).frame(width: 2.4, height: 4)
            }
            .offset(y: -1)

            Path { path in
                path.move(to: CGPoint(x: 11, y: 16))
                path.addQuadCurve(to: CGPoint(x: 17, y: 16), control: CGPoint(x: 14, y: 20))
            }
            .stroke(Color.white.opacity(0.75), lineWidth: 1)
            .frame(width: 28, height: 28)

            HStack(spacing: 9) {
                Capsule().fill(Color.white.opacity(0.82)).frame(width: 3, height: 6)
                    .offset(y: sin(gait) * 1.4)
                Capsule().fill(Color.white.opacity(0.82)).frame(width: 3, height: 6)
                    .offset(y: -sin(gait) * 1.4)
            }
            .offset(y: 12)
        }
    }
}

private struct BooPet: View {
    let gait: Double

    var body: some View {
        ZStack {
            GhostPetShape(wave: sin(gait) * 0.8)
                .fill(Color.white.opacity(0.17))
                .overlay(GhostPetShape(wave: sin(gait) * 0.8).stroke(Color.white.opacity(0.88), lineWidth: 1.2))

            HStack(spacing: 5) {
                Circle().fill(Color.white).frame(width: 3, height: 4)
                Circle().fill(Color.white).frame(width: 3, height: 4)
            }
            .offset(y: -2)

            Circle().fill(Color.white.opacity(0.78)).frame(width: 3, height: 2.4)
                .offset(y: 4)
        }
        .frame(width: 25, height: 26)
    }
}

private struct CatHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.19))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.34),
            control1: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.12),
            control2: CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.16)
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.18))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.34),
            control1: CGPoint(x: rect.maxX, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct GhostPetShape: Shape {
    let wave: Double

    var animatableData: Double {
        get { wave }
        set { }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control1: CGPoint(x: rect.maxX * 0.76, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.height * 0.2)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
        let lift = CGFloat(wave)
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY - 2 - lift),
            control: CGPoint(x: rect.width * 0.75, y: rect.maxY - 8 + lift)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - 3),
            control: CGPoint(x: rect.width * 0.25, y: rect.maxY - 8 - lift)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.height * 0.2),
            control2: CGPoint(x: rect.width * 0.24, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
