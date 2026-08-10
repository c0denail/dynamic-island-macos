import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandController: ObservableObject {
    static let shared = IslandController()

    @Published var presentation: IslandPresentation = .mini
    @Published var selectedSection: IslandSection = .overview
    @Published var requestedSystemPanel: SystemPanelDestination?
    @Published var temporaryMessage: CompactActivity?
    @Published var notchWidth: CGFloat = 182
    @Published var notchHeight: CGFloat = 34
    @Published var hasPhysicalNotch = false
    private(set) var lastExpansionDate = Date.distantPast

    let media = MediaService()
    let timer = TimerService()
    let clockTimer = ClockTimerService()
    let system = SystemStatusService()
    let connectivity = ConnectivityService()
    let notifications = NotificationMirrorService()

    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var notificationQueue: [MirroredNotification] = []
    private var activeNotificationID: String?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {
        clockTimer.$hasActiveActivity
            .combineLatest(media.$isPlaying)
            .sink { [weak self] timerActive, mediaPlaying in
                guard let self else { return }
                if self.presentation == .mini, timerActive || mediaPlaying {
                    self.presentation = .compact
                }
            }
            .store(in: &cancellables)

        clockTimer.$activeMode
            .compactMap { $0 }
            .sink { [weak self] mode in self?.timer.mode = mode }
            .store(in: &cancellables)

        system.$volumeEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                guard let self,
                      UserDefaults.standard.object(forKey: "showVolumeHUD") == nil || UserDefaults.standard.bool(forKey: "showVolumeHUD")
                else { return }
                self.showTemporaryActivity(.volume(value: event.value, isMuted: event.isMuted), duration: 1.45)
            }
            .store(in: &cancellables)

        system.$brightnessEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                guard let self,
                      UserDefaults.standard.object(forKey: "showBrightnessHUD") == nil || UserDefaults.standard.bool(forKey: "showBrightnessHUD")
                else { return }
                self.showTemporaryActivity(.brightness(value: event.value), duration: 1.45)
            }
            .store(in: &cancellables)

        clockTimer.$hasActiveActivity
            .dropFirst()
            .sink { [weak self] isActive in
                guard let self,
                      isActive
                else { return }
                if self.presentation == .mini { self.presentation = .compact }
            }
            .store(in: &cancellables)

        notifications.$incomingNotification
            .compactMap { $0 }
            .sink { [weak self] notification in
                self?.enqueueNotification(notification)
            }
            .store(in: &cancellables)
    }

    var compactActivity: CompactActivity {
        if let temporaryMessage { return temporaryMessage }
        if clockTimer.hasActiveActivity { return .timer }
        if media.isPlaying || media.hasActiveSource { return .media }
        return .idle
    }

    func start() {
        media.start()
        clockTimer.start()
        system.start()
        connectivity.start()
        notifications.start()
        installHotKey()
    }

    func stop() {
        media.stop()
        clockTimer.stop()
        system.stop()
        connectivity.stop()
        notifications.stop()
        notificationTask?.cancel()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func open(_ section: IslandSection) {
        collapseTask?.cancel()
        selectedSection = section
        lastExpansionDate = Date()
        presentation = .expanded
    }

    func openSystemPanel(_ destination: SystemPanelDestination) {
        requestedSystemPanel = destination
        open(.system)
    }

    func consumeSystemPanelRequest() {
        requestedSystemPanel = nil
    }

    func toggleExpanded() {
        if presentation != .expanded {
            collapseTask?.cancel()
            lastExpansionDate = Date()
        }
        presentation = presentation == .expanded ? preferredCollapsedPresentation : .expanded
    }

    func openContextualActivity() {
        if case let .notification(notification) = temporaryMessage {
            let didActivate = notifications.activateSource(for: notification)
            finishActiveNotification()
            if !didActivate { open(.overview) }
            return
        }
        if media.hasActiveSource {
            open(.media)
        } else if clockTimer.hasActiveActivity {
            open(.timer)
        } else {
            open(.overview)
        }
    }

    func handleHover(_ hovering: Bool) {
        guard UserDefaults.standard.object(forKey: "hoverToExpand") == nil || UserDefaults.standard.bool(forKey: "hoverToExpand") else { return }
        guard presentation != .expanded else { return }
        collapseTask?.cancel()

        if hovering {
            presentation = .compact
        } else {
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, let self else { return }
                guard self.presentation != .expanded else { return }
                self.presentation = self.preferredCollapsedPresentation
            }
        }
    }

    func collapse() {
        presentation = preferredCollapsedPresentation
    }

    func showMessage(icon: String, title: String, color: Color = IslandPalette.primary) {
        showTemporaryActivity(.message(icon: icon, title: title, color: color), duration: 2.4)
    }

    func showTemporaryActivity(_ activity: CompactActivity, duration: TimeInterval) {
        guard activeNotificationID == nil else { return }
        messageTask?.cancel()
        temporaryMessage = activity
        if presentation == .mini { presentation = .compact }

        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.temporaryMessage = nil
            if !self.clockTimer.hasActiveActivity && !self.media.isPlaying {
                self.presentation = .mini
            }
        }
    }

    func activateNotification(_ notification: MirroredNotification) {
        let didActivate = notifications.activateSource(for: notification)
        finishActiveNotification()
        if !didActivate { open(.overview) }
    }

    func previewNotification() {
        enqueueNotification(
            MirroredNotification(
                id: UUID().uuidString,
                appName: "Mesajlar",
                title: "Yeni mesaj",
                subtitle: "Dynamic Island",
                body: "Gelen bildirimler artık çentikten açılıyor.",
                bundleIdentifier: nil,
                appIconData: NSApplication.shared.applicationIconImage.tiffRepresentation
            )
        )
    }

    private func enqueueNotification(_ notification: MirroredNotification) {
        guard activeNotificationID != notification.id,
              !notificationQueue.contains(where: { $0.id == notification.id })
        else { return }
        notificationQueue.append(notification)
        presentNextNotificationIfNeeded()
    }

    private func presentNextNotificationIfNeeded() {
        guard activeNotificationID == nil, !notificationQueue.isEmpty else { return }
        let notification = notificationQueue.removeFirst()
        activeNotificationID = notification.id
        messageTask?.cancel()
        temporaryMessage = .notification(notification)
        if presentation != .expanded { presentation = .compact }

        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5.2))
            guard !Task.isCancelled else { return }
            self?.finishActiveNotification()
        }
    }

    private func finishActiveNotification() {
        notificationTask?.cancel()
        notificationTask = nil
        activeNotificationID = nil
        if case .notification = temporaryMessage { temporaryMessage = nil }

        if notificationQueue.isEmpty {
            if presentation != .expanded { presentation = preferredCollapsedPresentation }
        } else {
            presentNextNotificationIfNeeded()
        }
    }

    func updateDisplayMetrics(notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) {
        guard self.notchWidth != notchWidth || self.notchHeight != notchHeight || hasPhysicalNotch != hasNotch else { return }
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        hasPhysicalNotch = hasNotch
    }

    func copySystemSummary() {
        let summary = "Pil: \(system.batteryPercent)% · Ağ: \(system.networkLabel) · Ses: \(Int(system.outputVolume * 100))% · Parlaklık: \(Int(system.displayBrightness * 100))%"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        showMessage(icon: "doc.on.doc.fill", title: "Sistem özeti kopyalandı", color: IslandPalette.cyan)
    }

    private var preferredCollapsedPresentation: IslandPresentation {
        clockTimer.hasActiveActivity || media.isPlaying ? .compact : .mini
    }

    private func installHotKey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option else { return }
            Task { @MainActor in self?.toggleExpanded() }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option {
                handler(event)
                return nil
            }
            return event
        }
    }
}
