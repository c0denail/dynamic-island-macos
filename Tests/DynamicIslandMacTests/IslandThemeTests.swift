import XCTest
@testable import DynamicIslandMac

@MainActor
final class IslandThemeTests: XCTestCase {
    func testThemeColorHexRoundTrip() throws {
        let color = try XCTUnwrap(IslandThemeColor(hex: "#1A80E6"))

        XCTAssertEqual(color.hex, "#1A80E6")
        XCTAssertNil(IslandThemeColor(hex: "invalid"))
    }

    func testThemePersistsBothSelections() throws {
        let suiteName = "DynamicIslandMacTests.Theme.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let theme = IslandTheme(defaults: defaults)
        XCTAssertEqual(theme.hud, .white)
        XCTAssertEqual(theme.text, .white)

        let hud = try XCTUnwrap(IslandThemeColor(hex: "#35C7F2"))
        let text = try XCTUnwrap(IslandThemeColor(hex: "#F2D56B"))
        theme.setHUDColor(hud)
        theme.setTextColor(text)

        let restored = IslandTheme(defaults: defaults)
        XCTAssertEqual(restored.hud, hud)
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(defaults.string(forKey: IslandTheme.hudColorDefaultsKey), hud.hex)
        XCTAssertEqual(defaults.string(forKey: IslandTheme.textColorDefaultsKey), text.hex)
    }
}
