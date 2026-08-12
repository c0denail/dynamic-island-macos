import AppKit
import Combine
import SwiftUI

struct IslandThemeColor: Equatable, Sendable {
    static let white = IslandThemeColor(red: 1, green: 1, blue: 1)

    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    init?(hex: String) {
        let normalized = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard normalized.count == 6, let value = UInt32(normalized, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var contrastingColor: Color {
        // Perceived luminance keeps labels readable on user-selected fills.
        (red * 0.299 + green * 0.587 + blue * 0.114) > 0.58 ? .black : .white
    }

    @MainActor
    init?(color: Color) {
        let source = NSColor(color)
        guard let converted = source.usingColorSpace(.sRGB) ?? source.usingColorSpace(.deviceRGB) else { return nil }
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent)
        )
    }
}

@MainActor
final class IslandTheme: ObservableObject {
    static let hudColorDefaultsKey = "islandThemeHUDColor"
    static let textColorDefaultsKey = "islandThemeTextColor"

    @Published private(set) var hud = IslandThemeColor.white
    @Published private(set) var text = IslandThemeColor.white

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hud = defaults.string(forKey: Self.hudColorDefaultsKey)
            .flatMap(IslandThemeColor.init(hex:)) ?? .white
        text = defaults.string(forKey: Self.textColorDefaultsKey)
            .flatMap(IslandThemeColor.init(hex:)) ?? .white
    }

    var hudColor: Color { hud.color }
    var textColor: Color { text.color }
    var hudContrastingColor: Color { hud.contrastingColor }

    func setHUDColor(_ color: Color) {
        guard let value = IslandThemeColor(color: color) else { return }
        setHUDColor(value)
    }

    func setTextColor(_ color: Color) {
        guard let value = IslandThemeColor(color: color) else { return }
        setTextColor(value)
    }

    func setHUDColor(_ value: IslandThemeColor) {
        guard hud != value else { return }
        hud = value
        defaults.set(value.hex, forKey: Self.hudColorDefaultsKey)
    }

    func setTextColor(_ value: IslandThemeColor) {
        guard text != value else { return }
        text = value
        defaults.set(value.hex, forKey: Self.textColorDefaultsKey)
    }

    func reset() {
        setHUDColor(IslandThemeColor.white)
        setTextColor(IslandThemeColor.white)
    }
}

private struct IslandHUDColorKey: EnvironmentKey {
    static let defaultValue = Color.white
}

private struct IslandTextColorKey: EnvironmentKey {
    static let defaultValue = Color.white
}

private struct IslandHUDContrastingColorKey: EnvironmentKey {
    static let defaultValue = Color.black
}

extension EnvironmentValues {
    var islandHUDColor: Color {
        get { self[IslandHUDColorKey.self] }
        set { self[IslandHUDColorKey.self] = newValue }
    }

    var islandTextColor: Color {
        get { self[IslandTextColorKey.self] }
        set { self[IslandTextColorKey.self] = newValue }
    }

    var islandHUDContrastingColor: Color {
        get { self[IslandHUDContrastingColorKey.self] }
        set { self[IslandHUDContrastingColorKey.self] = newValue }
    }
}
