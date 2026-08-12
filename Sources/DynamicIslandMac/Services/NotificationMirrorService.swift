import AppKit
import ApplicationServices
import Combine

@MainActor
final class NotificationMirrorService: ObservableObject {
    @Published private(set) var incomingNotification: MirroredNotification?
    @Published private(set) var isAccessibilityTrusted = false
    var shouldDeferPolling: (() -> Bool)?

    private var poller: AnyCancellable?
    private var notificationCenterElement: AXUIElement?
    private var notificationCenterPID: pid_t = 0
    private var hasEstablishedBaseline = false
    private var wasFeatureEnabled = false
    private var seenIdentifiers: [String: Date] = [:]
    private var bannerElements: [String: AXUIElement] = [:]

    private var isFeatureEnabled: Bool {
        UserDefaults.standard.object(forKey: "showNotificationHUD") == nil
            || UserDefaults.standard.bool(forKey: "showNotificationHUD")
    }

    func start() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        wasFeatureEnabled = isFeatureEnabled

        if UserDefaults.standard.bool(forKey: "permissionOnboardingCompleted"),
           isFeatureEnabled,
           !isAccessibilityTrusted {
            // Ask once per launch instead of suppressing the prompt forever.
            // A newly signed app build can require Accessibility approval again.
            requestAccessibilityAccess()
        }

        poller = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollNotificationCenter() }
        pollNotificationCenter()
    }

    func stop() {
        poller?.cancel()
        poller = nil
        resetTracking()
    }

    func featurePreferenceDidChange(enabled: Bool) {
        if enabled { requestAccessibilityAccess() }
        pollNotificationCenter()
    }

    func requestAccessibilityAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func activateSource(for notification: MirroredNotification) -> Bool {
        if let element = bannerElements[notification.id],
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }

        if let bundleIdentifier = notification.bundleIdentifier,
           let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            return application.activate(options: [.activateAllWindows])
        }
        return false
    }

    private func pollNotificationCenter() {
        let enabled = isFeatureEnabled
        if enabled != wasFeatureEnabled {
            wasFeatureEnabled = enabled
            resetTracking()
        }

        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        guard enabled, trusted else {
            if !enabled { resetTracking() }
            return
        }
        guard shouldDeferPolling?() != true else { return }

        guard let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .first
        else { return }

        if runningApplication.processIdentifier != notificationCenterPID || notificationCenterElement == nil {
            notificationCenterPID = runningApplication.processIdentifier
            notificationCenterElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
            hasEstablishedBaseline = false
            seenIdentifiers.removeAll()
            bannerElements.removeAll()
        }

        guard let notificationCenterElement else { return }
        let windows = elementArrayAttribute(notificationCenterElement, kAXWindowsAttribute)
            .filter(isBannerWindow)
        let banners = windows.flatMap { bannerElements(in: $0) }
        let now = Date()

        if !hasEstablishedBaseline {
            for banner in banners {
                let identifier = notificationIdentifier(for: banner)
                seenIdentifiers[identifier] = now
                bannerElements[identifier] = banner
            }
            hasEstablishedBaseline = true
            return
        }

        for banner in banners {
            let identifier = notificationIdentifier(for: banner)
            bannerElements[identifier] = banner
            guard seenIdentifiers[identifier] == nil else { continue }
            seenIdentifiers[identifier] = now
            if let notification = mirroredNotification(from: banner, identifier: identifier) {
                incomingNotification = notification
            }
        }

        let expiration = now.addingTimeInterval(-3600)
        let expired = seenIdentifiers.filter { $0.value < expiration }.map(\.key)
        for identifier in expired {
            seenIdentifiers.removeValue(forKey: identifier)
            bannerElements.removeValue(forKey: identifier)
        }
    }

    private func resetTracking() {
        notificationCenterElement = nil
        notificationCenterPID = 0
        hasEstablishedBaseline = false
        seenIdentifiers.removeAll()
        bannerElements.removeAll()
    }

    private func isBannerWindow(_ window: AXUIElement) -> Bool {
        guard stringAttribute(window, kAXSubroleAttribute) == "AXSystemDialog" else { return false }
        guard let size = sizeAttribute(window) else { return true }
        return size.width <= 650 && size.height <= 450
    }

    private func bannerElements(in root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth <= 8 else { return [] }
        if stringAttribute(root, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
            return [root]
        }
        return elementArrayAttribute(root, kAXChildrenAttribute)
            .flatMap { bannerElements(in: $0, depth: depth + 1) }
    }

    private func notificationIdentifier(for banner: AXUIElement) -> String {
        if let identifier = stringAttribute(banner, kAXIdentifierAttribute), !identifier.isEmpty {
            return identifier
        }
        return [
            stringAttribute(banner, kAXDescriptionAttribute) ?? "",
            textValue(in: banner, identifier: "title") ?? "",
            textValue(in: banner, identifier: "subtitle") ?? "",
            textValue(in: banner, identifier: "body") ?? ""
        ].joined(separator: "|")
    }

    private func mirroredNotification(from banner: AXUIElement, identifier: String) -> MirroredNotification? {
        let title = textValue(in: banner, identifier: "title") ?? ""
        let subtitle = textValue(in: banner, identifier: "subtitle") ?? ""
        let body = textValue(in: banner, identifier: "body") ?? ""
        guard !title.isEmpty || !subtitle.isEmpty || !body.isEmpty else { return nil }

        let description = stringAttribute(banner, kAXDescriptionAttribute) ?? ""
        let appName = sourceApplicationName(from: description, title: title)
        let application = runningApplication(named: appName)

        return MirroredNotification(
            id: identifier,
            appName: appName,
            title: title,
            subtitle: subtitle,
            body: body,
            bundleIdentifier: application?.bundleIdentifier,
            appIconData: application?.icon?.tiffRepresentation
        )
    }

    private func sourceApplicationName(from description: String, title: String) -> String {
        if !title.isEmpty, let marker = description.range(of: ", \(title)") {
            let name = description[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        let firstComponent = description.split(separator: ",", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return firstComponent?.isEmpty == false ? firstComponent! : "Bildirim"
    }

    private func runningApplication(named appName: String) -> NSRunningApplication? {
        let normalizedName = appName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return NSWorkspace.shared.runningApplications.first { application in
            guard let localizedName = application.localizedName else { return false }
            return localizedName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedName
        }
    }

    private func textValue(in root: AXUIElement, identifier: String, depth: Int = 0) -> String? {
        guard depth <= 6 else { return nil }
        if stringAttribute(root, kAXIdentifierAttribute) == identifier {
            return stringAttribute(root, kAXValueAttribute)
        }
        for child in elementArrayAttribute(root, kAXChildrenAttribute) {
            if let value = textValue(in: child, identifier: identifier, depth: depth + 1) {
                return value
            }
        }
        return nil
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func sizeAttribute(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
