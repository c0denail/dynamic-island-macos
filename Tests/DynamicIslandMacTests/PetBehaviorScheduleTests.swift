import CoreGraphics
import XCTest
@testable import DynamicIslandMac

final class PetBehaviorScheduleTests: XCTestCase {
    func testFivePetPersonalitiesHaveStableIdentifiers() {
        XCTAssertEqual(
            IslandPetKind.allCases.map(\.rawValue),
            ["byte", "ember", "nova", "moss", "patch"]
        )
    }

    func testLegacyPetSelectionsMigrateToByte() {
        for oldSelection in ["orbit", "neko", "boo", "unknown"] {
            XCTAssertEqual(IslandPetKind.resolved(oldSelection), .byte)
        }
        XCTAssertEqual(IslandPetKind.resolved("nova"), .nova)
    }

    func testScheduleIsDeterministicForEveryPet() {
        let timestamps: [TimeInterval] = [0, 1.25, 8.75, 47.125, 19_876.543]

        for kind in IslandPetKind.allCases {
            for timestamp in timestamps {
                XCTAssertEqual(
                    PetBehaviorSchedule.sample(at: timestamp, kind: kind),
                    PetBehaviorSchedule.sample(at: timestamp, kind: kind)
                )
            }
        }
    }

    func testEveryPetGetsADistinctKindSeededSchedule() {
        var fingerprints = Set<String>()

        for kind in IslandPetKind.allCases {
            var cursor: TimeInterval = 0
            var components: [String] = []
            for _ in 0..<PetBehavior.allCases.count {
                let sample = PetBehaviorSchedule.sample(at: cursor + 0.001, kind: kind)
                components.append("\(sample.behavior.rawValue):\(sample.episodeDuration)")
                cursor = sample.episodeStart + sample.episodeDuration
            }
            fingerprints.insert(components.joined(separator: "|"))
        }

        XCTAssertEqual(fingerprints.count, IslandPetKind.allCases.count)
    }

    func testChoreographyWalksThenSuddenlyRollsAndDropsTheRope() {
        for kind in IslandPetKind.allCases {
            let episodes = firstCycle(for: kind)
            XCTAssertEqual(episodes.count, 45)
            XCTAssertEqual(Set(episodes.map(\.behavior)), Set(PetBehavior.allCases))
            XCTAssertEqual(episodes.filter { $0.behavior == .walk }.count, 20)

            for blockStart in stride(from: 0, to: episodes.count, by: 9) {
                XCTAssertEqual(
                    Array(episodes[blockStart..<(blockStart + 4)].map(\.behavior)),
                    [.walk, .roll, .ropeSwing, .walk]
                )
            }

            for (index, episode) in episodes.enumerated() {
                if episode.behavior == .walk {
                    XCTAssertGreaterThanOrEqual(episode.episodeDuration, 8)
                    XCTAssertLessThanOrEqual(episode.episodeDuration, 13)
                    continue
                }

                let previous = episodes[(index - 1 + episodes.count) % episodes.count].behavior
                let next = episodes[(index + 1) % episodes.count].behavior
                switch episode.behavior {
                case .roll:
                    XCTAssertEqual(previous, .walk)
                    XCTAssertEqual(next, .ropeSwing)
                case .ropeSwing:
                    XCTAssertEqual(previous, .roll)
                    XCTAssertEqual(next, .walk)
                case .hop, .idle, .peek:
                    XCTAssertEqual(previous, .walk)
                    XCTAssertEqual(next, .walk)
                case .walk:
                    break
                }
            }
        }
    }

    func testGroundedWalkNeverOffsetsOrRescalesAwayFromSurface() {
        for kind in IslandPetKind.allCases {
            for episode in firstCycle(for: kind) where episode.behavior == .walk {
                for frame in 0..<120 {
                    let progress = (Double(frame) + 0.5) / 120
                    let sample = PetBehaviorSchedule.sample(
                        at: episode.episodeStart + episode.episodeDuration * progress,
                        kind: kind
                    )

                    XCTAssertEqual(sample.behavior, .walk)
                    XCTAssertEqual(sample.tangentOffset, 0, accuracy: 0.000_001)
                    XCTAssertEqual(sample.outwardOffset, 0, accuracy: 0.000_001)
                    XCTAssertEqual(sample.scale, 1, accuracy: 0.000_001)
                    XCTAssertEqual(sample.ropeVisibility, 0, accuracy: 0.000_001)
                    XCTAssertEqual(sample.ropeDrop, 0, accuracy: 0.000_001)
                }
            }
        }
    }

    func testRollIsShortFastAndVisuallyReturnsToNeutralAngle() {
        for kind in IslandPetKind.allCases {
            for episode in firstCycle(for: kind) where episode.behavior == .roll {
                XCTAssertGreaterThanOrEqual(episode.episodeDuration, 1.15)
                XCTAssertLessThanOrEqual(episode.episodeDuration, 1.8)

                let middle = PetBehaviorSchedule.sample(
                    at: episode.episodeStart + episode.episodeDuration / 2,
                    kind: kind
                )
                let finalFrame = PetBehaviorSchedule.sample(
                    at: episode.episodeStart + episode.episodeDuration - 0.000_01,
                    kind: kind
                )
                XCTAssertEqual(middle.routeSpeedMultiplier, 4.8, accuracy: 0.000_001)
                XCTAssertEqual(visualAngleDistanceFromNeutral(finalFrame.rotationDegrees), 0, accuracy: 0.01)
            }
        }
    }

    func testRopePausesRouteAndUsesLongDropWithVisibleHold() {
        for kind in IslandPetKind.allCases {
            for episode in firstCycle(for: kind) where episode.behavior == .ropeSwing {
                XCTAssertGreaterThanOrEqual(episode.episodeDuration, 4.8)
                XCTAssertLessThanOrEqual(episode.episodeDuration, 7)

                let progressPoints: [Double] = [0.05, 0.25, 0.5, 0.75, 0.95]
                let samples = progressPoints.map { progress in
                    PetBehaviorSchedule.sample(
                        at: episode.episodeStart + episode.episodeDuration * progress,
                        kind: kind
                    )
                }
                let firstDistance = samples[0].routeDistance
                for sample in samples {
                    XCTAssertEqual(sample.routeDistance, firstDistance, accuracy: 0.000_001)
                    XCTAssertEqual(sample.routeSpeedMultiplier, 0, accuracy: 0.000_001)
                }

                let middle = samples[2]
                XCTAssertGreaterThanOrEqual(middle.ropeDrop, 27)
                XCTAssertEqual(middle.outwardOffset, middle.ropeDrop, accuracy: 0.000_001)
                XCTAssertEqual(middle.ropeVisibility, 1, accuracy: 0.000_001)
            }
        }
    }

    func testRouteAndVisualTransformsStayContinuousAtEpisodeBoundaries() {
        for kind in IslandPetKind.allCases {
            var boundary: TimeInterval = 0

            for _ in 0..<(PetBehavior.allCases.count * 5) {
                let episode = PetBehaviorSchedule.sample(at: boundary + 0.001, kind: kind)
                boundary = episode.episodeStart + episode.episodeDuration

                let before = PetBehaviorSchedule.sample(at: boundary - 0.000_01, kind: kind)
                let after = PetBehaviorSchedule.sample(at: boundary, kind: kind)

                XCTAssertLessThan(abs(after.routeDistance - before.routeDistance), 0.001)
                XCTAssertLessThan(before.routeSpeedMultiplier, 0.001)
                XCTAssertLessThan(abs(before.tangentOffset), 0.001)
                XCTAssertLessThan(abs(before.outwardOffset), 0.001)
                XCTAssertLessThan(visualAngleDistanceFromNeutral(before.rotationDegrees), 0.01)
                XCTAssertEqual(before.scale, 1, accuracy: 0.001)
                XCTAssertLessThan(before.ropeVisibility, 0.001)
                XCTAssertLessThan(before.ropeDrop, 0.001)

                XCTAssertEqual(after.tangentOffset, 0, accuracy: 0.000_001)
                XCTAssertEqual(after.routeSpeedMultiplier, 0, accuracy: 0.000_001)
                XCTAssertEqual(after.outwardOffset, 0, accuracy: 0.000_001)
                XCTAssertEqual(after.rotationDegrees, 0, accuracy: 0.000_001)
                XCTAssertEqual(after.scale, 1, accuracy: 0.000_001)
                XCTAssertEqual(after.ropeVisibility, 0, accuracy: 0.000_001)
                XCTAssertEqual(after.ropeDrop, 0, accuracy: 0.000_001)
            }
        }
    }

    func testBehaviorSamplesExposeExpectedIndependentMotionControls() throws {
        var samples: [PetBehavior: PetBehaviorSample] = [:]
        var cursor: TimeInterval = 0

        while samples.count < PetBehavior.allCases.count {
            let episode = PetBehaviorSchedule.sample(at: cursor + 0.001, kind: .byte)
            let middle = PetBehaviorSchedule.sample(
                at: episode.episodeStart + episode.episodeDuration * 0.5,
                kind: .byte
            )
            samples[middle.behavior] = middle
            cursor = episode.episodeStart + episode.episodeDuration
        }

        XCTAssertGreaterThan(try XCTUnwrap(samples[.walk]).routeSpeedMultiplier, 0)
        XCTAssertGreaterThan(try XCTUnwrap(samples[.roll]).routeSpeedMultiplier, 1)
        XCTAssertGreaterThan(try XCTUnwrap(samples[.ropeSwing]).ropeVisibility, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(samples[.ropeSwing]).ropeDrop, 26)
        XCTAssertGreaterThan(try XCTUnwrap(samples[.hop]).outwardOffset, 0)
        XCTAssertEqual(try XCTUnwrap(samples[.idle]).routeSpeedMultiplier, 0)
        XCTAssertLessThan(try XCTUnwrap(samples[.peek]).outwardOffset, 0)
    }

    func testBehaviorOffsetsNeverMovePetAcrossForbiddenTopRoute() {
        let kind = IslandPetKind.nova
        let cycleDuration = PetBehaviorSchedule.cycleDuration(for: kind)
        let frameCount = Int(ceil(cycleDuration * 120))

        for presentation in IslandPresentation.allCases {
            let size = presentation.defaultSize
            let rect = CGRect(origin: .zero, size: size)

            for frame in 0...frameCount {
                let sample = PetBehaviorSchedule.sample(
                    at: min(cycleDuration, Double(frame) / 120),
                    kind: kind
                )

                // The two open-route endpoints are the closest possible
                // points to the forbidden top edge. Both directions matter
                // because their tangent vectors point in opposite directions.
                for routeProgress in [0.0, 1.0] {
                    let pose = PetPerimeterGeometry.pose(
                        progress: routeProgress,
                        in: rect,
                        presentation: presentation,
                        notchHeight: 34
                    )
                    let placement = PetVisualGeometry.placement(
                        for: pose,
                        travelTangent: pose.tangent,
                        behavior: sample,
                        kind: kind
                    )
                    let visibleBounds = PetVisualGeometry.visibleArtworkBounds(
                        placement: placement,
                        behavior: sample,
                        kind: kind
                    )

                    XCTAssertGreaterThanOrEqual(
                        visibleBounds.minY,
                        0,
                        "\(presentation.rawValue) / \(sample.behavior.rawValue) crossed the top edge"
                    )
                }
            }
        }
    }

    private func visualAngleDistanceFromNeutral(_ degrees: Double) -> Double {
        let remainder = abs(degrees.truncatingRemainder(dividingBy: 360))
        return min(remainder, 360 - remainder)
    }

    private func firstCycle(for kind: IslandPetKind) -> [PetBehaviorSample] {
        let cycleDuration = PetBehaviorSchedule.cycleDuration(for: kind)
        var cursor: TimeInterval = 0
        var samples: [PetBehaviorSample] = []

        while cursor < cycleDuration - 0.000_001 {
            let sample = PetBehaviorSchedule.sample(at: cursor + 0.000_001, kind: kind)
            samples.append(sample)
            let nextCursor = sample.episodeStart + sample.episodeDuration
            XCTAssertGreaterThan(nextCursor, cursor)
            cursor = nextCursor
        }

        return samples
    }
}
