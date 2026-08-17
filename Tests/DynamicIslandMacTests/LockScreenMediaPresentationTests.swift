import CoreGraphics
import XCTest
@testable import DynamicIslandMac

final class LockScreenMediaPresentationTests: XCTestCase {
    func testLockAndUnlockEventsDriveVisibilityWithoutChangingFeatureInputs() {
        var state = LockScreenMediaPresentationState(
            isPreviewing: false,
            isEnabled: true,
            hasActiveMedia: true
        )

        XCTAssertEqual(state.session, .unknown)
        XCTAssertFalse(state.shouldShow)

        state.apply(.lockDetected)

        XCTAssertEqual(state.session, .locked)
        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.shouldShow)

        state.apply(.unlockDetected)

        XCTAssertEqual(state.session, .unlocked)
        XCTAssertFalse(state.isLocked)
        XCTAssertFalse(state.shouldShow)
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.hasActiveMedia)
    }

    func testDuplicateSessionEventsAreIdempotent() {
        var state = LockScreenMediaPresentationState()

        state.apply(.lockDetected)
        state.apply(.lockDetected)
        XCTAssertEqual(state.session, .locked)

        state.apply(.unlockDetected)
        state.apply(.unlockDetected)
        XCTAssertEqual(state.session, .unlocked)
    }

    func testRuntimeVisibilityRequiresLockEnabledFeatureAndActiveMedia() {
        for isLocked in [false, true] {
            for isEnabled in [false, true] {
                for hasActiveMedia in [false, true] {
                    let expected = isLocked && isEnabled && hasActiveMedia
                    XCTAssertEqual(
                        LockScreenMediaPresentationState.shouldShow(
                            isLocked: isLocked,
                            isPreviewing: false,
                            isEnabled: isEnabled,
                            hasActiveMedia: hasActiveMedia
                        ),
                        expected
                    )
                }
            }
        }
    }

    func testPreviewIsVisibleOutsideRuntimeEligibility() {
        XCTAssertTrue(
            LockScreenMediaPresentationState.shouldShow(
                isLocked: false,
                isPreviewing: true,
                isEnabled: false,
                hasActiveMedia: false
            )
        )
    }

    func testInactiveUserSessionNeverShowsMediaOrPreview() {
        XCTAssertFalse(
            LockScreenMediaPresentationState.shouldShow(
                isLocked: true,
                isPreviewing: true,
                isEnabled: true,
                hasActiveMedia: true,
                isSessionActive: false
            )
        )
    }

    func testDefaultCardFrameIsCenteredAndContainedInVisibleFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 24, width: 1512, height: 934)

        let frame = LockScreenMediaPresentationState.cardFrame(
            screenFrame: screen,
            visibleFrame: visible,
            cardSize: CGSize(width: 650, height: 240)
        )

        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.001)
        XCTAssertLessThan(frame.midY, visible.midY)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.size, CGSize(width: 650, height: 240))
    }

    func testCardFrameHandlesOffsetDisplaysAndInvalidVisibleFrame() {
        let screen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)

        let frame = LockScreenMediaPresentationState.cardFrame(
            screenFrame: screen,
            visibleFrame: .zero,
            cardSize: CGSize(width: 620, height: 230)
        )

        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001)
        XCTAssertTrue(screen.contains(frame))
    }

    func testCardShrinksResponsivelyInsideNarrowVisibleFrame() {
        let screen = CGRect(x: 0, y: 0, width: 430, height: 620)
        let visible = CGRect(x: 0, y: 20, width: 430, height: 580)

        let frame = LockScreenMediaPresentationState.cardFrame(
            screenFrame: screen,
            visibleFrame: visible,
            cardSize: CGSize(width: 650, height: 240)
        )

        XCTAssertEqual(frame.width, 366, accuracy: 0.001)
        XCTAssertLessThanOrEqual(frame.height, 240)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 32)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 32)
        XCTAssertTrue(visible.contains(frame))
    }

    func testReservedFrameMovesCardWithoutOverlap() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let requestedSize = CGSize(width: 650, height: 240)
        let preferredFrame = LockScreenMediaPresentationState.cardFrame(
            screenFrame: screen,
            visibleFrame: screen,
            cardSize: requestedSize
        )

        let movedFrame = try XCTUnwrap(
            LockScreenMediaPresentationState.cardFrame(
                screenFrame: screen,
                visibleFrame: screen,
                cardSize: requestedSize,
                avoiding: [preferredFrame]
            )
        )

        XCTAssertNotEqual(movedFrame, preferredFrame)
        XCTAssertFalse(movedFrame.intersects(preferredFrame.insetBy(dx: -20, dy: -20)))
        XCTAssertTrue(screen.contains(movedFrame))
    }

    func testPlacementReturnsNilInsteadOfOverlappingFullyReservedArea() {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 700)

        let frame = LockScreenMediaPresentationState.cardFrame(
            screenFrame: screen,
            visibleFrame: screen,
            cardSize: CGSize(width: 620, height: 230),
            avoiding: [screen]
        )

        XCTAssertNil(frame)
    }
}
