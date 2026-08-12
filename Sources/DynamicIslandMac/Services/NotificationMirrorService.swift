import AppKit
import ApplicationServices
import Combine

private struct SendableAXElement: @unchecked Sendable {
    let value: AXUIElement
}

private struct NotificationBannerPayload: Sendable {
    let description: String
    let title: String
    let subtitle: String
    let body: String
}

private struct NotificationBannerSnapshot: Sendable {
    let identifier: String
    let element: SendableAXElement
    let payload: NotificationBannerPayload?
}

private struct NotificationCenterScanRequest: Sendable {
    let id: UInt64
    let trackingGeneration: UInt64
    let processIdentifier: pid_t
    let root: SendableAXElement
    let hasEstablishedBaseline: Bool
    let seenIdentifiers: Set<String>
}

private enum NotificationCenterAXScanner {
    static func scan(_ request: NotificationCenterScanRequest) -> [NotificationBannerSnapshot] {
        let windows = elementArrayAttribute(request.root.value, kAXWindowsAttribute)
            .filter(isBannerWindow)
        let banners = windows.flatMap { bannerElements(in: $0) }

        return banners.map { banner in
            let identifier = notificationIdentifier(for: banner)
            let needsPayload = request.hasEstablishedBaseline
                && !request.seenIdentifiers.contains(identifier)
            let payload: NotificationBannerPayload?

            if needsPayload {
                payload = NotificationBannerPayload(
                    description: stringAttribute(banner, kAXDescriptionAttribute) ?? "",
                    title: textValue(in: banner, identifier: "title") ?? "",
                    subtitle: textValue(in: banner, identifier: "subtitle") ?? "",
                    body: textValue(in: banner, identifier: "body") ?? ""
                )
            } else {
                payload = nil
            }

            return NotificationBannerSnapshot(
                identifier: identifier,
                element: SendableAXElement(value: banner),
                payload: payload
            )
        }
    }

    private static func isBannerWindow(_ window: AXUIElement) -> Bool {
        guard stringAttribute(window, kAXSubroleAttribute) == "AXSystemDialog" else { return false }
        guard let size = sizeAttribute(window) else { return true }
        return size.width <= 650 && size.height <= 450
    }

    private static func bannerElements(in root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth <= 8 else { return [] }
        if stringAttribute(root, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
            return [root]
        }
        return elementArrayAttribute(root, kAXChildrenAttribute)
            .flatMap { bannerElements(in: $0, depth: depth + 1) }
    }

    private static func notificationIdentifier(for banner: AXUIElement) -> String {
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

    private static func textValue(in root: AXUIElement, identifier: String, depth: Int = 0) -> String? {
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

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func sizeAttribute(_ element: AXUIElement) -> CGSize? {
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
    private var isPollingActive = false
    private var nextScanID: UInt64 = 0
    private var activeScanID: UInt64?
    private var trackingGeneration: UInt64 = 0

    private var isFeatureEnabled: Bool {
        UserDefaults.standard.object(forKey: "showNotificationHUD") == nil
            || UserDefaults.standard.bool(forKey: "showNotificationHUD")
    }

    func start() {
        isPollingActive = true
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
        isPollingActive = false
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
            trackingGeneration &+= 1
        }

        guard activeScanID == nil, let notificationCenterElement else { return }
        nextScanID &+= 1
        let request = NotificationCenterScanRequest(
            id: nextScanID,
            trackingGeneration: trackingGeneration,
            processIdentifier: notificationCenterPID,
            root: SendableAXElement(value: notificationCenterElement),
            hasEstablishedBaseline: hasEstablishedBaseline,
            seenIdentifiers: Set(seenIdentifiers.keys)
        )
        activeScanID = request.id

        Task { [weak self] in
            let banners = await Task.detached(priority: .utility) {
                NotificationCenterAXScanner.scan(request)
            }.value
            self?.applyScan(banners, request: request)
        }
    }

    private func applyScan(
        _ banners: [NotificationBannerSnapshot],
        request: NotificationCenterScanRequest
    ) {
        guard activeScanID == request.id else { return }
        activeScanID = nil

        guard isPollingActive,
              request.trackingGeneration == trackingGeneration,
              request.processIdentifier == notificationCenterPID,
              notificationCenterElement != nil,
              isFeatureEnabled,
              AXIsProcessTrusted(),
              shouldDeferPolling?() != true,
              NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
                .first?.processIdentifier == request.processIdentifier
        else { return }

        let now = Date()

        if !hasEstablishedBaseline {
            for banner in banners {
                seenIdentifiers[banner.identifier] = now
                bannerElements[banner.identifier] = banner.element.value
            }
            hasEstablishedBaseline = true
            return
        }

        for banner in banners {
            bannerElements[banner.identifier] = banner.element.value
            guard seenIdentifiers[banner.identifier] == nil else { continue }
            seenIdentifiers[banner.identifier] = now
            if let payload = banner.payload,
               let notification = mirroredNotification(from: payload, identifier: banner.identifier) {
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
        trackingGeneration &+= 1
    }

    private func mirroredNotification(
        from payload: NotificationBannerPayload,
        identifier: String
    ) -> MirroredNotification? {
        guard !payload.title.isEmpty || !payload.subtitle.isEmpty || !payload.body.isEmpty else { return nil }

        let appName = sourceApplicationName(from: payload.description, title: payload.title)
        let application = runningApplication(named: appName)

        return MirroredNotification(
            id: identifier,
            appName: appName,
            title: payload.title,
            subtitle: payload.subtitle,
            body: payload.body,
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

}
