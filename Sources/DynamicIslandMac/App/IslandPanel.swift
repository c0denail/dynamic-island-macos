import AppKit
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    var collapsedMouseDownHandler: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, collapsedMouseDownHandler?() == true {
            return
        }
        super.sendEvent(event)
    }
}

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandPanelCoordinator: NSObject {
    private struct FrameAnimation {
        let startFrame: NSRect
        let targetFrame: NSRect
        let startTime: TimeInterval
        let duration: TimeInterval
    }

    private let controller: IslandController
    private let panel: IslandPanel
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var frameAnimationTimer: Timer?
    private var frameAnimation: FrameAnimation?
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
        super.init()

        configurePanel()

        let root = IslandRootView()
            .environmentObject(controller)
            .environmentObject(controller.media)
            .environmentObject(controller.timer)
            .environmentObject(controller.clockTimer)
            .environmentObject(controller.system)
            .environmentObject(controller.connectivity)

        let hosting = IslandHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layerContentsRedrawPolicy = .duringViewResize
        hosting.layer?.drawsAsynchronously = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.collapsedMouseDownHandler = { [weak controller] in
            guard let controller, controller.presentation != .expanded else { return false }
            controller.openContextualActivity()
            return true
        }

        controller.$presentation
            .removeDuplicates()
            .sink { [weak self] presentation in
                guard let self else { return }
                if self.panel.isVisible {
                    // Publish the transition state before SwiftUI evaluates the
                    // newly selected presentation. Heavy expanded content can
                    // then wait for the window to reach its final geometry.
                    self.prepareForPresentationAnimation()
                }
                // Let SwiftUI commit the new presentation tree before the
                // window starts resizing it. This prevents AppKit from dropping
                // a frame request made reentrantly inside mouseDown delivery.
                DispatchQueue.main.async {
                    self.resize(for: presentation, animated: true)
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
        guard let screen = targetScreen else {
            stopPanelAnimation()
            return
        }
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
            frameAnimationTimer = nil
            frameAnimation = nil
            panel.setFrame(frame, display: true, animate: false)
            controller.setPresentationAnimating(false)
            return
        }

        animatePanel(to: frame, duration: presentation == .expanded ? 0.3 : 0.24)
    }

    private func animatePanel(to targetFrame: NSRect, duration: TimeInterval) {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        frameAnimation = nil
        let startFrame = panel.frame
        guard startFrame != targetFrame else {
            controller.setPresentationAnimating(false)
            return
        }

        controller.setPresentationAnimating(true)
        frameAnimation = FrameAnimation(
            startFrame: startFrame,
            targetFrame: targetFrame,
            startTime: ProcessInfo.processInfo.systemUptime,
            duration: max(0.01, duration)
        )

        // A stable 60 Hz cadence is smoother than asking the main run loop for
        // 120 forced SwiftUI redraws. Time-based interpolation also keeps the
        // motion correct when macOS occasionally coalesces a timer tick.
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(advanceFrameAnimation(_:)),
            userInfo: nil,
            repeats: true
        )

        timer.tolerance = 1.0 / 600.0
        frameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func prepareForPresentationAnimation() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        frameAnimation = nil
        controller.setPresentationAnimating(true)
    }

    @objc private func advanceFrameAnimation(_ timer: Timer) {
        guard let animation = frameAnimation else {
            timer.invalidate()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - animation.startTime
        let progress = min(1, max(0, elapsed / animation.duration))
        let eased = progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - pow(-2 * progress + 2, 3) / 2

        let startFrame = animation.startFrame
        let targetFrame = animation.targetFrame
        let frame = NSRect(
            x: startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * eased,
            y: startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * eased,
            width: startFrame.width + (targetFrame.width - startFrame.width) * eased,
            height: startFrame.height + (targetFrame.height - startFrame.height) * eased
        )

        // Let the layer-backed hosting view schedule its redraw without
        // synchronously blocking input delivery on every interpolation.
        panel.setFrame(frame, display: false, animate: false)

        if progress >= 1 {
            timer.invalidate()
            frameAnimationTimer = nil
            frameAnimation = nil
            panel.setFrame(targetFrame, display: true, animate: false)
            controller.setPresentationAnimating(false)
        }
    }

    private func stopPanelAnimation() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        frameAnimation = nil
        controller.setPresentationAnimating(false)
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
                  Date().timeIntervalSince(self.controller.lastExpansionDate) > 0.22,
                  !self.panel.frame.contains(NSEvent.mouseLocation)
            else { return }
            self.controller.collapse()
        }

        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }

                // The physical camera notch can own the actual mouse event even
                // while our transparent panel visually occupies that frame. A
                // global mouse-down fallback keeps the whole notch footprint
                // clickable, including its otherwise non-hit-testable center.
                if event.type == .leftMouseDown,
                   self.controller.presentation != .expanded,
                   self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.controller.openContextualActivity()
                    return
                }
                collapseIfOutside()
            }
        }
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            collapseIfOutside()
            return event
        }
    }
}
