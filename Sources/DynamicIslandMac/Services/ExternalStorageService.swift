import AppKit
import Combine
import DiskArbitration
import Foundation

enum ExternalStorageKind: String, CaseIterable, Sendable {
    case usb
    case thunderbolt
    case sdCard

    var displayName: String {
        switch self {
        case .usb: "USB"
        case .thunderbolt: "Thunderbolt"
        case .sdCard: "SD Kart"
        }
    }

    var systemImageName: String {
        switch self {
        case .usb: "externaldrive.fill"
        case .thunderbolt: "bolt.horizontal.fill"
        case .sdCard: "sdcard.fill"
        }
    }
}

struct ExternalStorageVolume: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: ExternalStorageKind
    let totalCapacityBytes: Int64
    let availableCapacityBytes: Int64
    let mountURL: URL

    var usedCapacityBytes: Int64 {
        max(0, totalCapacityBytes - availableCapacityBytes)
    }

    var usedFraction: Double {
        guard totalCapacityBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedCapacityBytes) / Double(totalCapacityBytes)))
    }
}

enum ExternalStorageEventAction: String, Sendable {
    case connected
    case disconnected
}

struct ExternalStorageEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let action: ExternalStorageEventAction
    let volume: ExternalStorageVolume

    init(id: UUID = UUID(), action: ExternalStorageEventAction, volume: ExternalStorageVolume) {
        self.id = id
        self.action = action
        self.volume = volume
    }
}

/// Watches user-visible filesystem mounts and emits events only for physical
/// USB, Thunderbolt and SD storage. The first scan establishes state without
/// producing a HUD event, so disks connected before app launch stay silent.
@MainActor
final class ExternalStorageService: ObservableObject {
    @Published private(set) var connectedVolumes: [ExternalStorageVolume] = []
    @Published private(set) var latestEvent: ExternalStorageEvent?

    private let workspace: NSWorkspace
    private var inventory = ExternalStorageInventory()
    private var observerTokens: [NSObjectProtocol] = []
    private var baselineTask: Task<Void, Never>?
    private var eventProcessingTask: Task<Void, Never>?
    private var isStarted = false
    private var hasEstablishedBaseline = false
    private var pendingWorkspaceEvents: [PendingWorkspaceEvent] = []

    private enum PendingWorkspaceEvent {
        case mounted(URL)
        case unmounted(URL)
    }

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        hasEstablishedBaseline = false
        latestEvent = nil
        installWorkspaceObservers()
        baselineTask?.cancel()
        baselineTask = Task { @MainActor [weak self] in
            let initialVolumes = await Task.detached(priority: .utility) {
                Self.mountedVolumeURLs.compactMap(Self.inspectVolume(at:))
            }.value
            guard !Task.isCancelled, let self, self.isStarted else { return }
            self.inventory.establishBaseline(initialVolumes)
            self.connectedVolumes = self.inventory.sortedVolumes
            self.hasEstablishedBaseline = true
            self.drainWorkspaceEventsIfNeeded()
        }
    }

    private func installWorkspaceObservers() {
        guard observerTokens.isEmpty, isStarted else { return }
        let center = workspace.notificationCenter
        observerTokens = [
            center.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleMountNotification(notification)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleUnmountNotification(notification)
                }
            }
        ]
    }

    func stop() {
        isStarted = false
        let center = workspace.notificationCenter
        observerTokens.forEach(center.removeObserver)
        observerTokens.removeAll()
        baselineTask?.cancel()
        baselineTask = nil
        eventProcessingTask?.cancel()
        eventProcessingTask = nil
        hasEstablishedBaseline = false
        pendingWorkspaceEvents = []
        inventory = ExternalStorageInventory()
        connectedVolumes = []
        latestEvent = nil
    }

    func clearLatestEvent(id: UUID? = nil) {
        guard id == nil || latestEvent?.id == id else { return }
        latestEvent = nil
    }

    private func handleMountNotification(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        pendingWorkspaceEvents.append(.mounted(url))
        drainWorkspaceEventsIfNeeded()
    }

    private func handleUnmountNotification(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        pendingWorkspaceEvents.append(.unmounted(url))
        drainWorkspaceEventsIfNeeded()
    }

    private func drainWorkspaceEventsIfNeeded() {
        guard hasEstablishedBaseline, eventProcessingTask == nil, !pendingWorkspaceEvents.isEmpty else { return }
        eventProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isStarted, self.hasEstablishedBaseline, !self.pendingWorkspaceEvents.isEmpty {
                let event = self.pendingWorkspaceEvents.removeFirst()
                switch event {
                case .mounted(let url):
                    let inspected = await Task.detached(priority: .utility) {
                        let volume = Self.inspectVolume(at: url)
                        let stillMounted = volume.map {
                            FileManager.default.fileExists(atPath: $0.mountURL.path)
                        } ?? false
                        return (volume, stillMounted)
                    }.value
                    guard !Task.isCancelled,
                          self.isStarted,
                          inspected.1,
                          let volume = inspected.0
                    else { continue }
                    if let connected = self.inventory.recordMount(volume, forceEvent: true) {
                        self.latestEvent = connected
                    }
                case .unmounted(let url):
                    if let disconnected = self.inventory.recordUnmount(at: url) {
                        self.latestEvent = disconnected
                    }
                }
                self.connectedVolumes = self.inventory.sortedVolumes
            }
            self.eventProcessingTask = nil
            self.drainWorkspaceEventsIfNeeded()
        }
    }

    nonisolated private static var mountedVolumeURLs: [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(ExternalStorageResourceSnapshot.requiredKeys),
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    nonisolated private static func inspectVolume(at url: URL) -> ExternalStorageVolume? {
        guard let resources = ExternalStorageResourceSnapshot(url: url),
              let disk = ExternalStorageDiskDescription(url: resources.url)
        else { return nil }
        return ExternalStorageClassifier.volume(resources: resources, disk: disk)
    }
}

struct ExternalStorageResourceSnapshot: Equatable, Sendable {
    static let requiredKeys: Set<URLResourceKey> = [
        .isVolumeKey,
        .isHiddenKey,
        .nameKey,
        .volumeLocalizedNameKey,
        .volumeUUIDStringKey,
        .volumeIsLocalKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey
    ]

    let url: URL
    let name: String
    let volumeUUID: String?
    let isVolume: Bool
    let isHidden: Bool
    let isLocal: Bool?
    let isInternal: Bool?
    let isRemovable: Bool?
    let isEjectable: Bool?
    let totalCapacityBytes: Int64?
    let availableCapacityBytes: Int64?

    init?(url: URL) {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? canonicalURL.resourceValues(forKeys: Self.requiredKeys) else { return nil }

        self.url = canonicalURL
        name = values.volumeLocalizedName
            ?? values.name
            ?? canonicalURL.lastPathComponent
        volumeUUID = values.volumeUUIDString
        isVolume = values.isVolume ?? false
        isHidden = values.isHidden ?? false
        isLocal = values.volumeIsLocal
        isInternal = values.volumeIsInternal
        isRemovable = values.volumeIsRemovable
        isEjectable = values.volumeIsEjectable
        totalCapacityBytes = values.volumeTotalCapacity.map(Int64.init)
        availableCapacityBytes = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
    }

    init(
        url: URL,
        name: String,
        volumeUUID: String? = nil,
        isVolume: Bool = true,
        isHidden: Bool = false,
        isLocal: Bool? = true,
        isInternal: Bool? = false,
        isRemovable: Bool? = true,
        isEjectable: Bool? = true,
        totalCapacityBytes: Int64? = 1_000,
        availableCapacityBytes: Int64? = 400
    ) {
        self.url = url.standardizedFileURL
        self.name = name
        self.volumeUUID = volumeUUID
        self.isVolume = isVolume
        self.isHidden = isHidden
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.totalCapacityBytes = totalCapacityBytes
        self.availableCapacityBytes = availableCapacityBytes
    }
}

struct ExternalStorageDiskDescription: Equatable, Sendable {
    let bsdName: String?
    let volumeUUID: String?
    let volumeIsNetwork: Bool?
    let deviceIsInternal: Bool?
    let mediaIsRemovable: Bool?
    let mediaIsEjectable: Bool?
    let mediaSizeBytes: Int64?
    let deviceProtocol: String
    let deviceModel: String
    let deviceVendor: String
    let devicePath: String
    let mediaName: String
    let mediaKind: String
    let mediaPath: String

    init?(url: URL) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let copiedDescription = DADiskCopyDescription(disk)
        else { return nil }

        let description = copiedDescription as NSDictionary
        bsdName = DADiskGetBSDName(disk).map(String.init(cString:))
        volumeUUID = Self.uuid(kDADiskDescriptionVolumeUUIDKey, in: description)
        volumeIsNetwork = Self.bool(kDADiskDescriptionVolumeNetworkKey, in: description)
        deviceIsInternal = Self.bool(kDADiskDescriptionDeviceInternalKey, in: description)
        mediaIsRemovable = Self.bool(kDADiskDescriptionMediaRemovableKey, in: description)
        mediaIsEjectable = Self.bool(kDADiskDescriptionMediaEjectableKey, in: description)
        mediaSizeBytes = Self.number(kDADiskDescriptionMediaSizeKey, in: description)?.int64Value
        deviceProtocol = Self.string(kDADiskDescriptionDeviceProtocolKey, in: description)
        deviceModel = Self.string(kDADiskDescriptionDeviceModelKey, in: description)
        deviceVendor = Self.string(kDADiskDescriptionDeviceVendorKey, in: description)
        devicePath = Self.string(kDADiskDescriptionDevicePathKey, in: description)
        mediaName = Self.string(kDADiskDescriptionMediaNameKey, in: description)
        mediaKind = Self.string(kDADiskDescriptionMediaKindKey, in: description)
        mediaPath = Self.string(kDADiskDescriptionMediaPathKey, in: description)
    }

    init(
        bsdName: String? = "disk9s1",
        volumeUUID: String? = nil,
        volumeIsNetwork: Bool? = false,
        deviceIsInternal: Bool? = false,
        mediaIsRemovable: Bool? = true,
        mediaIsEjectable: Bool? = true,
        mediaSizeBytes: Int64? = 1_000,
        deviceProtocol: String,
        deviceModel: String = "",
        deviceVendor: String = "",
        devicePath: String = "",
        mediaName: String = "",
        mediaKind: String = "IOMedia",
        mediaPath: String = ""
    ) {
        self.bsdName = bsdName
        self.volumeUUID = volumeUUID
        self.volumeIsNetwork = volumeIsNetwork
        self.deviceIsInternal = deviceIsInternal
        self.mediaIsRemovable = mediaIsRemovable
        self.mediaIsEjectable = mediaIsEjectable
        self.mediaSizeBytes = mediaSizeBytes
        self.deviceProtocol = deviceProtocol
        self.deviceModel = deviceModel
        self.deviceVendor = deviceVendor
        self.devicePath = devicePath
        self.mediaName = mediaName
        self.mediaKind = mediaKind
        self.mediaPath = mediaPath
    }

    private static func value(_ key: CFString, in description: NSDictionary) -> Any? {
        description[key as String]
    }

    private static func string(_ key: CFString, in description: NSDictionary) -> String {
        value(key, in: description) as? String ?? ""
    }

    private static func bool(_ key: CFString, in description: NSDictionary) -> Bool? {
        (value(key, in: description) as? NSNumber)?.boolValue
    }

    private static func number(_ key: CFString, in description: NSDictionary) -> NSNumber? {
        value(key, in: description) as? NSNumber
    }

    private static func uuid(_ key: CFString, in description: NSDictionary) -> String? {
        guard let value = value(key, in: description) else { return nil }
        if let uuid = value as? UUID { return uuid.uuidString }
        if CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            let uuid = unsafeBitCast(value as AnyObject, to: CFUUID.self)
            return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
        }
        return nil
    }
}

enum ExternalStorageClassifier {
    static func volume(
        resources: ExternalStorageResourceSnapshot,
        disk: ExternalStorageDiskDescription
    ) -> ExternalStorageVolume? {
        let path = resources.url.standardizedFileURL.path
        guard resources.isVolume,
              !resources.isHidden,
              path.hasPrefix("/Volumes/"),
              path != "/Volumes",
              resources.isLocal == true,
              disk.volumeIsNetwork != true,
              resources.isInternal != true,
              disk.deviceIsInternal != true,
              resources.isInternal == false || disk.deviceIsInternal == false,
              !isDiskImage(disk),
              let kind = storageKind(disk)
        else { return nil }

        let total = max(0, resources.totalCapacityBytes ?? disk.mediaSizeBytes ?? 0)
        guard total > 0 else { return nil }
        let available = min(total, max(0, resources.availableCapacityBytes ?? 0))
        let trimmedName = resources.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = resources.volumeUUID
            ?? disk.volumeUUID
            ?? disk.bsdName.map { "bsd:\($0)" }
            ?? "path:\(path)"

        return ExternalStorageVolume(
            id: identifier,
            name: trimmedName.isEmpty ? resources.url.lastPathComponent : trimmedName,
            kind: kind,
            totalCapacityBytes: total,
            availableCapacityBytes: available,
            mountURL: resources.url
        )
    }

    static func storageKind(_ disk: ExternalStorageDiskDescription) -> ExternalStorageKind? {
        let transportText = [
            disk.deviceProtocol,
            disk.deviceModel,
            disk.deviceVendor,
            disk.devicePath,
            disk.mediaName,
            disk.mediaKind,
            disk.mediaPath
        ]
        .joined(separator: " ")
        .lowercased()

        let sdMarkers = ["secure digital", "sd card", "sdcard", "sdxc", "sdhc", "iosdxc", "mmc"]
        if sdMarkers.contains(where: transportText.contains) { return .sdCard }
        if transportText.contains("thunderbolt") { return .thunderbolt }
        if transportText.contains("usb") { return .usb }
        return nil
    }

    private static func isDiskImage(_ disk: ExternalStorageDiskDescription) -> Bool {
        let text = [
            disk.deviceProtocol,
            disk.deviceModel,
            disk.devicePath,
            disk.mediaName,
            disk.mediaKind,
            disk.mediaPath
        ]
        .joined(separator: " ")
        .lowercased()
        return text.contains("disk image")
            || text.contains("diskimages")
            || text.contains("diskimagemounter")
            || text.contains("virtual interface")
    }
}

struct ExternalStorageInventory {
    private var volumesByID: [String: ExternalStorageVolume] = [:]

    var sortedVolumes: [ExternalStorageVolume] {
        volumesByID.values.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }

    mutating func establishBaseline(_ volumes: [ExternalStorageVolume]) {
        volumesByID = Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0) })
    }

    mutating func recordMount(
        _ volume: ExternalStorageVolume,
        forceEvent: Bool = false
    ) -> ExternalStorageEvent? {
        if volumesByID[volume.id] != nil {
            volumesByID[volume.id] = volume
            return forceEvent ? ExternalStorageEvent(action: .connected, volume: volume) : nil
        }

        let canonicalPath = Self.canonicalPath(volume.mountURL)
        if let staleID = volumesByID.first(where: {
            Self.canonicalPath($0.value.mountURL) == canonicalPath
        })?.key {
            volumesByID.removeValue(forKey: staleID)
        }
        volumesByID[volume.id] = volume
        return ExternalStorageEvent(action: .connected, volume: volume)
    }

    mutating func recordUnmount(at url: URL) -> ExternalStorageEvent? {
        let path = Self.canonicalPath(url)
        guard let match = volumesByID.first(where: {
            Self.canonicalPath($0.value.mountURL) == path
        }) else { return nil }
        volumesByID.removeValue(forKey: match.key)
        return ExternalStorageEvent(action: .disconnected, volume: match.value)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
