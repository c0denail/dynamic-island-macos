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
    @AppStorage("islandPetKind") private var selectedPet = IslandPetKind.byte.rawValue
    @AppStorage("islandPetSpeed") private var petSpeed = 1.0

    var body: some View {
        GeometryReader { proxy in
            if isPetEnabled {
                TimelineView(.animation(minimumInterval: IslandAnimationCadence.minimumInterval)) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    let kind = IslandPetKind.resolved(selectedPet)
                    let behavior = PetBehaviorSchedule.sample(at: elapsed, kind: kind)
                    let routeDuration = 17.5 / max(0.55, min(1.8, petSpeed))
                    let travel = PetPerimeterGeometry.pingPongProgress(
                        elapsed: behavior.routeDistance,
                        duration: routeDuration
                    )
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
                    let travelDirection: CGFloat = travel.forward ? 1 : -1
                    let tangent = CGVector(
                        dx: pose.tangent.dx * travelDirection,
                        dy: pose.tangent.dy * travelDirection
                    )
                    let placement = PetVisualGeometry.placement(
                        for: pose,
                        travelTangent: tangent,
                        behavior: behavior,
                        kind: kind
                    )

                    PetActivityView(
                        kind: kind,
                        behavior: behavior,
                        pose: pose,
                        tangent: tangent,
                        center: placement.center,
                        rotationDegrees: placement.rotationDegrees
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(layout.isSuspended ? 0 : 1)
        .animation(.easeInOut(duration: 0.1), value: layout.isSuspended)
        .onAppear {
            let resolvedPet = IslandPetKind.resolved(selectedPet).rawValue
            if selectedPet != resolvedPet {
                selectedPet = resolvedPet
            }
        }
    }
}

private struct PetActivityView: View {
    let kind: IslandPetKind
    let behavior: PetBehaviorSample
    let pose: PetPerimeterPose
    let tangent: CGVector
    let center: CGPoint
    let rotationDegrees: Double

    var body: some View {
        ZStack {
            if behavior.ropeVisibility > 0.001 {
                ropePath
                    .stroke(
                        Color.black.opacity(0.58 * behavior.ropeVisibility),
                        style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
                    )

                ropePath
                    .stroke(
                        Color.white.opacity(0.96 * behavior.ropeVisibility),
                        style: StrokeStyle(lineWidth: 2.15, lineCap: .round, lineJoin: .round)
                    )

                Circle()
                    .fill(Color.white.opacity(0.98 * behavior.ropeVisibility))
                    .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 0.65))
                    .frame(width: 5, height: 5)
                    .position(pose.anchor)
            }

            IslandPetAvatar(
                kind: kind,
                behavior: behavior.behavior,
                motionEnvelope: behavior.motionEnvelope
            )
            .frame(width: IslandPetAvatarMetrics.frameSize, height: IslandPetAvatarMetrics.frameSize)
            .scaleEffect(behavior.scale)
            .rotationEffect(.degrees(rotationDegrees))
            .position(center)
        }
    }

    private var ropePath: Path {
        Path { path in
            path.move(to: pose.anchor)
            let control = CGPoint(
                x: (pose.anchor.x + center.x) / 2 + tangent.dx * 5,
                y: (pose.anchor.y + center.y) / 2 + tangent.dy * 5 + 3
            )
            path.addQuadCurve(to: center, control: control)
        }
    }
}

struct IslandPetAvatar: View {
    let kind: IslandPetKind
    var behavior: PetBehavior = .idle
    var motionEnvelope: CGFloat = 1

    @MainActor
    var body: some View {
        if let image = IslandPetAssetLoader.shared.image(for: kind.asset) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .scaleEffect(x: squashX, y: squashY, anchor: .bottom)
        } else {
            fallbackAvatar
        }
    }

    private var squashX: CGFloat {
        behavior == .hop && kind == .moss ? 1 + 0.06 * motionEnvelope : 1
    }

    private var squashY: CGFloat {
        behavior == .hop && kind == .moss ? 1 - 0.06 * motionEnvelope : 1
    }

    private var fallbackAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: kind == .nova ? 8 : 14, style: .continuous)
                .fill(kind.fallbackColor.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: kind == .nova ? 8 : 14, style: .continuous)
                        .stroke(.white.opacity(0.7), lineWidth: 1)
                )
            HStack(spacing: 5) {
                Circle().fill(.white).frame(width: 3, height: 3)
                Circle().fill(.white).frame(width: 3, height: 3)
            }
        }
        .frame(width: 27, height: 27)
    }
}

private enum IslandPetAvatarMetrics {
    static let frameSize: CGFloat = 34
}

private extension IslandPetKind {
    var asset: IslandPetAsset {
        IslandPetAsset(rawValue: rawValue) ?? .byte
    }

    var fallbackColor: Color {
        switch self {
        case .byte: .cyan
        case .ember: .orange
        case .nova: .purple
        case .moss: .green
        case .patch: .red
        }
    }
}
