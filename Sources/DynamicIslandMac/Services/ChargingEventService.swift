import Combine
import Foundation
import IOKit.ps

struct ChargingPowerSnapshot: Equatable, Sendable {
    let isConnectedToAC: Bool
    let isCharging: Bool
    let batteryPercentage: Int?
    let estimatedMinutesToFull: Int?
}

struct ChargingConnectionEvent: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case connectedToPower
        case disconnectedFromPower
    }

    let id: UUID
    let kind: Kind
    let snapshot: ChargingPowerSnapshot
    let occurredAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        snapshot: ChargingPowerSnapshot,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.snapshot = snapshot
        self.occurredAt = occurredAt
    }
}

struct ChargingConnectionTransitionDetector {
    private(set) var previousSnapshot: ChargingPowerSnapshot?

    mutating func process(_ snapshot: ChargingPowerSnapshot) -> ChargingConnectionEvent.Kind? {
        defer { previousSnapshot = snapshot }
        guard let previousSnapshot,
              previousSnapshot.isConnectedToAC != snapshot.isConnectedToAC
        else { return nil }

        return snapshot.isConnectedToAC ? .connectedToPower : .disconnectedFromPower
    }

    mutating func reset() {
        previousSnapshot = nil
    }
}

private enum ChargingPowerSnapshotReader {
    static func read() -> ChargingPowerSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
        else { return nil }

        for source in sourceList as NSArray {
            guard let description = IOPSGetPowerSourceDescription(info, source as AnyObject)?
                .takeUnretainedValue() as NSDictionary?,
                  isInternalBattery(description)
            else { continue }

            let powerSourceState = description[kIOPSPowerSourceStateKey] as? String
            let isConnectedToAC = powerSourceState == kIOPSACPowerValue
            let isCharging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false

            return ChargingPowerSnapshot(
                isConnectedToAC: isConnectedToAC,
                isCharging: isCharging,
                batteryPercentage: batteryPercentage(from: description),
                estimatedMinutesToFull: estimatedMinutesToFull(
                    from: description,
                    isCharging: isCharging
                )
            )
        }

        return nil
    }

    private static func isInternalBattery(_ description: NSDictionary) -> Bool {
        let type = description[kIOPSTypeKey] as? String
        let transportType = description[kIOPSTransportTypeKey] as? String
        return type == kIOPSInternalBatteryType || transportType == kIOPSInternalType
    }

    private static func batteryPercentage(from description: NSDictionary) -> Int? {
        guard let currentCapacity = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximumCapacity = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
              maximumCapacity > 0
        else { return nil }

        let percentage = Int((currentCapacity / maximumCapacity * 100).rounded())
        return min(100, max(0, percentage))
    }

    private static func estimatedMinutesToFull(
        from description: NSDictionary,
        isCharging: Bool
    ) -> Int? {
        guard isCharging,
              let minutes = (description[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue,
              minutes >= 0
        else { return nil }
        return minutes
    }
}

@MainActor
final class ChargingEventService: ObservableObject {
    @Published private(set) var currentSnapshot: ChargingPowerSnapshot?
    @Published private(set) var incomingEvent: ChargingConnectionEvent?

    private var notificationSource: CFRunLoopSource?
    private var transitionDetector = ChargingConnectionTransitionDetector()

    func start() {
        guard notificationSource == nil else { return }

        if let source = IOPSNotificationCreateRunLoopSource(
            chargingPowerSourceDidChange,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() {
            notificationSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        refresh()
    }

    func stop() {
        if let notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
            CFRunLoopSourceInvalidate(notificationSource)
            self.notificationSource = nil
        }

        currentSnapshot = nil
        incomingEvent = nil
        transitionDetector.reset()
    }

    func refresh() {
        guard let snapshot = ChargingPowerSnapshotReader.read() else { return }
        currentSnapshot = snapshot

        guard let kind = transitionDetector.process(snapshot) else { return }
        incomingEvent = ChargingConnectionEvent(kind: kind, snapshot: snapshot)
    }

    deinit {
        if let notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
            CFRunLoopSourceInvalidate(notificationSource)
        }
    }
}

private let chargingPowerSourceDidChange: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let service = Unmanaged<ChargingEventService>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        service.refresh()
    }
}
