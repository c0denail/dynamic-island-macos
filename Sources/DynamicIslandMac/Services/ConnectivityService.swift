import Combine
@preconcurrency import CoreLocation
import CoreWLAN
import Darwin
import IOBluetooth

struct WiFiNetworkItem: Identifiable, Equatable, Sendable {
    var id: String { ssid }
    let ssid: String
    let rssi: Int
    let isSecure: Bool
    let isKnown: Bool
    let isCurrent: Bool
}

struct BluetoothDeviceItem: Identifiable, Equatable, Sendable {
    var id: String { address }
    let address: String
    let name: String
    let isConnected: Bool
}

@MainActor
final class ConnectivityService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var wifiEnabled = false
    @Published var currentSSID: String?
    @Published var wifiNetworks: [WiFiNetworkItem] = []
    @Published var isScanningWiFi = false
    @Published var connectingWiFiSSID: String?
    @Published var passwordRequiredSSID: String?
    @Published var wifiError: String?
    @Published var locationAuthorization: CLAuthorizationStatus = .notDetermined

    @Published var bluetoothEnabled = false
    @Published var bluetoothStatusKnown = false
    @Published var bluetoothDevices: [BluetoothDeviceItem] = []
    @Published var connectingBluetoothAddress: String?
    @Published var bluetoothError: String?

    private let bluetoothPower = BluetoothPowerBridge()
    private let locationManager = CLLocationManager()
    private var poller: AnyCancellable?
    private var shouldMonitorBluetoothDevices = false

    var connectedBluetoothCount: Int {
        bluetoothDevices.filter(\.isConnected).count
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationAuthorization = locationManager.authorizationStatus
    }

    func start() {
        refreshStatus()
        poller = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func refreshStatus() {
        let interface = CWWiFiClient.shared().interface()
        wifiEnabled = interface?.powerOn() ?? false
        if !wifiEnabled {
            currentSSID = nil
        } else if let ssid = interface?.ssid() {
            currentSSID = ssid
        }
        if shouldMonitorBluetoothDevices {
            bluetoothEnabled = bluetoothPower.isEnabled
            bluetoothStatusKnown = true
            bluetoothDevices = Self.readBluetoothDevices()
        }
    }

    func loadBluetoothDevices() {
        shouldMonitorBluetoothDevices = true
        refreshStatus()
    }

    func setWiFiEnabled(_ enabled: Bool) {
        wifiError = nil
        guard let interface = CWWiFiClient.shared().interface() else {
            wifiError = "Wi‑Fi arabirimi bulunamadı."
            return
        }
        do {
            try interface.setPower(enabled)
            wifiEnabled = enabled
            if enabled {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(650))
                    self?.prepareWiFiAccess()
                }
            } else {
                currentSSID = nil
                wifiNetworks = []
            }
        } catch {
            wifiError = error.localizedDescription
            refreshStatus()
        }
    }

    func prepareWiFiAccess() {
        locationAuthorization = locationManager.authorizationStatus
        switch locationAuthorization {
        case .authorized, .authorizedAlways:
            scanWiFi()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            wifiError = "Wi‑Fi ağlarını göstermek için Sistem Ayarları’ndan konum izni verin."
        @unknown default:
            wifiError = "Wi‑Fi konum izni durumu okunamadı."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorization = manager.authorizationStatus
        if locationAuthorization == .authorized || locationAuthorization == .authorizedAlways {
            wifiError = nil
            scanWiFi()
        }
    }

    func scanWiFi() {
        guard wifiEnabled, !isScanningWiFi else { return }
        guard locationAuthorization == .authorized || locationAuthorization == .authorizedAlways else {
            prepareWiFiAccess()
            return
        }
        isScanningWiFi = true
        wifiError = nil
        let fallbackCurrentSSID = currentSSID

        Task { [weak self] in
            let result = await Task.detached { () -> Result<([WiFiNetworkItem], String?), Error> in
                do {
                    guard let interface = CWWiFiClient.shared().interface() else {
                        throw ConnectivityError.noWiFiInterface
                    }
                    let current = interface.ssid() ?? fallbackCurrentSSID
                    let profiles = (interface.configuration()?.networkProfiles.array as? [CWNetworkProfile]) ?? []
                    let knownSSIDs = Set(profiles.compactMap(\.ssid))
                    let scanned = try interface.scanForNetworks(withSSID: nil)
                    var strongest: [String: WiFiNetworkItem] = [:]

                    for network in scanned {
                        guard let ssid = network.ssid?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !ssid.isEmpty
                        else { continue }
                        let item = WiFiNetworkItem(
                            ssid: ssid,
                            rssi: network.rssiValue,
                            isSecure: !network.supportsSecurity(.none),
                            isKnown: knownSSIDs.contains(ssid),
                            isCurrent: ssid == current
                        )
                        if strongest[ssid] == nil || item.rssi > strongest[ssid]!.rssi {
                            strongest[ssid] = item
                        }
                    }
                    return .success((strongest.values.sorted { $0.rssi > $1.rssi }, current))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.isScanningWiFi = false
            switch result {
            case let .success((networks, current)):
                self.wifiNetworks = networks
                self.currentSSID = current
            case let .failure(error):
                self.wifiError = error.localizedDescription
            }
        }
    }

    func connectWiFi(_ item: WiFiNetworkItem, password: String?) {
        guard connectingWiFiSSID == nil else { return }
        connectingWiFiSSID = item.ssid
        passwordRequiredSSID = nil
        wifiError = nil

        Task { [weak self] in
            let result = await Task.detached { () -> Result<Void, Error> in
                do {
                    guard let interface = CWWiFiClient.shared().interface() else {
                        throw ConnectivityError.noWiFiInterface
                    }
                    let networks = try interface.scanForNetworks(withSSID: Data(item.ssid.utf8))
                    guard let network = networks.max(by: { $0.rssiValue < $1.rssiValue }) else {
                        throw ConnectivityError.networkNotFound
                    }
                    try interface.associate(to: network, password: password?.isEmpty == false ? password : nil)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.connectingWiFiSSID = nil
            switch result {
            case .success:
                self.currentSSID = item.ssid
                self.passwordRequiredSSID = nil
                self.wifiNetworks = self.wifiNetworks.map {
                    WiFiNetworkItem(
                        ssid: $0.ssid,
                        rssi: $0.rssi,
                        isSecure: $0.isSecure,
                        isKnown: $0.isKnown,
                        isCurrent: $0.ssid == item.ssid
                    )
                }
                self.refreshStatus()
                self.scanWiFi()
            case let .failure(error):
                if item.isSecure && password?.isEmpty != false {
                    self.passwordRequiredSSID = item.ssid
                    self.wifiError = "Bu ağ için Wi‑Fi parolası gerekiyor."
                } else {
                    self.wifiError = error.localizedDescription
                }
            }
        }
    }

    func setBluetoothEnabled(_ enabled: Bool) {
        bluetoothError = nil
        shouldMonitorBluetoothDevices = true
        bluetoothStatusKnown = true
        guard bluetoothPower.setEnabled(enabled) else {
            bluetoothError = "Bluetooth durumu değiştirilemedi."
            return
        }
        bluetoothEnabled = enabled
        if !enabled, shouldMonitorBluetoothDevices {
            bluetoothDevices = Self.readBluetoothDevices()
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.refreshStatus()
        }
    }

    func toggleBluetoothDevice(_ item: BluetoothDeviceItem) {
        guard connectingBluetoothAddress == nil else { return }
        connectingBluetoothAddress = item.address
        bluetoothError = nil

        Task { [weak self] in
            let result = await Task.detached { () -> Int32 in
                guard let device = IOBluetoothDevice(addressString: item.address) else { return -1 }
                return item.isConnected ? device.closeConnection() : device.openConnection()
            }.value

            guard let self else { return }
            self.connectingBluetoothAddress = nil
            if result != 0 {
                self.bluetoothError = "\(item.name) bağlantısı değiştirilemedi (\(result))."
            }
            try? await Task.sleep(for: .milliseconds(450))
            self.refreshStatus()
        }
    }

    private static func readBluetoothDevices() -> [BluetoothDeviceItem] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { device in
            guard let address = device.addressString else { return nil }
            return BluetoothDeviceItem(
                address: address,
                name: device.name ?? "Bluetooth aygıtı",
                isConnected: device.isConnected()
            )
        }
        .sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

private enum ConnectivityError: LocalizedError {
    case noWiFiInterface
    case networkNotFound

    var errorDescription: String? {
        switch self {
        case .noWiFiInterface: "Wi‑Fi arabirimi bulunamadı."
        case .networkNotFound: "Seçilen Wi‑Fi ağı artık bulunamıyor."
        }
    }
}

private final class BluetoothPowerBridge {
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var getPower: GetPower?
    private var setPower: SetPower?

    init() {
        let path = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
        frameworkHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        guard let frameworkHandle else { return }
        if let symbol = dlsym(frameworkHandle, "IOBluetoothPreferenceGetControllerPowerState") {
            getPower = unsafeBitCast(symbol, to: GetPower.self)
        }
        if let symbol = dlsym(frameworkHandle, "IOBluetoothPreferenceSetControllerPowerState") {
            setPower = unsafeBitCast(symbol, to: SetPower.self)
        }
    }

    deinit {
        if let frameworkHandle { dlclose(frameworkHandle) }
    }

    var isEnabled: Bool { getPower?() == 1 }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard let setPower else { return false }
        setPower(enabled ? 1 : 0)
        return true
    }
}
