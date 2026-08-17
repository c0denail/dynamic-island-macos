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
    private var cancellables = Set<AnyCancellable>()
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var previewTask: Task<Void, Never>?
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

        configurePanel()

        let root = LockScreenMediaPlayerView(
            isPreview: false,
            dismissPreview: nil
        )
        .environmentObject(controller.media)
        .environmentObject(controller.theme)

        let hosting = LockScreenMediaHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
    }

    func start() {
        guard !started else { return }
        started = true
        installObservers()
        isSessionActive = Self.currentSessionIsActive
        isLocked = Self.currentSessionIsLocked
        updateVisibility(animated: false)

        if CommandLine.arguments.contains("--preview-lock-screen-media") {
            preview(duration: 30)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        panel.orderOut(nil)
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

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isExcludedFromWindowsMenu = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.canBecomeVisibleWithoutLogin = true

        // Stay above the lock-screen wallpaper/screen saver while leaving
        // higher-level loginwindow authentication UI in control.
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
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
                    self.panel.orderOut(nil)
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
                    self.isLocked = Self.currentSessionIsLocked
                    self.updateVisibility(animated: false)
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
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        isLocked = true
        controller.media.refresh()
        updateRootView()
        updateVisibility(animated: false)
    }

    private func screenDidUnlock() {
        isLocked = false
        isPreviewing = false
        previewTask?.cancel()
        previewTask = nil
        updateRootView()
        updateVisibility(animated: false)
    }

    private func updateVisibility(animated: Bool) {
        let shouldShow = LockScreenMediaPresentationState.shouldShow(
            isLocked: isLocked,
            isPreviewing: isPreviewing,
            isEnabled: lockScreenMediaEnabled,
            hasActiveMedia: controller.media.hasActiveSource,
            isSessionActive: isSessionActive
        )

        guard shouldShow else {
            if panel.isVisible {
                // Unlock and session-switch transitions must remove the card
                // immediately so media metadata never lingers over login UI.
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
            return
        }

        positionPanel()
        if panel.isVisible {
            panel.orderFrontRegardless()
            return
        }

        if animated {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func updateRootView() {
        let root = LockScreenMediaPlayerView(
            isPreview: isPreviewing && !isLocked,
            dismissPreview: { [weak self] in
                self?.isPreviewing = false
                self?.updateRootView()
                self?.updateVisibility(animated: true)
            }
        )
        .environmentObject(controller.media)
        .environmentObject(controller.theme)

        guard let hosting = panel.contentView as? LockScreenMediaHostingView<AnyView> else {
            let replacement = LockScreenMediaHostingView(rootView: AnyView(root))
            replacement.sizingOptions = []
            replacement.autoresizingMask = [.width, .height]
            replacement.wantsLayer = true
            replacement.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = replacement
            return
        }
        hosting.rootView = AnyView(root)
    }

    private func positionPanel() {
        guard let screen = targetScreen else { return }
        let frame = LockScreenMediaPresentationState.cardFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            cardSize: Self.cardSize
        )
        panel.setFrame(frame, display: panel.isVisible, animate: false)
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
