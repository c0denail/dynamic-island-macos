import AppKit
import ApplicationServices
import Combine
@preconcurrency import CoreBluetooth
@preconcurrency import CoreLocation
import CoreServices
import SwiftUI
import UserNotifications

private enum PermissionProgress: Equatable {
    case waiting
    case requesting
    case granted
    case denied
    case actionRequired

    var label: String {
        switch self {
        case .waiting: "Bekliyor"
        case .requesting: "İzin bekleniyor"
        case .granted: "İzin verildi"
        case .denied: "İzin verilmedi"
        case .actionRequired: "Ayar gerekli"
        }
    }

    var icon: String {
        switch self {
        case .waiting: "circle"
        case .requesting: "ellipsis.circle"
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .actionRequired: "gearshape.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .secondary
        case .requesting: .white
        case .granted: .green
        case .denied: .red
        case .actionRequired: .orange
        }
    }
}

@MainActor
private final class PermissionOnboardingManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate, @preconcurrency CBCentralManagerDelegate {
    @Published var notificationPermission: PermissionProgress = .waiting
    @Published var locationPermission: PermissionProgress = .waiting
    @Published var bluetoothPermission: PermissionProgress = .waiting
    @Published var automationPermission: PermissionProgress = .waiting
    @Published var accessibilityPermission: PermissionProgress = .waiting
    @Published var isRunning = false
    @Published var isComplete = false

    private let notificationMirror: NotificationMirrorService
    private let locationManager = CLLocationManager()
    private var bluetoothManager: CBCentralManager?
    private var locationContinuation: CheckedContinuation<Void, Never>?
    private var bluetoothContinuation: CheckedContinuation<Void, Never>?
    private var bluetoothTimeoutTask: Task<Void, Never>?
    private var accessibilityPoller: AnyCancellable?

    init(notificationMirror: NotificationMirrorService) {
        self.notificationMirror = notificationMirror
        super.init()
        locationManager.delegate = self
        refreshAccessibilityStatus()
        accessibilityPoller = Timer.publish(every: 0.6, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshAccessibilityStatus() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isComplete = false

        Task { [weak self] in
            guard let self else { return }
            await self.requestNotifications()
            await self.requestLocation()
            await self.requestBluetooth()
            await self.requestAutomation()
            await self.requestAccessibility()
            self.isRunning = false
            self.isComplete = true
        }
    }

    func openAccessibilitySettings() {
        notificationMirror.openAccessibilitySettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationPermission = .granted
            return
        case .denied:
            notificationPermission = .denied
            return
        case .notDetermined:
            notificationPermission = .requesting
        @unknown default:
            notificationPermission = .actionRequired
            return
        }

        do {
            notificationPermission = try await center.requestAuthorization(options: [.alert, .sound, .badge]) ? .granted : .denied
        } catch {
            notificationPermission = .denied
        }
    }

    private func requestLocation() async {
        updateLocationStatus(locationManager.authorizationStatus)
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationPermission = .requesting
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestAlwaysAuthorization()
        }
    }

    private func requestBluetooth() async {
        updateBluetoothStatus(CBManager.authorization)
        guard CBManager.authorization == .notDetermined else { return }
        bluetoothPermission = .requesting
        await withCheckedContinuation { continuation in
            bluetoothContinuation = continuation
            bluetoothManager = CBCentralManager(delegate: self, queue: .main)
            bluetoothTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.bluetoothContinuation != nil else { return }
                self.updateBluetoothStatus(CBManager.authorization)
                if CBManager.authorization == .notDetermined { self.bluetoothPermission = .actionRequired }
                self.finishBluetoothRequest()
            }
        }
    }

    private func requestAutomation() async {
        automationPermission = .requesting
        let status = await Task.detached(priority: .userInitiated) {
            Self.requestAutomationPermission(for: "com.apple.systemevents")
        }.value
        automationPermission = status == noErr ? .granted : (status == errAEEventNotPermitted ? .denied : .actionRequired)
    }

    private func requestAccessibility() async {
        if AXIsProcessTrusted() {
            accessibilityPermission = .granted
            return
        }
        accessibilityPermission = .requesting
        notificationMirror.requestAccessibilityAccess()
        try? await Task.sleep(for: .seconds(1.2))
        accessibilityPermission = AXIsProcessTrusted() ? .granted : .actionRequired
    }

    nonisolated private static func requestAutomationPermission(for bundleIdentifier: String) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let target = descriptor.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, true)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateLocationStatus(manager.authorizationStatus)
        guard manager.authorizationStatus != .notDetermined else { return }
        locationContinuation?.resume()
        locationContinuation = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateBluetoothStatus(CBManager.authorization)
        guard CBManager.authorization != .notDetermined else { return }
        finishBluetoothRequest()
    }

    private func updateLocationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            locationPermission = .granted
        case .denied, .restricted:
            locationPermission = .denied
        case .notDetermined:
            if locationPermission != .requesting { locationPermission = .waiting }
        @unknown default:
            locationPermission = .actionRequired
        }
    }

    private func updateBluetoothStatus(_ status: CBManagerAuthorization) {
        switch status {
        case .allowedAlways:
            bluetoothPermission = .granted
        case .denied, .restricted:
            bluetoothPermission = .denied
        case .notDetermined:
            if bluetoothPermission != .requesting { bluetoothPermission = .waiting }
        @unknown default:
            bluetoothPermission = .actionRequired
        }
    }

    private func finishBluetoothRequest() {
        bluetoothTimeoutTask?.cancel()
        bluetoothTimeoutTask = nil
        bluetoothContinuation?.resume()
        bluetoothContinuation = nil
    }

    private func refreshAccessibilityStatus() {
        if AXIsProcessTrusted() {
            accessibilityPermission = .granted
        } else if accessibilityPermission == .granted {
            accessibilityPermission = .actionRequired
        }
    }
}

@MainActor
final class PermissionOnboardingCoordinator {
    private let controller: IslandController
    private var window: NSWindow?

    init(controller: IslandController) {
        self.controller = controller
    }

    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "permissionOnboardingCompleted") else { return }

        let manager = PermissionOnboardingManager(notificationMirror: controller.notifications)
        let view = PermissionOnboardingView(manager: manager) { [weak self] in
            UserDefaults.standard.set(true, forKey: "permissionOnboardingCompleted")
            self?.window?.close()
            self?.window = nil
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 570),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dynamic Island Kurulumu"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct PermissionOnboardingView: View {
    @ObservedObject var manager: PermissionOnboardingManager
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                ZStack {
                    Capsule().fill(.white)
                    Image(systemName: "capsule.inset.filled")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black)
                }
                .frame(width: 74, height: 38)

                Text("Dynamic Island’ı Hazırla")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Özelliklerin çalışabilmesi için macOS izinlerini sırayla isteyeceğiz. İzin içerikleri yalnızca bu Mac’te işlenir.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }

            VStack(spacing: 8) {
                permissionRow(icon: "bell.badge.fill", title: "Bildirimler", detail: "Sayaç uyarıları", state: manager.notificationPermission)
                permissionRow(icon: "location.fill", title: "Konum / Wi‑Fi", detail: "Yakındaki Wi‑Fi ağlarının adları", state: manager.locationPermission)
                permissionRow(icon: "dot.radiowaves.left.and.right", title: "Bluetooth", detail: "Eşleşmiş aygıtları gösterme ve bağlanma", state: manager.bluetoothPermission)
                permissionRow(icon: "music.note", title: "Medya otomasyonu", detail: "Music ve Spotify denetimi", state: manager.automationPermission)
                permissionRow(icon: "bell.and.waves.left.and.right.fill", title: "Erişilebilirlik", detail: "Bildirimleri gösterme ve macOS Saat’i denetleme", state: manager.accessibilityPermission)
            }

            if manager.accessibilityPermission == .actionRequired {
                Button {
                    manager.openAccessibilitySettings()
                } label: {
                    Label("Erişilebilirlik Ayarlarını Aç", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 10) {
                if manager.isComplete {
                    Button("İzinleri Tekrar Kontrol Et") { manager.start() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }

                Button {
                    onComplete()
                } label: {
                    Text(manager.isComplete ? "Dynamic Island’ı Kullan" : "İzinler isteniyor…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .controlSize(.large)
                .disabled(!manager.isComplete)
            }
        }
        .padding(30)
        .frame(width: 610, height: 570)
        .background(Color(red: 0.025, green: 0.025, blue: 0.032))
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            manager.start()
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, state: PermissionProgress) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .bold))
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(state.label, systemImage: state.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(state.color)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
