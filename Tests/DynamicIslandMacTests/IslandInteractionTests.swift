import AppKit
import XCTest
@testable import DynamicIslandMac

@MainActor
final class IslandInteractionTests: XCTestCase {
    func testCollapsedPanelHandlesMouseDownAcrossEntireSurface() throws {
        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: 42),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var handledLocations: [CGPoint] = []
        panel.collapsedMouseDownHandler = {
            handledLocations.append(panel.mouseLocationOutsideOfEventStream)
            return true
        }

        for point in [CGPoint(x: 2, y: 2), CGPoint(x: 255, y: 21), CGPoint(x: 508, y: 40)] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: point,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: panel.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
            panel.sendEvent(event)
        }

        XCTAssertEqual(handledLocations.count, 3)
    }

    func testPetRouteUsesOnlyLeftBottomAndRightSides() {
        let rect = CGRect(x: 40, y: 0, width: 680, height: 418)
        var encountered = Set<String>()

        for index in 0...200 {
            let pose = PetPerimeterGeometry.pose(progress: Double(index) / 200, in: rect)
            XCTAssertGreaterThan(pose.anchor.y, rect.minY)
            XCTAssertGreaterThanOrEqual(pose.anchor.x, rect.minX)
            XCTAssertLessThanOrEqual(pose.anchor.x, rect.maxX)
            XCTAssertLessThanOrEqual(pose.anchor.y, rect.maxY)

            switch pose.segment {
            case .left:
                encountered.insert("left")
                XCTAssertLessThanOrEqual(pose.anchor.x, rect.minX + 34.001)
            case .bottom:
                encountered.insert("bottom")
                XCTAssertEqual(pose.anchor.y, rect.maxY, accuracy: 0.001)
            case .right:
                encountered.insert("right")
                XCTAssertGreaterThanOrEqual(pose.anchor.x, rect.maxX - 34.001)
            }
        }

        XCTAssertEqual(encountered, Set(["left", "bottom", "right"]))
    }

    func testPetPingPongLoopReturnsWithoutCrossingTopEdge() {
        let outbound = PetPerimeterGeometry.pingPongProgress(elapsed: 4, duration: 8)
        let end = PetPerimeterGeometry.pingPongProgress(elapsed: 8, duration: 8)
        let returning = PetPerimeterGeometry.pingPongProgress(elapsed: 12, duration: 8)
        let restarted = PetPerimeterGeometry.pingPongProgress(elapsed: 16, duration: 8)

        XCTAssertEqual(outbound.progress, 0.5, accuracy: 0.001)
        XCTAssertTrue(outbound.forward)
        XCTAssertEqual(end.progress, 1, accuracy: 0.001)
        XCTAssertTrue(end.forward)
        XCTAssertEqual(returning.progress, 0.5, accuracy: 0.001)
        XCTAssertFalse(returning.forward)
        XCTAssertEqual(restarted.progress, 0, accuracy: 0.001)
        XCTAssertTrue(restarted.forward)
    }

    func testPetRouteHasNoCornerTeleport() {
        let rect = CGRect(x: 40, y: 0, width: 680, height: 418)
        var previous = PetPerimeterGeometry.pose(progress: 0, in: rect)
        var largestStep: CGFloat = 0
        var largestNormalStep: CGFloat = 0

        for index in 1...1_000 {
            let current = PetPerimeterGeometry.pose(progress: Double(index) / 1_000, in: rect)
            largestStep = max(largestStep, hypot(current.anchor.x - previous.anchor.x, current.anchor.y - previous.anchor.y))
            largestNormalStep = max(
                largestNormalStep,
                hypot(
                    current.outwardNormal.dx - previous.outwardNormal.dx,
                    current.outwardNormal.dy - previous.outwardNormal.dy
                )
            )
            previous = current
        }

        XCTAssertLessThan(largestStep, 2)
        XCTAssertLessThan(largestNormalStep, 0.08)
    }

    func testProductionPetPlacementStaysContinuousAroundCorners() {
        let rect = CGRect(x: 40, y: 0, width: 680, height: 418)
        let firstPose = PetPerimeterGeometry.pose(progress: 0, in: rect)
        let behavior = PetBehaviorSchedule.sample(at: 2, kind: .byte)
        var previousPlacement = PetVisualGeometry.placement(
            for: firstPose,
            travelTangent: firstPose.tangent,
            behavior: behavior,
            kind: .byte
        )
        var largestCenterStep: CGFloat = 0
        var largestRotationStep: Double = 0

        for index in 1...2_000 {
            let pose = PetPerimeterGeometry.pose(progress: Double(index) / 2_000, in: rect)
            let placement = PetVisualGeometry.placement(
                for: pose,
                travelTangent: pose.tangent,
                behavior: behavior,
                kind: .byte
            )
            largestCenterStep = max(
                largestCenterStep,
                hypot(
                    placement.center.x - previousPlacement.center.x,
                    placement.center.y - previousPlacement.center.y
                )
            )
            largestRotationStep = max(
                largestRotationStep,
                visualAngleDelta(placement.rotationDegrees, previousPlacement.rotationDegrees)
            )
            previousPlacement = placement
        }

        XCTAssertLessThan(largestCenterStep, 1.5)
        // At the production travel speed this is under two degrees per 120 Hz
        // frame even at the tightest rounded corner.
        XCTAssertLessThan(largestRotationStep, 2)
    }

    func testPetAvatarNeverCrossesTopForEveryPresentation() {
        for kind in IslandPetKind.allCases {
            let cycleDuration = PetBehaviorSchedule.cycleDuration(for: kind)
            for presentation in IslandPresentation.allCases {
                let size = presentation.defaultSize
                let rect = CGRect(origin: .zero, size: size)
                for elapsed in stride(from: 0.0, through: cycleDuration, by: 0.25) {
                    let behavior = PetBehaviorSchedule.sample(at: elapsed, kind: kind)
                    for progress in [0.0, 1.0] {
                        let pose = PetPerimeterGeometry.pose(
                            progress: progress,
                            in: rect,
                            presentation: presentation,
                            notchHeight: 34
                        )
                        let placement = PetVisualGeometry.placement(
                            for: pose,
                            travelTangent: pose.tangent,
                            behavior: behavior,
                            kind: kind
                        )
                        let visibleBounds = PetVisualGeometry.visibleArtworkBounds(
                            placement: placement,
                            behavior: behavior,
                            kind: kind
                        )

                        XCTAssertGreaterThanOrEqual(
                            visibleBounds.minY,
                            0,
                            "\(kind.rawValue) / \(presentation.rawValue) crossed the top edge"
                        )
                        XCTAssertGreaterThanOrEqual(visibleBounds.minX, -68)
                        XCTAssertLessThanOrEqual(visibleBounds.maxX, size.width + 68)
                        XCTAssertLessThanOrEqual(visibleBounds.maxY, size.height + 68)
                    }
                }
            }
        }
    }

    func testGroundedPetFootTouchesEveryPointOfTheUPath() {
        for presentation in IslandPresentation.allCases {
            let rect = CGRect(origin: .zero, size: presentation.defaultSize)
            for kind in IslandPetKind.allCases {
                let firstWalk = PetBehaviorSchedule.sample(at: 0.000_001, kind: kind)
                for gaitFrame in 0..<60 {
                    let behavior = PetBehaviorSchedule.sample(
                        at: firstWalk.episodeDuration * Double(gaitFrame) / 60,
                        kind: kind
                    )
                    let gait = PetGaitGeometry.pose(
                        progress: behavior.episodeProgress,
                        motionEnvelope: behavior.motionEnvelope,
                        supportFootX: kind.supportFoot.x,
                        leanAmplitude: kind.gaitLeanAmplitude
                    )
                    for index in 0...200 {
                        let pose = PetPerimeterGeometry.pose(
                            progress: Double(index) / 200,
                            in: rect,
                            presentation: presentation,
                            notchHeight: 34
                        )
                        let placement = PetVisualGeometry.placement(
                            for: pose,
                            travelTangent: pose.tangent,
                            behavior: behavior,
                            kind: kind
                        )
                        let radians = CGFloat(placement.rotationDegrees * .pi / 180)
                        let transformedFoot = CGPoint(
                            x: placement.center.x
                                + cos(radians) * gait.contactOffset
                                - sin(radians) * kind.supportFoot.y,
                            y: placement.center.y
                                + sin(radians) * gait.contactOffset
                                + cos(radians) * kind.supportFoot.y
                        )

                        XCTAssertEqual(transformedFoot.x, pose.anchor.x, accuracy: 0.000_1)
                        XCTAssertEqual(transformedFoot.y, pose.anchor.y, accuracy: 0.000_1)
                    }
                }
            }
        }
    }

    private func visualAngleDelta(_ lhs: Double, _ rhs: Double) -> Double {
        let remainder = abs((lhs - rhs).truncatingRemainder(dividingBy: 360))
        return min(remainder, 360 - remainder)
    }
}
