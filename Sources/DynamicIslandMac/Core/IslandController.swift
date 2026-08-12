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
    @Published private(set) var isPresentationAnimating = false

    let media = MediaService()
    let timer = TimerService()
    let clockTimer = ClockTimerService()
    let system = SystemStatusService()
    let connectivity = ConnectivityService()
    let notifications = NotificationMirrorService()
    let charging = ChargingEventService()
    let storage = ExternalStorageService()
    let audioAccessories = AudioAccessoryService()
    let theme = IslandTheme()

    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var notificationQueue: [MirroredNotification] = []
    private var activeNotificationID: String?
    private var hardwareTask: Task<Void, Never>?
    private var hardwareQueue: [IslandHardwareActivity] = []
    private var activeHardwareActivity: IslandHardwareActivity?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {
        notifications.shouldDeferPolling = { [weak self] in
            self?.isPresentationAnimating == true
        }

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

        charging.$incomingEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                self?.handleChargingEvent(event)
            }
            .store(in: &cancellables)

        storage.$latestEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                self?.handleStorageEvent(event)
            }
            .store(in: &cancellables)

        audioAccessories.$connectionEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                self?.handleAudioAccessoryEvent(event)
            }
            .store(in: &cancellables)

        audioAccessories.$connectedAccessories
            .dropFirst()
            .sink { [weak self] accessories in
                self?.updateVisibleAudioAccessory(accessories)
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
        charging.start()
        storage.start()
        audioAccessories.start()
        installHotKey()
    }

    func stop() {
        media.stop()
        clockTimer.stop()
        system.stop()
        connectivity.stop()
        notifications.stop()
        charging.stop()
        storage.stop()
        audioAccessories.stop()
        notificationTask?.cancel()
        hardwareTask?.cancel()
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
        if case let .hardware(activity) = temporaryMessage {
            activateHardwareActivity(activity)
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

    func showMessage(icon: String, title: String, color: Color? = nil) {
        showTemporaryActivity(.message(icon: icon, title: title, color: color ?? theme.hudColor), duration: 2.4)
    }

    func showTemporaryActivity(_ activity: CompactActivity, duration: TimeInterval) {
        guard activeNotificationID == nil, activeHardwareActivity == nil else { return }
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

    func activateHardwareActivity(_ activity: IslandHardwareActivity) {
        finishActiveHardwareActivity()

        switch activity.kind {
        case .charging, .powerConnected, .powerDisconnected:
            open(.system)
        case .airPods, .airPodsMax, .headphones:
            openSystemPanel(.bluetooth)
        case .storageConnected:
            if let volumeURL = activity.volumeURL {
                NSWorkspace.shared.activateFileViewerSelecting([volumeURL])
            } else {
                open(.overview)
            }
        case .storageDisconnected:
            open(.overview)
        }
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
        suspendActiveHardwareActivityForNotification()
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
            presentNextHardwareActivityIfNeeded()
            if activeHardwareActivity == nil, presentation != .expanded {
                presentation = preferredCollapsedPresentation
            }
        } else {
            presentNextNotificationIfNeeded()
        }
    }

    private func handleChargingEvent(_ event: ChargingConnectionEvent) {
        let percentage = event.snapshot.batteryPercentage
        let battery = IslandBatteryLevels(combined: percentage)

        switch event.kind {
        case .connectedToPower:
            let subtitle: String
            if let minutes = event.snapshot.estimatedMinutesToFull, minutes > 0 {
                subtitle = "\(formatMinutes(minutes)) sonra dolacak"
            } else if event.snapshot.isCharging {
                subtitle = percentage.map { "Pil %\($0)" } ?? "Güç adaptörü bağlı"
            } else {
                subtitle = "Güç adaptörü bağlı"
            }
            enqueueHardwareActivity(
                IslandHardwareActivity(
                    id: "power:\(event.kind)",
                    sourceID: "power",
                    kind: event.snapshot.isCharging ? .charging : .powerConnected,
                    title: event.snapshot.isCharging ? "Mac şarj oluyor" : "Güç adaptörü bağlandı",
                    subtitle: subtitle,
                    isConnected: true,
                    battery: battery
                )
            )
        case .disconnectedFromPower:
            enqueueHardwareActivity(
                IslandHardwareActivity(
                    id: "power:\(event.kind)",
                    sourceID: "power",
                    kind: .powerDisconnected,
                    title: "Güç adaptörü çıkarıldı",
                    subtitle: percentage.map { "Pil %\($0) · Pil gücü kullanılıyor" } ?? "Pil gücü kullanılıyor",
                    isConnected: false,
                    battery: battery
                )
            )
        }
    }

    private func handleStorageEvent(_ event: ExternalStorageEvent) {
        let volume = event.volume
        let kind: IslandHardwareActivityKind = event.action == .connected
            ? .storageConnected
            : .storageDisconnected
        let subtitle: String
        if event.action == .connected {
            let total = ByteCountFormatter.string(fromByteCount: volume.totalCapacityBytes, countStyle: .file)
            subtitle = "\(volume.kind.displayName) · \(total)"
        } else {
            subtitle = "\(volume.kind.displayName) aygıtının bağlantısı kesildi"
        }

        enqueueHardwareActivity(
            IslandHardwareActivity(
                id: "storage:\(volume.id):\(event.action.rawValue)",
                sourceID: "storage:\(volume.id)",
                kind: kind,
                title: event.action == .connected ? volume.name : "\(volume.name) çıkarıldı",
                subtitle: subtitle,
                isConnected: event.action == .connected,
                totalCapacity: volume.totalCapacityBytes,
                availableCapacity: volume.availableCapacityBytes,
                volumeURL: event.action == .connected ? volume.mountURL : nil
            )
        )
        storage.clearLatestEvent(id: event.id)
    }

    private func handleAudioAccessoryEvent(_ event: AudioAccessoryConnectionEvent) {
        enqueueHardwareActivity(makeAudioHardwareActivity(for: event.accessory, state: event.state))
    }

    private func makeAudioHardwareActivity(
        for accessory: AudioAccessorySnapshot,
        state: AudioAccessoryConnectionState
    ) -> IslandHardwareActivity {
        let kind: IslandHardwareActivityKind
        switch accessory.kind {
        case .airPods, .airPodsPro:
            kind = .airPods
        case .airPodsMax:
            kind = .airPodsMax
        case .headphones:
            kind = .headphones
        }

        let connected = state == .connected
        let battery = IslandBatteryLevels(
            combined: accessory.batteryPercent,
            left: accessory.batteryLeftPercent,
            right: accessory.batteryRightPercent,
            caseLevel: accessory.batteryCasePercent
        )
        let batteryDetail = battery.preferred.map { " · Şarj %\($0)" } ?? ""
        return IslandHardwareActivity(
            id: "audio:\(accessory.id):\(state.rawValue)",
            sourceID: "audio:\(accessory.id)",
            kind: kind,
            title: accessory.name,
            subtitle: connected ? "Kulaklık bağlandı\(batteryDetail)" : "Kulaklık bağlantısı kesildi",
            isConnected: connected,
            battery: battery
        )
    }

    private func updateVisibleAudioAccessory(_ accessories: [AudioAccessorySnapshot]) {
        for accessory in accessories {
            let activity = makeAudioHardwareActivity(for: accessory, state: .connected)
            if activeHardwareActivity?.id == activity.id {
                activeHardwareActivity = activity
                if case let .hardware(current) = temporaryMessage, current.id == activity.id {
                    temporaryMessage = .hardware(activity)
                }
            }
            for index in hardwareQueue.indices where hardwareQueue[index].id == activity.id {
                hardwareQueue[index] = activity
            }
        }
    }

    private func enqueueHardwareActivity(_ activity: IslandHardwareActivity) {
        guard UserDefaults.standard.object(forKey: "showHardwareHUD") == nil
                || UserDefaults.standard.bool(forKey: "showHardwareHUD")
        else { return }

        if let sourceID = activity.sourceID {
            hardwareQueue.removeAll { $0.sourceID == sourceID }
            if activeHardwareActivity?.sourceID == sourceID {
                presentHardwareActivity(activity)
                return
            }
        } else {
            guard activeHardwareActivity?.id != activity.id,
                  !hardwareQueue.contains(where: { $0.id == activity.id })
            else { return }
        }

        hardwareQueue.append(activity)
        if hardwareQueue.count > 8 {
            hardwareQueue.removeFirst(hardwareQueue.count - 8)
        }
        presentNextHardwareActivityIfNeeded()
    }

    private func presentNextHardwareActivityIfNeeded() {
        guard activeNotificationID == nil,
              activeHardwareActivity == nil,
              !hardwareQueue.isEmpty
        else { return }

        presentHardwareActivity(hardwareQueue.removeFirst())
    }

    private func presentHardwareActivity(_ activity: IslandHardwareActivity) {
        hardwareTask?.cancel()
        activeHardwareActivity = activity
        messageTask?.cancel()
        temporaryMessage = .hardware(activity)
        if presentation != .expanded { presentation = .compact }

        hardwareTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(activity.duration))
            guard !Task.isCancelled else { return }
            self?.finishActiveHardwareActivity()
        }
    }

    private func suspendActiveHardwareActivityForNotification() {
        guard let activeHardwareActivity else { return }
        hardwareTask?.cancel()
        hardwareTask = nil
        hardwareQueue.insert(activeHardwareActivity, at: 0)
        self.activeHardwareActivity = nil
        if case .hardware = temporaryMessage { temporaryMessage = nil }
    }

    private func finishActiveHardwareActivity() {
        hardwareTask?.cancel()
        hardwareTask = nil
        activeHardwareActivity = nil
        if case .hardware = temporaryMessage { temporaryMessage = nil }

        if hardwareQueue.isEmpty {
            if activeNotificationID == nil, presentation != .expanded {
                presentation = preferredCollapsedPresentation
            }
        } else {
            presentNextHardwareActivityIfNeeded()
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) dk" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) sa" : "\(hours) sa \(remainder) dk"
    }

    func updateDisplayMetrics(notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) {
        guard self.notchWidth != notchWidth || self.notchHeight != notchHeight || hasPhysicalNotch != hasNotch else { return }
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        hasPhysicalNotch = hasNotch
    }

    func setPresentationAnimating(_ isAnimating: Bool) {
        isPresentationAnimating = isAnimating
    }

    func copySystemSummary() {
        let summary = "Pil: \(system.batteryPercent)% · Ağ: \(system.networkLabel) · Ses: \(Int(system.outputVolume * 100))% · Parlaklık: \(Int(system.displayBrightness * 100))%"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        showMessage(icon: "doc.on.doc.fill", title: "Sistem özeti kopyalandı", color: theme.hudColor)
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
