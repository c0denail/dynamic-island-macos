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
}
