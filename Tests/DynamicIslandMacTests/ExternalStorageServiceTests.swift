import XCTest
@testable import DynamicIslandMac

final class ExternalStorageServiceTests: XCTestCase {
    func testClassifierAcceptsUSBThunderboltAndSDTransports() throws {
        let resources = fixtureResources()

        let usb = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: resources,
            disk: fixtureDisk(protocol: "USB")
        ))
        XCTAssertEqual(usb.kind, .usb)

        let thunderbolt = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: resources,
            disk: fixtureDisk(protocol: "PCI-Express", path: "IOService:/IOThunderboltPort/Drive")
        ))
        XCTAssertEqual(thunderbolt.kind, .thunderbolt)

        let sd = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: resources,
            disk: fixtureDisk(protocol: "USB", model: "Apple SDXC Card Reader")
        ))
        XCTAssertEqual(sd.kind, .sdCard)
    }

    func testClassifierPublishesNameStableIdentityAndClampedCapacity() throws {
        let resources = ExternalStorageResourceSnapshot(
            url: URL(fileURLWithPath: "/Volumes/Work"),
            name: "  Project Drive  ",
            volumeUUID: "VOLUME-UUID",
            totalCapacityBytes: 2_000,
            availableCapacityBytes: 2_500
        )
        let volume = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: resources,
            disk: fixtureDisk(protocol: "USB")
        ))

        XCTAssertEqual(volume.id, "VOLUME-UUID")
        XCTAssertEqual(volume.name, "Project Drive")
        XCTAssertEqual(volume.totalCapacityBytes, 2_000)
        XCTAssertEqual(volume.availableCapacityBytes, 2_000)
        XCTAssertEqual(volume.usedCapacityBytes, 0)
        XCTAssertEqual(volume.usedFraction, 0)
    }

    func testClassifierRejectsInternalSystemNetworkDiskImageAndUnsupportedVolumes() {
        XCTAssertNil(ExternalStorageClassifier.volume(
            resources: fixtureResources(path: "/"),
            disk: fixtureDisk(protocol: "USB")
        ))
        XCTAssertNil(ExternalStorageClassifier.volume(
            resources: fixtureResources(isInternal: true),
            disk: fixtureDisk(protocol: "Apple Fabric", isInternal: true)
        ))
        XCTAssertNil(ExternalStorageClassifier.volume(
            resources: fixtureResources(isLocal: false),
            disk: fixtureDisk(protocol: "SMB", isNetwork: true)
        ))
        XCTAssertNil(ExternalStorageClassifier.volume(
            resources: fixtureResources(),
            disk: fixtureDisk(protocol: "Disk Image", model: "Apple Disk Image")
        ))
        XCTAssertNil(ExternalStorageClassifier.volume(
            resources: fixtureResources(),
            disk: fixtureDisk(protocol: "SATA")
        ))
        XCTAssertNil(ExternalStorageClassifier.volume(
            resources: fixtureResources(isHidden: true),
            disk: fixtureDisk(protocol: "USB")
        ))
    }

    func testInitialBaselineIsSilentAndDuplicateMountDoesNotRepeatEvent() throws {
        let initial = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: fixtureResources(path: "/Volumes/Already Here", uuid: "initial"),
            disk: fixtureDisk(protocol: "USB")
        ))
        let added = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: fixtureResources(path: "/Volumes/New Drive", uuid: "new"),
            disk: fixtureDisk(protocol: "Thunderbolt")
        ))
        var inventory = ExternalStorageInventory()

        inventory.establishBaseline([initial])
        XCTAssertEqual(inventory.sortedVolumes, [initial])

        let connected = try XCTUnwrap(inventory.recordMount(added))
        XCTAssertEqual(connected.action, .connected)
        XCTAssertEqual(connected.volume, added)
        XCTAssertNil(inventory.recordMount(added))
        XCTAssertEqual(Set(inventory.sortedVolumes.map(\.id)), ["initial", "new"])
    }

    func testUnmountUsesRememberedSnapshotAfterFilesystemDisappears() throws {
        let volume = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: fixtureResources(path: "/Volumes/Travel", uuid: "travel"),
            disk: fixtureDisk(protocol: "USB")
        ))
        var inventory = ExternalStorageInventory()
        inventory.establishBaseline([volume])

        let disconnected = try XCTUnwrap(
            inventory.recordUnmount(at: URL(fileURLWithPath: "/Volumes/Travel/../Travel"))
        )
        XCTAssertEqual(disconnected.action, .disconnected)
        XCTAssertEqual(disconnected.volume, volume)
        XCTAssertTrue(inventory.sortedVolumes.isEmpty)
        XCTAssertNil(inventory.recordUnmount(at: volume.mountURL))
    }

    func testMountNotificationCanReplayAfterSilentBaseline() throws {
        let volume = try XCTUnwrap(ExternalStorageClassifier.volume(
            resources: fixtureResources(path: "/Volumes/Replay", uuid: "replay"),
            disk: fixtureDisk(protocol: "USB")
        ))
        var inventory = ExternalStorageInventory()
        inventory.establishBaseline([volume])

        let replayed = try XCTUnwrap(inventory.recordMount(volume, forceEvent: true))
        XCTAssertEqual(replayed.action, .connected)
        XCTAssertEqual(replayed.volume, volume)
        XCTAssertEqual(inventory.sortedVolumes, [volume])
    }

    private func fixtureResources(
        path: String = "/Volumes/External",
        uuid: String? = "external-uuid",
        isHidden: Bool = false,
        isLocal: Bool? = true,
        isInternal: Bool? = false
    ) -> ExternalStorageResourceSnapshot {
        ExternalStorageResourceSnapshot(
            url: URL(fileURLWithPath: path),
            name: "External",
            volumeUUID: uuid,
            isHidden: isHidden,
            isLocal: isLocal,
            isInternal: isInternal
        )
    }

    private func fixtureDisk(
        protocol deviceProtocol: String,
        model: String = "",
        path: String = "",
        isInternal: Bool? = false,
        isNetwork: Bool? = false
    ) -> ExternalStorageDiskDescription {
        ExternalStorageDiskDescription(
            volumeIsNetwork: isNetwork,
            deviceIsInternal: isInternal,
            deviceProtocol: deviceProtocol,
            deviceModel: model,
            devicePath: path
        )
    }
}
