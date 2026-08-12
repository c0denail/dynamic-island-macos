import SwiftUI

struct IslandRootView: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var theme: IslandTheme

    var body: some View {
        ZStack(alignment: .top) {
            islandShape
                .fill(IslandPalette.background)

            content
        }
        .contentShape(Rectangle())
        .foregroundStyle(theme.textColor)
        .environment(\.islandHUDColor, theme.hudColor)
        .environment(\.islandTextColor, theme.textColor)
        .environment(\.islandHUDContrastingColor, theme.hudContrastingColor)
        .onTapGesture {
            guard island.presentation != .expanded else { return }
            island.openContextualActivity()
        }
        .onHover(perform: island.handleHover)
        .contextMenu {
            Button("Medya") { island.open(.media) }
            Button("Sayaç") { island.open(.timer) }
            Divider()
            Button("Küçült") { island.collapse() }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dynamic Island")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard island.presentation != .expanded else { return }
            island.openContextualActivity()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch island.presentation {
        case .mini:
            if island.hasPhysicalNotch {
                Color.clear
                    .accessibilityLabel("Gizli Dynamic Island etkinleştiricisi")
            } else {
                MiniIslandView()
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        case .compact:
            CompactIslandView()
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .expanded:
            if island.isPresentationAnimating {
                // Expanded controls have a large intrinsic size. Deferring them
                // prevents AppKit from snapping the panel halfway open before
                // the frame animation has drawn its first interpolated frame.
                Color.clear
            } else {
                ExpandedIslandView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }

    private var islandShape: NotchIslandShape {
        NotchIslandShape(
            presentation: island.presentation,
            notchWidth: island.notchWidth,
            notchHeight: island.notchHeight
        )
    }
}

struct NotchIslandShape: InsettableShape {
    let presentation: IslandPresentation
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius: CGFloat = presentation == .expanded ? 34 : bounds.height / 2

        guard presentation == .expanded else {
            return Path(roundedRect: bounds, cornerRadius: radius, style: .continuous)
        }

        let neck = min(max(150, notchWidth), bounds.width - 70)
        let neckLeft = bounds.midX - neck / 2
        let neckRight = bounds.midX + neck / 2
        let shoulderY = min(max(30, notchHeight * 0.9), bounds.height * 0.24)
        let lowerY = bounds.maxY - radius

        var path = Path()
        path.move(to: CGPoint(x: neckLeft + 12, y: bounds.minY))
        path.addLine(to: CGPoint(x: neckRight - 12, y: bounds.minY))
        path.addQuadCurve(
            to: CGPoint(x: neckRight, y: bounds.minY + 12),
            control: CGPoint(x: neckRight, y: bounds.minY)
        )
        path.addCurve(
            to: CGPoint(x: bounds.maxX - radius * 0.55, y: shoulderY),
            control1: CGPoint(x: neckRight, y: shoulderY * 0.78),
            control2: CGPoint(x: bounds.maxX - radius * 1.8, y: shoulderY * 0.48)
        )
        path.addCurve(
            to: CGPoint(x: bounds.maxX, y: shoulderY + radius * 0.8),
            control1: CGPoint(x: bounds.maxX - radius * 0.18, y: shoulderY + 2),
            control2: CGPoint(x: bounds.maxX, y: shoulderY + radius * 0.28)
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: lowerY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY),
            control: CGPoint(x: bounds.maxX, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX + radius, y: bounds.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX, y: lowerY),
            control: CGPoint(x: bounds.minX, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX, y: shoulderY + radius * 0.8))
        path.addCurve(
            to: CGPoint(x: bounds.minX + radius * 0.55, y: shoulderY),
            control1: CGPoint(x: bounds.minX, y: shoulderY + radius * 0.28),
            control2: CGPoint(x: bounds.minX + radius * 0.18, y: shoulderY + 2)
        )
        path.addCurve(
            to: CGPoint(x: neckLeft, y: bounds.minY + 12),
            control1: CGPoint(x: bounds.minX + radius * 1.8, y: shoulderY * 0.48),
            control2: CGPoint(x: neckLeft, y: shoulderY * 0.78)
        )
        path.addQuadCurve(
            to: CGPoint(x: neckLeft + 12, y: bounds.minY),
            control: CGPoint(x: neckLeft, y: bounds.minY)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NotchIslandShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
