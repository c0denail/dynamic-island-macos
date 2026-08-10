import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelCoordinator: IslandPanelCoordinator?
    private var permissionOnboardingCoordinator: PermissionOnboardingCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let coordinator = IslandPanelCoordinator(controller: .shared)
        panelCoordinator = coordinator
        coordinator.show()
        IslandController.shared.start()

        let onboarding = PermissionOnboardingCoordinator(controller: .shared)
        permissionOnboardingCoordinator = onboarding
        onboarding.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        IslandController.shared.stop()
    }
}
