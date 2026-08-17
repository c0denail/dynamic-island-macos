import AppKit
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

private extension Notification.Name {
    static let dynamicIslandScreenDidLock = Notification.Name("com.apple.screenIsLocked")
    static let dynamicIslandScreenDidUnlock = Notification.Name("com.apple.screenIsUnlocked")
    static let previewLockScreenMedia = Notification.Name("dev.c0denail.DynamicIslandMac.previewLockScreenMedia")
}

private final class LockScreenMediaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LockScreenMediaHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the small interactive player shown by the current user's app while the
/// macOS session is locked. This deliberately mirrors the existing media
/// service instead of publishing a second Now Playing session, which would
/// replace Chrome, Spotify, Music, or the browser as the command destination.
@MainActor
final class LockScreenMediaCoordinator {
    private let controller: IslandController
    private let panel: LockScreenMediaPanel
    private var previewPanel: LockScreenMediaPanel?
    private var cancellables = Set<AnyCancellable>()
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var previewTask: Task<Void, Never>?
    private var lockVerificationTask: Task<Void, Never>?
    private var lockStateMonitorTask: Task<Void, Never>?
    private var hasDelegatedLockPanel = false
    private var isLocked = false
    private var isPreviewing = false
    private var isSessionActive = true
    private var started = false

    init(controller: IslandController) {
        self.controller = controller
        panel = LockScreenMediaPanel(
            contentRect: NSRect(origin: .zero, size: Self.cardSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configurePanel(panel, canBecomeVisibleWithoutLogin: true)
        updateRootView(on: panel, isPreview: false)
    }

    func start() {
        guard !started else { return }
        started = true
        installObservers()
        isSessionActive = Self.currentSessionIsActive
        prepareLockPanelSpaceIfNeeded()
        if isSessionActive && Self.currentSessionIsLocked {
            activateLockedPresentation()
        } else {
            isLocked = false
            updateVisibility(animated: false)
        }

        if CommandLine.arguments.contains("--preview-lock-screen-media") {
            preview(duration: 30)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        previewTask?.cancel()
        previewTask = nil
        lockVerificationTask?.cancel()
        lockVerificationTask = nil
        lockStateMonitorTask?.cancel()
        lockStateMonitorTask = nil
        isPreviewing = false
        panel.orderOut(nil)
        previewPanel?.orderOut(nil)
        cancellables.removeAll()

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributedCenter.removeObserver)
        distributedObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()

        localObservers.forEach(NotificationCenter.default.removeObserver)
        localObservers.removeAll()
    }

    func preview(duration: TimeInterval = 12) {
        previewTask?.cancel()
        isPreviewing = true
        updateRootView()
        updateVisibility(animated: true)

        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.isPreviewing = false
            self.updateRootView()
            self.updateVisibility(animated: true)
        }
    }

    private func configurePanel(
        _ target: LockScreenMediaPanel,
        canBecomeVisibleWithoutLogin: Bool
    ) {
        target.isOpaque = false
        target.backgroundColor = .clear
        target.hasShadow = false
        target.hidesOnDeactivate = false
        target.canHide = false
        target.isReleasedWhenClosed = false
        target.titleVisibility = .hidden
        target.titlebarAppearsTransparent = true
        target.animationBehavior = .none
        target.isMovable = false
        target.isMovableByWindowBackground = false
        target.isExcludedFromWindowsMenu = true
        target.becomesKeyOnlyIfNeeded = true
        target.worksWhenModal = true
        target.acceptsMouseMovedEvents = true
        target.ignoresMouseEvents = false
        target.canBecomeVisibleWithoutLogin = canBecomeVisibleWithoutLogin
        target.level = .screenSaver
        target.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
    }

    private func installObservers() {
        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.append(
            distributedCenter.addObserver(
                forName: .dynamicIslandScreenDidLock,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenDidLock()
                }
            }
        )
        distributedObservers.append(
            distributedCenter.addObserver(
                forName: .dynamicIslandScreenDidUnlock,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenDidUnlock()
                }
            }
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A resigned Aqua session can belong to a different user
                    // after fast user switching. Fail closed so this user's
                    // media metadata is never drawn into another session.
                    guard let self else { return }
                    self.isSessionActive = false
                    self.isLocked = false
                    self.isPreviewing = false
                    self.previewTask?.cancel()
                    self.previewTask = nil
                    self.lockVerificationTask?.cancel()
                    self.lockVerificationTask = nil
                    self.lockStateMonitorTask?.cancel()
                    self.lockStateMonitorTask = nil
                    self.panel.orderOut(nil)
                    self.previewPanel?.orderOut(nil)
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSessionActive = true
                    if Self.currentSessionIsLocked {
                        self.screenDidLock()
                    } else {
                        self.screenDidUnlock()
                    }
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.isSessionActive else { return }
                    if Self.currentSessionIsLocked {
                        self.activateLockedPresentation()
                    } else {
                        self.screenDidUnlock()
                    }
                }
            }
        )

        localObservers.append(
            NotificationCenter.default.addObserver(
                forName: .previewLockScreenMedia,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.preview()
                }
            }
        )
        localObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.positionPanel()
                }
            }
        )
        localObservers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateVisibility(animated: true)
                }
            }
        )

        controller.media.$source
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateVisibility(animated: true) }
            .store(in: &cancellables)
    }

    private func screenDidLock() {
        guard isSessionActive else { return }
        lockVerificationTask?.cancel()
        // Even a spoofed lock notification may safely dismiss Settings
        // preview. Closing it synchronously guarantees the ordinary preview
        // Space never overlaps the real lock transition while CGSession's bit
        // is still catching up.
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        previewPanel?.orderOut(nil)

        if Self.currentSessionIsActive && Self.currentSessionIsLocked {
            activateLockedPresentation()
            return
        }

        // The distributed notification can arrive just before CGSession has
        // committed its lock bit. It can also be spoofed by another process,
        // so never enter the private lock-screen Space until the real session
        // state confirms the transition.
        isLocked = false
        panel.orderOut(nil)
        lockVerificationTask = Task { @MainActor [weak self] in
            for _ in 0..<12 {
                guard !Task.isCancelled, let self, self.isSessionActive else { return }
                if Self.currentSessionIsActive && Self.currentSessionIsLocked {
                    self.activateLockedPresentation()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func activateLockedPresentation() {
        guard isSessionActive,
              Self.currentSessionIsActive,
              Self.currentSessionIsLocked else {
            return
        }

        lockVerificationTask?.cancel()
        lockVerificationTask = nil
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        isLocked = true
        revalidateLockPanelSpace()
        controller.media.refresh()
        updateRootView()
        updateVisibility(animated: false)
        startLockStateMonitoring()
    }

    private func startLockStateMonitoring() {
        lockStateMonitorTask?.cancel()
        lockStateMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                guard self.isSessionActive,
                      Self.currentSessionIsActive,
                      Self.currentSessionIsLocked else {
                    self.screenDidUnlock()
                    return
                }
            }
        }
    }

    private func screenDidUnlock() {
        lockVerificationTask?.cancel()
        lockVerificationTask = nil
        lockStateMonitorTask?.cancel()
        lockStateMonitorTask = nil
        isLocked = false
        isPreviewing = false
        previewTask?.cancel()
        previewTask = nil
        updateRootView()
        updateVisibility(animated: false)
    }

    private func updateVisibility(animated: Bool) {
        prepareLockPanelSpaceIfNeeded()

        let shouldShowLockedCard = LockScreenMediaPresentationState.shouldShow(
            isLocked: isLocked,
            isPreviewing: false,
            isEnabled: lockScreenMediaEnabled,
            hasActiveMedia: controller.media.hasActiveSource,
            isSessionActive: isSessionActive
        )
        let shouldShowPreview = isSessionActive && isPreviewing && !isLocked

        if shouldShowLockedCard,
           Self.currentSessionIsActive,
           Self.currentSessionIsLocked {
            previewPanel?.orderOut(nil)
            positionPanel(panel)

            if hasDelegatedLockPanel {
                show(panel, animated: false)
            } else {
                // A normal AppKit window cannot reliably cross into the
                // loginwindow Space. Never compensate with a near-maximum
                // global level: that could cover authentication UI without
                // making the card reliably visible. Unsupported systems fail
                // closed while Settings preview remains available.
                panel.orderOut(nil)
            }
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            if !hasDelegatedLockPanel {
                panel.level = .screenSaver
            }
        }

        if shouldShowPreview {
            let preview = ensurePreviewPanel()
            updateRootView(on: preview, isPreview: true)
            positionPanel(preview)
            show(preview, animated: animated)
        } else {
            previewPanel?.orderOut(nil)
            previewPanel?.alphaValue = 1
        }
    }

    /// Atoll/SkyLight-style lock Spaces are prepared while the Aqua session is
    /// still active, then the same hidden window is retained for the lifetime
    /// of the process. Creating or reattaching it during the lock transition is
    /// less reliable and can race loginwindow's Space switch.
    private func prepareLockPanelSpaceIfNeeded() {
        guard lockScreenMediaEnabled, !hasDelegatedLockPanel else { return }
        revalidateLockPanelSpace()
    }

    private func revalidateLockPanelSpace() {
        panel.level = Self.lockScreenSpaceWindowLevel
        hasDelegatedLockPanel = LockScreenSpaceBridge.shared.delegate(panel)
        if !hasDelegatedLockPanel {
            panel.level = .screenSaver
        }
    }

    private func show(_ target: LockScreenMediaPanel, animated: Bool) {
        if target.isVisible {
            target.orderFrontRegardless()
            return
        }
        if animated {
            target.alphaValue = 0
            target.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                target.animator().alphaValue = 1
            }
        } else {
            target.alphaValue = 1
            target.orderFrontRegardless()
        }
    }

    private func updateRootView() {
        updateRootView(on: panel, isPreview: false)
        if let previewPanel {
            updateRootView(on: previewPanel, isPreview: true)
        }
    }

    private func updateRootView(
        on target: LockScreenMediaPanel,
        isPreview: Bool
    ) {
        let dismissPreview: (() -> Void)? = isPreview ? { [weak self] in
            self?.isPreviewing = false
            self?.updateRootView()
            self?.updateVisibility(animated: true)
        } : nil
        let root = LockScreenMediaPlayerView(
            isPreview: isPreview,
            dismissPreview: dismissPreview
        )
        .environmentObject(controller.media)
        .environmentObject(controller.theme)

        guard let hosting = target.contentView as? LockScreenMediaHostingView<AnyView> else {
            let replacement = LockScreenMediaHostingView(rootView: AnyView(root))
            replacement.sizingOptions = []
            replacement.autoresizingMask = [.width, .height]
            replacement.wantsLayer = true
            replacement.layer?.backgroundColor = NSColor.clear.cgColor
            target.contentView = replacement
            return
        }
        hosting.rootView = AnyView(root)
    }

    private func ensurePreviewPanel() -> LockScreenMediaPanel {
        if let previewPanel {
            return previewPanel
        }

        let preview = LockScreenMediaPanel(
            contentRect: NSRect(origin: .zero, size: Self.cardSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel(preview, canBecomeVisibleWithoutLogin: false)
        updateRootView(on: preview, isPreview: true)
        previewPanel = preview
        return preview
    }

    private func positionPanel() {
        positionPanel(panel)
        if let previewPanel {
            positionPanel(previewPanel)
        }
    }

    private func positionPanel(_ target: LockScreenMediaPanel) {
        guard let screen = targetScreen else { return }
        let frame = LockScreenMediaPresentationState.cardFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            cardSize: Self.cardSize
        )
        target.setFrame(frame, display: target.isVisible, animate: false)
    }

    private var targetScreen: NSScreen? {
        if let main = NSScreen.main {
            return main
        }

        return NSScreen.screens.first(where: { screen in
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea
            else { return false }
            return !left.isEmpty && !right.isEmpty
        }) ?? NSScreen.screens.first
    }

    private var lockScreenMediaEnabled: Bool {
        UserDefaults.standard.object(forKey: "showLockScreenMedia") == nil
            || UserDefaults.standard.bool(forKey: "showLockScreenMedia")
    }

    private static let cardSize = CGSize(width: 560, height: 270)

    private static var lockScreenSpaceWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    }

    private static var currentSessionIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static var currentSessionIsActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        else { return false }
        let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool ?? false
        let loginDone = session["kCGSessionLoginDoneKey"] as? Bool ?? false
        return onConsole && loginDone
    }
}

extension LockScreenMediaCoordinator {
    static func requestPreview() {
        NotificationCenter.default.post(
            name: .previewLockScreenMedia,
            object: nil,
            userInfo: nil
        )
    }
}
