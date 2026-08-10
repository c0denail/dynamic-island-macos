import AppKit
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandPanelCoordinator {
    private let controller: IslandController
    private let panel: IslandPanel
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var frameAnimationTimer: Timer?
    private var outsideGlobalMonitor: Any?
    private var outsideLocalMonitor: Any?

    init(controller: IslandController) {
        self.controller = controller
        panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: IslandPresentation.mini.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configurePanel()

        let root = IslandRootView()
            .environmentObject(controller)
            .environmentObject(controller.media)
            .environmentObject(controller.timer)
            .environmentObject(controller.clockTimer)
            .environmentObject(controller.system)
            .environmentObject(controller.connectivity)

        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layerContentsRedrawPolicy = .duringViewResize
        hosting.layer?.drawsAsynchronously = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        controller.$presentation
            .removeDuplicates()
            .sink { [weak self] presentation in
                DispatchQueue.main.async {
                    self?.resize(for: presentation, animated: true)
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resize(for: self.controller.presentation, animated: false)
            }
        }

        installOutsideClickMonitoring()
    }

    deinit {
        frameAnimationTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let outsideGlobalMonitor { NSEvent.removeMonitor(outsideGlobalMonitor) }
        if let outsideLocalMonitor { NSEvent.removeMonitor(outsideLocalMonitor) }
    }

    func show() {
        resize(for: controller.presentation, animated: false)
        panel.orderFrontRegardless()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // NSPanel's shadow follows the rectangular window frame rather than the
        // island mask, which leaves square hairlines around the notch.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
    }

    private func resize(for presentation: IslandPresentation, animated: Bool) {
        guard let screen = targetScreen else { return }
        var size = presentation.defaultSize
        let hasNotch = screenHasNotch(screen)
        let notchWidth = detectedNotchWidth(on: screen)
        let notchHeight = hasNotch ? max(32, screen.safeAreaInsets.top) : 30
        controller.updateDisplayMetrics(notchWidth: notchWidth, notchHeight: notchHeight, hasNotch: hasNotch)

        if presentation == .mini {
            size.width = hasNotch ? notchWidth : 190
            size.height = hasNotch ? notchHeight : 38
        } else if presentation == .compact {
            size.width = max(470, notchWidth + 288)
            size.height = max(40, notchHeight + 4)
        }

        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        let frame = NSRect(origin: origin, size: size)

        guard animated, panel.isVisible else {
            frameAnimationTimer?.invalidate()
            panel.setFrame(frame, display: true, animate: false)
            return
        }

        animatePanel(to: frame, duration: presentation == .expanded ? 0.3 : 0.24)
    }

    private func animatePanel(to targetFrame: NSRect, duration: TimeInterval) {
        frameAnimationTimer?.invalidate()
        let startFrame = panel.frame
        let startTime = Date.timeIntervalSinceReferenceDate

        guard startFrame != targetFrame else { return }

        let refreshRate = max(60, targetScreen?.maximumFramesPerSecond ?? 60)
        let timer = Timer(timeInterval: 1.0 / Double(refreshRate), repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = Date.timeIntervalSinceReferenceDate - startTime
            let progress = min(1, max(0, elapsed / duration))
            let eased = progress < 0.5
                ? 4 * progress * progress * progress
                : 1 - pow(-2 * progress + 2, 3) / 2

            let frame = NSRect(
                x: startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * eased,
                y: startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * eased,
                width: startFrame.width + (targetFrame.width - startFrame.width) * eased,
                height: startFrame.height + (targetFrame.height - startFrame.height) * eased
            )
            self.panel.setFrame(frame, display: true, animate: false)

            if progress >= 1 {
                timer.invalidate()
                self.panel.setFrame(targetFrame, display: true, animate: false)
            }
        }

        timer.tolerance = 0
        frameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var targetScreen: NSScreen? {
        if let notchedScreen = NSScreen.screens.first(where: screenHasNotch) {
            return notchedScreen
        }
        if let screenWithPointer = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return screenWithPointer
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func detectedNotchWidth(on screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              !left.isEmpty,
              !right.isEmpty
        else { return 182 }
        return max(170, right.minX - left.maxX)
    }

    private func screenHasNotch(_ screen: NSScreen) -> Bool {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return false }
        return !left.isEmpty && !right.isEmpty && screen.safeAreaInsets.top > 0
    }

    private func installOutsideClickMonitoring() {
        let collapseIfOutside: () -> Void = { [weak self] in
            guard let self,
                  self.controller.presentation == .expanded,
                  Date().timeIntervalSince(self.controller.lastExpansionDate) > 1.0,
                  !self.panel.frame.contains(NSEvent.mouseLocation)
            else { return }
            self.controller.collapse()
        }

        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in collapseIfOutside() }
        }
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            collapseIfOutside()
            return event
        }
    }
}
