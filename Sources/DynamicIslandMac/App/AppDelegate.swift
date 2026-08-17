import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelCoordinator: IslandPanelCoordinator?
    private var lockScreenMediaCoordinator: LockScreenMediaCoordinator?
    private var permissionOnboardingCoordinator: PermissionOnboardingCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let coordinator = IslandPanelCoordinator(controller: .shared)
        panelCoordinator = coordinator
        coordinator.show()
        IslandController.shared.start()

        let lockScreenCoordinator = LockScreenMediaCoordinator(controller: .shared)
        lockScreenMediaCoordinator = lockScreenCoordinator
        lockScreenCoordinator.start()

        let onboarding = PermissionOnboardingCoordinator(controller: .shared)
        permissionOnboardingCoordinator = onboarding
        onboarding.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lockScreenMediaCoordinator?.stop()
        IslandController.shared.stop()
    }
}
