import AppKit
import SwiftUI

struct SystemSection: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var system: SystemStatusService
    @EnvironmentObject private var connectivity: ConnectivityService
    @State private var showWiFi = false
    @State private var showBluetooth = false

    var body: some View {
        HStack(spacing: 12) {
            BatteryPowerTile()
                .environmentObject(system)

            VStack(spacing: 12) {
                Button {
                    showWiFi.toggle()
                    if showWiFi { connectivity.prepareWiFiAccess() }
                } label: {
                    ConnectivityTile(
                        icon: connectivity.wifiEnabled ? "wifi" : "wifi.slash",
                        title: "Wi‑Fi",
                        value: connectivity.wifiEnabled ? (connectivity.currentSSID ?? system.networkLabel) : "Kapalı",
                        detail: connectivity.wifiEnabled ? "Ağları göster" : "Açmak için tıklayın",
                        isEnabled: connectivity.wifiEnabled
                    )
                }
                .buttonStyle(ScaleButtonStyle())
                .popover(isPresented: $showWiFi, arrowEdge: .top) {
                    WiFiConnectionsPanel()
                        .environmentObject(connectivity)
                }

                Button {
                    showBluetooth.toggle()
                    if showBluetooth { connectivity.loadBluetoothDevices() }
                } label: {
                    ConnectivityTile(
                        icon: "dot.radiowaves.left.and.right",
                        title: "Bluetooth",
                        value: connectivity.bluetoothStatusKnown ? (connectivity.bluetoothEnabled ? "Açık" : "Kapalı") : "Aygıtlar",
                        detail: !connectivity.bluetoothStatusKnown
                            ? "Bağlantıları göster"
                            : connectivity.bluetoothEnabled
                            ? "\(connectivity.connectedBluetoothCount) aygıt bağlı"
                            : "Açmak için tıklayın",
                        isEnabled: connectivity.bluetoothStatusKnown && connectivity.bluetoothEnabled
                    )
                }
                .buttonStyle(ScaleButtonStyle())
                .popover(isPresented: $showBluetooth, arrowEdge: .top) {
                    BluetoothConnectionsPanel()
                        .environmentObject(connectivity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                SystemSliderControl(
                    icon: system.displayBrightness < 0.34 ? "sun.min.fill" : "sun.max.fill",
                    title: "Ekran parlaklığı",
                    value: Double(system.displayBrightness),
                    onChange: { system.setDisplayBrightness(Float($0)) }
                )

                Divider().overlay(.white.opacity(0.08))

                SystemSliderControl(
                    icon: system.outputVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: "Çıkış sesi",
                    value: Double(system.outputVolume),
                    onChange: { system.setVolume(Float($0)) }
                )

                Button(action: island.copySystemSummary) {
                    Label("Sistem özetini kopyala", systemImage: "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .onAppear(perform: openRequestedPanel)
        .onChange(of: island.requestedSystemPanel) { _, _ in
            openRequestedPanel()
        }
    }

    private func openRequestedPanel() {
        guard let request = island.requestedSystemPanel else { return }
        island.consumeSystemPanelRequest()

        Task { @MainActor in
            await Task.yield()
            switch request {
            case .wifi:
                showBluetooth = false
                showWiFi = true
                connectivity.prepareWiFiAccess()
            case .bluetooth:
                showWiFi = false
                showBluetooth = true
                connectivity.loadBluetoothDevices()
            }
        }
    }
}

private struct WiFiConnectionsPanel: View {
    @EnvironmentObject private var connectivity: ConnectivityService
    @State private var securedNetwork: WiFiNetworkItem?
    @State private var password = ""

    var body: some View {
        VStack(spacing: 12) {
            panelHeader(
                icon: "wifi",
                title: "Wi‑Fi",
                isOn: Binding(
                    get: { connectivity.wifiEnabled },
                    set: { connectivity.setWiFiEnabled($0) }
                )
            )

            if let securedNetwork {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lock.fill")
                        Text(securedNetwork.ssid)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            self.securedNetwork = nil
                            password = ""
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    SecureField("Wi‑Fi parolası", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connectSelectedWiFi)
                    Button("Bağlan", action: connectSelectedWiFi)
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                        .disabled(password.isEmpty || connectivity.connectingWiFiSSID != nil)
                }
                .padding(11)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !connectivity.wifiEnabled {
                emptyState(icon: "wifi.slash", text: "Yakındaki ağları görmek için Wi‑Fi’yi açın.")
            } else if connectivity.locationAuthorization == .denied || connectivity.locationAuthorization == .restricted {
                VStack(spacing: 11) {
                    emptyState(icon: "location.slash.fill", text: "Yakındaki Wi‑Fi ağlarını göstermek için konum izni gerekiyor.")
                    Button("Konum Ayarlarını Aç") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                }
            } else if connectivity.isScanningWiFi && connectivity.wifiNetworks.isEmpty {
                ProgressView("Yakındaki ağlar aranıyor…")
                    .controlSize(.small)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(connectivity.wifiNetworks) { network in
                            Button {
                                select(network)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: wifiIcon(for: network.rssi))
                                        .frame(width: 18)
                                    Text(network.ssid)
                                        .font(.system(size: 11, weight: network.isCurrent ? .bold : .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    if connectivity.connectingWiFiSSID == network.ssid {
                                        ProgressView().controlSize(.mini)
                                    } else if network.isCurrent {
                                        Image(systemName: "checkmark")
                                            .fontWeight(.bold)
                                    } else if network.isSecure {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    network.isCurrent ? .white.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(network.isCurrent || connectivity.connectingWiFiSSID != nil)
                        }
                    }
                }
            }

            if let error = connectivity.wifiError {
                Text(error)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            panelFooter(
                refresh: connectivity.prepareWiFiAccess,
                settingsURL: "x-apple.systempreferences:com.apple.Wi-Fi-Settings.extension"
            )
        }
        .padding(14)
        .frame(width: 340, height: 390)
        .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        .onAppear {
            connectivity.refreshStatus()
            connectivity.prepareWiFiAccess()
        }
        .onChange(of: connectivity.passwordRequiredSSID) { _, ssid in
            guard let ssid,
                  let network = connectivity.wifiNetworks.first(where: { $0.ssid == ssid })
            else { return }
            securedNetwork = network
            password = ""
        }
        .onChange(of: connectivity.currentSSID) { _, ssid in
            guard ssid == securedNetwork?.ssid else { return }
            securedNetwork = nil
            password = ""
        }
    }

    private func select(_ network: WiFiNetworkItem) {
        if network.isSecure && !network.isKnown {
            securedNetwork = network
            password = ""
        } else {
            connectivity.connectWiFi(network, password: nil)
        }
    }

    private func connectSelectedWiFi() {
        guard let securedNetwork, !password.isEmpty else { return }
        connectivity.connectWiFi(securedNetwork, password: password)
    }

    private func wifiIcon(for rssi: Int) -> String {
        if rssi > -58 { return "wifi" }
        if rssi > -72 { return "wifi" }
        return "wifi.exclamationmark"
    }
}

private struct BluetoothConnectionsPanel: View {
    @EnvironmentObject private var connectivity: ConnectivityService

    var body: some View {
        VStack(spacing: 12) {
            panelHeader(
                icon: "dot.radiowaves.left.and.right",
                title: "Bluetooth",
                isOn: Binding(
                    get: { connectivity.bluetoothEnabled },
                    set: { connectivity.setBluetoothEnabled($0) }
                )
            )

            if !connectivity.bluetoothEnabled {
                emptyState(icon: "dot.radiowaves.left.and.right", text: "Aygıtları görmek için Bluetooth’u açın.")
            } else if connectivity.bluetoothDevices.isEmpty {
                emptyState(icon: "headphones", text: "Eşleşmiş Bluetooth aygıtı bulunamadı.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(connectivity.bluetoothDevices) { device in
                            Button {
                                connectivity.toggleBluetoothDevice(device)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: bluetoothIcon(for: device.name))
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 19)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.system(size: 11, weight: device.isConnected ? .bold : .medium))
                                            .lineLimit(1)
                                        Text(device.isConnected ? "Bağlı" : "Bağlı değil")
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if connectivity.connectingBluetoothAddress == device.address {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Circle()
                                            .fill(device.isConnected ? .white : .white.opacity(0.18))
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    device.isConnected ? .white.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(connectivity.connectingBluetoothAddress != nil)
                        }
                    }
                }
            }

            if let error = connectivity.bluetoothError {
                Text(error)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            panelFooter(
                refresh: connectivity.refreshStatus,
                settingsURL: "x-apple.systempreferences:com.apple.BluetoothSettings"
            )
        }
        .padding(14)
        .frame(width: 340, height: 390)
        .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        .onAppear(perform: connectivity.loadBluetoothDevices)
    }

    private func bluetoothIcon(for name: String) -> String {
        let lowercased = name.lowercased()
        if lowercased.contains("airpod") || lowercased.contains("buds") || lowercased.contains("head") {
            return "airpodspro"
        }
        if lowercased.contains("mouse") || lowercased.contains("m240") { return "computermouse.fill" }
        if lowercased.contains("watch") { return "applewatch" }
        if lowercased.contains("iphone") { return "iphone" }
        return "hifispeaker.fill"
    }
}

private struct ConnectivityTile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isEnabled ? .black : .white.opacity(0.55))
                .frame(width: 34, height: 34)
                .background(isEnabled ? .white : .white.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.38))
                Text(value)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 3)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(IslandPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SystemSliderControl: View {
    let icon: String
    let title: String
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
                .tint(.white)
                .controlSize(.mini)
        }
    }
}

private struct SystemTile: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: Circle())
            Spacer()
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct BatteryPowerTile: View {
    @EnvironmentObject private var system: SystemStatusService

    private var color: Color {
        system.isCharging ? IslandPalette.primary : IslandPalette.orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: system.isCharging ? "bolt.fill" : "battery.75percent")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 42, height: 42)
                    .background(color.opacity(0.12), in: Circle())
                Spacer()
                if system.isChangingLowPowerMode {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                }
            }

            Spacer(minLength: 0)

            Text("PİL")
                .font(.system(size: 8, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.38))
            Text("\(system.batteryPercent)%")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(system.isCharging ? "Güç adaptörüne bağlı" : "Pille çalışıyor")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)

            Button {
                system.setLowPowerModeEnabled(!system.lowPowerModeEnabled)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: system.lowPowerModeEnabled ? "leaf.fill" : "leaf")
                    Text("Düşük Güç")
                    Spacer(minLength: 2)
                    Text(system.lowPowerModeEnabled ? "Açık" : "Kapalı")
                        .foregroundStyle(system.lowPowerModeEnabled ? .black.opacity(0.58) : .white.opacity(0.42))
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(system.lowPowerModeEnabled ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(system.lowPowerModeEnabled ? .white : .white.opacity(0.09), in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(system.isChangingLowPowerMode)
            .help("İlk kullanımda bir kez yönetici onayıyla Düşük Güç Modu’nu aç veya kapat")

            if let error = system.lowPowerModeError {
                Text(error)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private func panelHeader(icon: String, title: String, isOn: Binding<Bool>) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .bold))
            .frame(width: 31, height: 31)
            .background(.white, in: Circle())
            .foregroundStyle(.black)
        Text(title)
            .font(.system(size: 14, weight: .bold))
        Spacer()
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.white)
    }
}

private func emptyState(icon: String, text: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private func panelFooter(refresh: @escaping () -> Void, settingsURL: String) -> some View {
    HStack {
        Button(action: refresh) {
            Label("Yenile", systemImage: "arrow.clockwise")
        }
        Spacer()
        Button("Ayarlar…") {
            guard let url = URL(string: settingsURL) else { return }
            NSWorkspace.shared.open(url)
        }
    }
    .font(.system(size: 9, weight: .semibold))
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
}
