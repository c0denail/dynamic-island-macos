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

    func testPetAvatarAndRopeStayContinuousAroundCorners() {
        let rect = CGRect(x: 40, y: 0, width: 680, height: 418)
        var previousPose = PetPerimeterGeometry.pose(progress: 0, in: rect)
        var previousCenter = PetPerimeterGeometry.hangingCenter(for: previousPose)
        var previousRotation = PetPerimeterGeometry.avatarRotation(for: previousPose)
        var largestCenterStep: CGFloat = 0
        var largestRotationStep: Double = 0

        for index in 1...2_000 {
            let pose = PetPerimeterGeometry.pose(progress: Double(index) / 2_000, in: rect)
            let center = PetPerimeterGeometry.hangingCenter(for: pose)
            let rotation = PetPerimeterGeometry.avatarRotation(for: pose)
            largestCenterStep = max(largestCenterStep, hypot(center.x - previousCenter.x, center.y - previousCenter.y))
            largestRotationStep = max(largestRotationStep, abs(rotation - previousRotation))
            previousPose = pose
            previousCenter = center
            previousRotation = rotation
        }

        XCTAssertLessThan(largestCenterStep, 1.5)
        XCTAssertLessThan(largestRotationStep, 0.2)
    }

    func testPetAvatarNeverCrossesTopForEveryPresentation() {
        for presentation in IslandPresentation.allCases {
            let size = presentation.defaultSize
            let rect = CGRect(origin: .zero, size: size)
            for index in 0...500 {
                let pose = PetPerimeterGeometry.pose(
                    progress: Double(index) / 500,
                    in: rect,
                    presentation: presentation,
                    notchHeight: 34
                )
                let center = PetPerimeterGeometry.hangingCenter(for: pose, swing: 3.4)
                XCTAssertGreaterThanOrEqual(center.y - 14, 0, "\(presentation.rawValue) crossed the top edge")
                XCTAssertGreaterThanOrEqual(center.x - 14, -44)
                XCTAssertLessThanOrEqual(center.x + 14, size.width + 44)
                XCTAssertLessThanOrEqual(center.y + 14, size.height + 52)
            }
        }
    }
}
