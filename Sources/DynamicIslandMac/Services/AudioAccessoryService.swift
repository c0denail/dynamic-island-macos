import Combine
import CoreAudio
import Foundation
import IOBluetooth
import IOKit.hid

enum AudioAccessoryKind: String, Equatable, Sendable {
    case airPods
    case airPodsPro
    case airPodsMax
    case headphones
}

struct AudioAccessorySnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: AudioAccessoryKind
    let batteryPercent: Int?
    let batteryLeftPercent: Int?
    let batteryRightPercent: Int?
    let batteryCasePercent: Int?
    let isConnected: Bool
    let isActiveOutput: Bool

    fileprivate func withConnection(_ connected: Bool) -> AudioAccessorySnapshot {
        AudioAccessorySnapshot(
            id: id,
            name: name,
            kind: kind,
            batteryPercent: batteryPercent,
            batteryLeftPercent: batteryLeftPercent,
            batteryRightPercent: batteryRightPercent,
            batteryCasePercent: batteryCasePercent,
            isConnected: connected,
            isActiveOutput: connected && isActiveOutput
        )
    }

    fileprivate func withBattery(_ battery: AudioAccessoryBatteryLevels) -> AudioAccessorySnapshot {
        AudioAccessorySnapshot(
            id: id,
            name: name,
            kind: kind,
            batteryPercent: battery.combinedPercent,
            batteryLeftPercent: battery.leftPercent,
            batteryRightPercent: battery.rightPercent,
            batteryCasePercent: battery.casePercent,
            isConnected: isConnected,
            isActiveOutput: isActiveOutput
        )
    }
}

private struct AudioAccessoryRawDevice: Sendable {
    let id: String
    let name: String?
    let deviceClassMajor: UInt32
    let deviceClassMinor: UInt32
    let serviceClassMajor: UInt32
}

struct AudioAccessoryBatteryLevels: Equatable, Sendable {
    let mainPercent: Int?
    let leftPercent: Int?
    let rightPercent: Int?
    let casePercent: Int?

    var combinedPercent: Int? {
        if let mainPercent { return mainPercent }
        switch (leftPercent, rightPercent) {
        case let (left?, right?): return min(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    fileprivate func mergingHIDPercent(_ hidPercent: Int?) -> AudioAccessoryBatteryLevels {
        AudioAccessoryBatteryLevels(
            mainPercent: mainPercent ?? hidPercent,
            leftPercent: leftPercent,
            rightPercent: rightPercent,
            casePercent: casePercent
        )
    }
}

enum AudioAccessoryConnectionState: String, Equatable, Sendable {
    case connected
    case disconnected
}

struct AudioAccessoryConnectionEvent: Equatable, Sendable {
    let state: AudioAccessoryConnectionState
    let accessory: AudioAccessorySnapshot
}

/// Pure transition state used by `AudioAccessoryService` and its tests. The
/// first update establishes a baseline and deliberately emits no event, so an
/// accessory that was already connected when the app launched never produces
/// a misleading pop-up.
struct AudioAccessoryTransitionTracker {
    private(set) var isPrimed = false
    private var knownAccessories: [String: AudioAccessorySnapshot] = [:]

    mutating func update(
        _ snapshots: [AudioAccessorySnapshot]
    ) -> [AudioAccessoryConnectionEvent] {
        let connected = snapshots.filter(\.isConnected)
        let current = Dictionary(uniqueKeysWithValues: connected.map { ($0.id, $0) })

        guard isPrimed else {
            isPrimed = true
            knownAccessories = current
            return []
        }

        let disconnectedIDs = knownAccessories.keys
            .filter { current[$0] == nil }
            .sorted()
        let connectedIDs = current.keys
            .filter { knownAccessories[$0] == nil }
            .sorted()

        var events = disconnectedIDs.compactMap { id -> AudioAccessoryConnectionEvent? in
            guard let previous = knownAccessories[id] else { return nil }
            return AudioAccessoryConnectionEvent(
                state: .disconnected,
                accessory: previous.withConnection(false)
            )
        }
        events.append(contentsOf: connectedIDs.compactMap { id -> AudioAccessoryConnectionEvent? in
            guard let accessory = current[id] else { return nil }
            return AudioAccessoryConnectionEvent(state: .connected, accessory: accessory)
        })

        // Name, battery and active-output changes update the retained snapshot
        // but are not physical connection transitions and therefore stay quiet.
        knownAccessories = current
        return events
    }

    mutating func reset() {
        isPrimed = false
        knownAccessories = [:]
    }
}

enum AudioAccessoryClassifier {
    private static let audioDeviceClassMajor: UInt32 = 0x04
    private static let audioServiceClassMask: UInt32 = 0x100
    private static let headphoneMinorClasses: Set<UInt32> = [
        0x01, // Headset
        0x02, // Hands-free
        0x06, // Headphones
        0x07  // Portable audio
    ]

    static func kind(
        name: String,
        deviceClassMajor: UInt32,
        deviceClassMinor: UInt32,
        serviceClassMajor: UInt32,
        isActiveBluetoothOutput: Bool
    ) -> AudioAccessoryKind? {
        let normalizedName = normalized(name)

        if normalizedName.contains("airpodsmax") { return .airPodsMax }
        if normalizedName.contains("airpodspro") { return .airPodsPro }
        if normalizedName.contains("airpods") { return .airPods }

        let headphoneNameTokens = [
            "headphone", "headset", "earbud", "earphone", "buds", "beats"
        ]
        if headphoneNameTokens.contains(where: normalizedName.contains) {
            return .headphones
        }

        guard deviceClassMajor == audioDeviceClassMajor else {
            // Some audio accessories report an unclassified Bluetooth class.
            // Accept one only when CoreAudio independently confirms that it is
            // the current Bluetooth output; this avoids treating mice, phones
            // and other paired devices as headphones.
            return isActiveBluetoothOutput && serviceClassMajor & audioServiceClassMask != 0
                ? .headphones
                : nil
        }

        if headphoneMinorClasses.contains(deviceClassMinor) { return .headphones }
        if isActiveBluetoothOutput { return .headphones }
        return nil
    }

    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        return min(left.count, right.count) >= 5
            && (left.contains(right) || right.contains(left))
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
    }
}

enum AudioAccessoryBatteryMath {
    static func percent(rawValue: Int, logicalMinimum: Int, logicalMaximum: Int) -> Int? {
        guard logicalMaximum > logicalMinimum,
              rawValue >= logicalMinimum,
              rawValue <= logicalMaximum
        else { return nil }

        let fraction = Double(rawValue - logicalMinimum)
            / Double(logicalMaximum - logicalMinimum)
        return min(100, max(0, Int((fraction * 100).rounded())))
    }
}

/// Watches public CoreAudio and IOBluetooth notifications to describe connected
/// headphone accessories. IOBluetooth owns physical connection truth, while
/// CoreAudio only marks which connected accessory is the current output. No
/// private framework, selector or undocumented preference key is used.
@MainActor
final class AudioAccessoryService: NSObject, ObservableObject {
    @Published private(set) var connectedAccessories: [AudioAccessorySnapshot] = []
    @Published private(set) var activeAccessory: AudioAccessorySnapshot?
    @Published private(set) var connectionEvent: AudioAccessoryConnectionEvent?

    private struct CachedBattery {
        let levels: AudioAccessoryBatteryLevels
        let readAt: Date
    }

    private var isStarted = false
    private var tracker = AudioAccessoryTransitionTracker()
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var fallbackPoller: AnyCancellable?
    private var batteryCache: [String: CachedBattery] = [:]
    private var knownAccessoryKinds: [String: AudioAccessoryKind] = [:]
    private var physicallyConnectedIDs: Set<String> = []
    private var hasPhysicalConnectionBaseline = false
    private var batteryEnrichmentTask: Task<Void, Never>?
    private var batteryRetryTask: Task<Void, Never>?
    private var pendingConnectionEvents: [String: AudioAccessoryConnectionEvent] = [:]
    private var pendingConnectionTasks: [String: Task<Void, Never>] = [:]
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    func start() {
        guard !isStarted else { return }
        isStarted = true
        tracker.reset()
        connectionEvent = nil

        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(bluetoothDeviceConnected(_:device:))
        )
        installDefaultOutputListener()
        reconcileConnectedAccessories()

        // IOBluetooth notifications are the primary source. The low-frequency
        // reconciliation covers wake-from-sleep and framework notification
        // loss without polling CoreAudio at animation cadence.
        fallbackPoller = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reconcileConnectedAccessories()
            }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        fallbackPoller?.cancel()
        fallbackPoller = nil
        batteryEnrichmentTask?.cancel()
        batteryEnrichmentTask = nil
        batteryRetryTask?.cancel()
        batteryRetryTask = nil
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        pendingConnectionTasks.values.forEach { $0.cancel() }
        pendingConnectionTasks = [:]
        pendingConnectionEvents = [:]
        removeDefaultOutputListener()
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications = [:]
        batteryCache = [:]
        knownAccessoryKinds = [:]
        physicallyConnectedIDs = []
        hasPhysicalConnectionBaseline = false
        tracker.reset()
        connectedAccessories = []
        activeAccessory = nil
        connectionEvent = nil
    }

    /// Public for foreground/wake reconciliation. Once `start()` has primed the
    /// baseline, this emits only genuine physical additions/removals.
    func refresh() {
        guard isStarted else { return }
        reconcileConnectedAccessories()
    }

    @objc private func bluetoothDeviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isStarted else { return }
            self.registerDisconnectNotification(for: device)
            if let id = Self.identifier(for: device) {
                self.batteryCache[id] = nil
            }
            // Give Bluetooth and system_profiler a brief moment to publish the
            // same connection before starting the battery-enrichment process.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, self.isStarted else { return }
            self.reconcileConnectedAccessories()
        }
    }

    @objc private func bluetoothDeviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isStarted else { return }
            if let id = Self.identifier(for: device) {
                self.disconnectNotifications.removeValue(forKey: id)?.unregister()
                self.batteryCache[id] = nil
            }
            self.reconcileConnectedAccessories()
        }
    }

    private func reconcileConnectedAccessories() {
        scanGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            let scan = await Task.detached(priority: .utility) {
                (Self.readConnectedDevices(), CoreAudioOutputReader.defaultOutput())
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.isStarted,
                  self.scanGeneration == generation
            else { return }
            self.applyConnectedDeviceScan(scan.0, output: scan.1)
        }
    }

    private func applyConnectedDeviceScan(
        _ connectedDevices: [AudioAccessoryRawDevice],
        output: CoreAudioOutputDescriptor?
    ) {
        let currentPhysicalIDs = Set(connectedDevices.map(\.id))
        let newlyConnectedIDs = hasPhysicalConnectionBaseline
            ? currentPhysicalIDs.subtracting(physicallyConnectedIDs)
            : []
        let newlyDisconnectedIDs = hasPhysicalConnectionBaseline
            ? physicallyConnectedIDs.subtracting(currentPhysicalIDs)
            : []

        var snapshots: [AudioAccessorySnapshot] = []
        for device in connectedDevices {
            registerDisconnectNotification(forID: device.id)
            guard let snapshot = snapshot(for: device, defaultOutput: output) else { continue }
            snapshots.append(snapshot)
        }

        snapshots.sort {
            if $0.isActiveOutput != $1.isActiveOutput { return $0.isActiveOutput }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        connectedAccessories = snapshots
        activeAccessory = snapshots.first(where: \.isActiveOutput)

        let events = tracker.update(snapshots).filter { event in
            switch event.state {
            case .connected: newlyConnectedIDs.contains(event.accessory.id)
            case .disconnected: newlyDisconnectedIDs.contains(event.accessory.id)
            }
        }
        handleTransitionEvents(events)
        physicallyConnectedIDs = currentPhysicalIDs
        hasPhysicalConnectionBaseline = true

        for id in disconnectNotifications.keys where !currentPhysicalIDs.contains(id) {
            disconnectNotifications.removeValue(forKey: id)?.unregister()
            batteryCache[id] = nil
        }

        requestBatteryEnrichment(
            for: snapshots,
            forceProfileRefresh: events.contains { $0.state == .connected }
        )
    }

    private func snapshot(
        for device: AudioAccessoryRawDevice,
        defaultOutput: CoreAudioOutputDescriptor?
    ) -> AudioAccessorySnapshot? {
        let id = device.id
        let fallbackName = defaultOutput?.name ?? "Bluetooth kulaklık"
        let name = device.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name?.isEmpty == false ? name! : fallbackName
        let isActiveOutput = defaultOutput?.isBluetooth == true
            && AudioAccessoryClassifier.namesMatch(resolvedName, defaultOutput?.name ?? "")
        let inferredKind = AudioAccessoryClassifier.kind(
            name: resolvedName,
            deviceClassMajor: device.deviceClassMajor,
            deviceClassMinor: device.deviceClassMinor,
            serviceClassMajor: device.serviceClassMajor,
            isActiveBluetoothOutput: isActiveOutput
        )
        guard let kind = inferredKind ?? knownAccessoryKinds[id] else { return nil }
        if let inferredKind { knownAccessoryKinds[id] = inferredKind }
        let battery = cachedBattery(for: id)

        return AudioAccessorySnapshot(
            id: id,
            name: resolvedName,
            kind: kind,
            batteryPercent: battery?.combinedPercent,
            batteryLeftPercent: battery?.leftPercent,
            batteryRightPercent: battery?.rightPercent,
            batteryCasePercent: battery?.casePercent,
            isConnected: true,
            isActiveOutput: isActiveOutput
        )
    }

    private func cachedBattery(for id: String) -> AudioAccessoryBatteryLevels? {
        guard let cached = batteryCache[id], Date().timeIntervalSince(cached.readAt) < 30 else {
            return nil
        }
        return cached.levels
    }

    private func handleTransitionEvents(_ events: [AudioAccessoryConnectionEvent]) {
        for event in events {
            switch event.state {
            case .connected:
                let id = event.accessory.id
                pendingConnectionEvents[id] = event
                pendingConnectionTasks[id]?.cancel()
                pendingConnectionTasks[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled else { return }
                    self?.publishPendingConnectionEvent(id: id)
                }
            case .disconnected:
                let id = event.accessory.id
                pendingConnectionTasks.removeValue(forKey: id)?.cancel()
                pendingConnectionEvents[id] = nil
                connectionEvent = event
            }
        }
    }

    private func publishPendingConnectionEvent(id: String) {
        pendingConnectionTasks.removeValue(forKey: id)?.cancel()
        guard let pending = pendingConnectionEvents.removeValue(forKey: id) else { return }
        let enriched = connectedAccessories.first(where: { $0.id == id }) ?? pending.accessory
        connectionEvent = AudioAccessoryConnectionEvent(state: .connected, accessory: enriched)
    }

    private func requestBatteryEnrichment(
        for snapshots: [AudioAccessorySnapshot],
        forceProfileRefresh: Bool,
        scheduleRetry: Bool = true
    ) {
        let descriptors = snapshots.compactMap { snapshot -> AudioAccessoryBatteryDescriptor? in
            if !forceProfileRefresh, cachedBattery(for: snapshot.id) != nil { return nil }
            return AudioAccessoryBatteryDescriptor(id: snapshot.id, name: snapshot.name)
        }
        guard !descriptors.isEmpty else { return }

        batteryEnrichmentTask?.cancel()
        batteryEnrichmentTask = Task { @MainActor [weak self] in
            let results = await AudioAccessoryBatteryProfiler.shared.levels(
                for: descriptors,
                forceProfileRefresh: forceProfileRefresh
            )
            guard !Task.isCancelled, let self, self.isStarted else { return }

            let currentIDs = Set(self.connectedAccessories.map(\.id))
            var enriched = self.connectedAccessories
            for descriptor in descriptors where currentIDs.contains(descriptor.id) {
                let id = descriptor.id
                guard let levels = results[id] else { continue }
                self.batteryCache[id] = CachedBattery(levels: levels, readAt: Date())
                if let index = enriched.firstIndex(where: { $0.id == id }) {
                    enriched[index] = enriched[index].withBattery(levels)
                }
            }
            self.connectedAccessories = enriched
            self.activeAccessory = enriched.first(where: \.isActiveOutput)
            _ = self.tracker.update(enriched)

            // The original physical transition is published exactly once. If
            // profiling completed within the short grace period, the pop-up's
            // immutable event already contains left/right/case battery data.
            for id in results.keys where self.pendingConnectionEvents[id] != nil {
                self.publishPendingConnectionEvent(id: id)
            }

            if forceProfileRefresh,
               scheduleRetry,
               descriptors.contains(where: { results[$0.id] == nil }) {
                self.batteryRetryTask?.cancel()
                self.batteryRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled, let self, self.isStarted else { return }
                    self.requestBatteryEnrichment(
                        for: self.connectedAccessories,
                        forceProfileRefresh: true,
                        scheduleRetry: false
                    )
                }
            }
        }
    }

    private func registerDisconnectNotification(for device: IOBluetoothDevice) {
        guard let id = Self.identifier(for: device), disconnectNotifications[id] == nil else { return }
        disconnectNotifications[id] = device.register(
            forDisconnectNotification: self,
            selector: #selector(bluetoothDeviceDisconnected(_:device:))
        )
    }

    private func registerDisconnectNotification(forID id: String) {
        guard disconnectNotifications[id] == nil,
              let device = IOBluetoothDevice(addressString: id)
        else { return }
        registerDisconnectNotification(for: device)
    }

    nonisolated private static func readConnectedDevices() -> [AudioAccessoryRawDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { device in
            guard device.isConnected(), let id = identifier(for: device) else { return nil }
            return AudioAccessoryRawDevice(
                id: id,
                name: device.name,
                deviceClassMajor: UInt32(device.deviceClassMajor),
                deviceClassMinor: UInt32(device.deviceClassMinor),
                serviceClassMajor: UInt32(device.serviceClassMajor)
            )
        }
    }

    nonisolated private static func identifier(for device: IOBluetoothDevice) -> String? {
        guard let address = device.addressString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty
        else { return nil }
        return address.uppercased()
    }

    private func installDefaultOutputListener() {
        removeDefaultOutputListener()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.reconcileConnectedAccessories()
            }
        }
        var address = CoreAudioOutputReader.defaultOutputAddress
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        ) == noErr else { return }
        defaultOutputListener = listener
    }

    private func removeDefaultOutputListener() {
        guard let defaultOutputListener else { return }
        var address = CoreAudioOutputReader.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            defaultOutputListener
        )
        self.defaultOutputListener = nil
    }
}

private struct CoreAudioOutputDescriptor {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

private enum CoreAudioOutputReader {
    static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutput() -> CoreAudioOutputDescriptor? {
        var address = defaultOutputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }

        guard let name = stringProperty(device, selector: kAudioObjectPropertyName) else { return nil }
        let uid = stringProperty(device, selector: kAudioDevicePropertyDeviceUID) ?? "audio-\(device)"
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &transportAddress,
            0,
            nil,
            &size,
            &transportType
        ) == noErr else { return nil }

        return CoreAudioOutputDescriptor(
            id: device,
            name: name,
            uid: uid,
            transportType: transportType
        )
    }

    private static func stringProperty(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

private struct AudioAccessoryBatteryDescriptor: Equatable, Sendable {
    let id: String
    let name: String
}

struct SystemProfilerBluetoothBatteryRecord: Equatable, Sendable {
    let name: String
    let levels: AudioAccessoryBatteryLevels
}

enum SystemProfilerBluetoothBatteryParser {
    static func records(from data: Data) -> [SystemProfilerBluetoothBatteryRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var records: [SystemProfilerBluetoothBatteryRecord] = []
        for report in reports {
            // Intentionally ignore `device_not_connected`. system_profiler may
            // retain old AirPods battery fields there long after disconnection.
            guard let connectedEntries = report["device_connected"] as? [[String: Any]] else { continue }
            for entry in connectedEntries {
                for (name, rawProperties) in entry {
                    guard let properties = rawProperties as? [String: Any] else { continue }
                    let levels = AudioAccessoryBatteryLevels(
                        mainPercent: firstPercent(
                            in: properties,
                            keys: ["device_batteryLevelMain", "device_batteryLevel"]
                        ),
                        leftPercent: percent(properties["device_batteryLevelLeft"]),
                        rightPercent: percent(properties["device_batteryLevelRight"]),
                        casePercent: percent(properties["device_batteryLevelCase"])
                    )
                    records.append(SystemProfilerBluetoothBatteryRecord(name: name, levels: levels))
                }
            }
        }
        return records
    }

    private static func firstPercent(in properties: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = percent(properties[key]) { return value }
        }
        return nil
    }

    private static func percent(_ rawValue: Any?) -> Int? {
        if let number = rawValue as? NSNumber {
            let value = number.intValue
            return (0...100).contains(value) ? value : nil
        }
        guard let text = rawValue as? String else { return nil }
        let digits = text.unicodeScalars.filter(CharacterSet.decimalDigits.contains)
        guard !digits.isEmpty, let value = Int(String(String.UnicodeScalarView(digits))) else { return nil }
        return (0...100).contains(value) ? value : nil
    }
}

private actor AudioAccessoryBatteryProfiler {
    static let shared = AudioAccessoryBatteryProfiler()

    private var cachedRecords: [SystemProfilerBluetoothBatteryRecord] = []
    private var cacheDate = Date.distantPast
    private var inFlight: Task<[SystemProfilerBluetoothBatteryRecord], Never>?

    func levels(
        for descriptors: [AudioAccessoryBatteryDescriptor],
        forceProfileRefresh: Bool
    ) async -> [String: AudioAccessoryBatteryLevels] {
        let records = await systemProfilerRecords(forceRefresh: forceProfileRefresh)
        return await Task.detached(priority: .utility) {
            var result: [String: AudioAccessoryBatteryLevels] = [:]
            for descriptor in descriptors {
                let matches = records.filter {
                    AudioAccessoryClassifier.namesMatch(descriptor.name, $0.name)
                }
                // Require a unique record from the physically connected
                // section. Ambiguous same-name devices intentionally yield no
                // system_profiler battery rather than the wrong percentage.
                let profilerLevels = matches.count == 1
                    ? matches[0].levels
                    : AudioAccessoryBatteryLevels(
                        mainPercent: nil,
                        leftPercent: nil,
                        rightPercent: nil,
                        casePercent: nil
                    )
                let hidPercent = PublicHIDBatteryReader.batteryPercent(
                    deviceName: descriptor.name,
                    bluetoothAddress: descriptor.id
                )
                let levels = profilerLevels.mergingHIDPercent(hidPercent)
                if levels.combinedPercent != nil || levels.casePercent != nil {
                    result[descriptor.id] = levels
                }
            }
            return result
        }.value
    }

    private func systemProfilerRecords(
        forceRefresh: Bool
    ) async -> [SystemProfilerBluetoothBatteryRecord] {
        if !forceRefresh, Date().timeIntervalSince(cacheDate) < 12 {
            return cachedRecords
        }
        if let inFlight { return await inFlight.value }

        let task = Task.detached(priority: .utility) {
            SystemProfilerBluetoothBatteryRunner.readRecords()
        }
        inFlight = task
        let records = await task.value
        cachedRecords = records
        cacheDate = Date()
        inFlight = nil
        return records
    }
}

private enum SystemProfilerBluetoothBatteryRunner {
    nonisolated static func readRecords() -> [SystemProfilerBluetoothBatteryRecord] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "mini"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LANG": "C", "LC_ALL": "C"],
            uniquingKeysWith: { _, new in new }
        )
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        // Draining before wait avoids a full pipe deadlock on Macs with many
        // paired devices. This method always runs on a detached utility task.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return SystemProfilerBluetoothBatteryParser.records(from: data)
    }
}

/// Reads only the standardized, public HID Battery Strength usage. AirPods do
/// not normally publish that usage on macOS, in which case returning nil is the
/// correct and safe result. This intentionally avoids IORegistry scraping and
/// private Bluetooth battery selectors.
private enum PublicHIDBatteryReader {
    private struct Candidate {
        let score: Int
        let percent: Int
    }

    static func batteryPercent(deviceName: String, bluetoothAddress: String) -> Int? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        let normalizedName = AudioAccessoryClassifier.normalized(deviceName)
        let normalizedAddress = AudioAccessoryClassifier.normalized(bluetoothAddress)
        var candidates: [Candidate] = []

        for device in devices {
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            let normalizedProduct = AudioAccessoryClassifier.normalized(product)
            let normalizedSerial = AudioAccessoryClassifier.normalized(serial)
            let normalizedTransport = AudioAccessoryClassifier.normalized(transport)

            guard normalizedTransport.contains("bluetooth") else { continue }
            let score: Int
            if !normalizedAddress.isEmpty, normalizedSerial == normalizedAddress {
                score = 3
            } else if !normalizedName.isEmpty, normalizedProduct == normalizedName {
                score = 2
            } else if min(normalizedProduct.count, normalizedName.count) >= 5,
                      normalizedProduct.contains(normalizedName) || normalizedName.contains(normalizedProduct) {
                score = 1
            } else {
                continue
            }

            guard let percent = batteryPercent(for: device) else { continue }
            candidates.append(Candidate(score: score, percent: percent))
        }

        guard let bestScore = candidates.map(\.score).max() else { return nil }
        let best = candidates.filter { $0.score == bestScore }
        // A product-name-only match is not reliable when two identical devices
        // are present. Prefer no percentage over showing another device's value.
        guard best.count == 1 else { return nil }
        return best[0].percent
    }

    private static func batteryPercent(for device: IOHIDDevice) -> Int? {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return nil }

        for element in elements {
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let isBatteryStrength =
                (usagePage == UInt32(kHIDPage_GenericDeviceControls)
                    && usage == UInt32(kHIDUsage_GenDevControls_BatteryStrength))
                || (usagePage == UInt32(kHIDPage_Digitizer)
                    && usage == UInt32(kHIDUsage_Dig_BatteryStrength))
            guard isBatteryStrength else { continue }

            var unmanagedValue: Unmanaged<IOHIDValue>!
            guard IOHIDDeviceGetValue(device, element, &unmanagedValue) == kIOReturnSuccess,
                  let value = unmanagedValue?.takeUnretainedValue()
            else { continue }

            if let percent = AudioAccessoryBatteryMath.percent(
                rawValue: IOHIDValueGetIntegerValue(value),
                logicalMinimum: IOHIDElementGetLogicalMin(element),
                logicalMaximum: IOHIDElementGetLogicalMax(element)
            ) {
                return percent
            }
        }
        return nil
    }
}
