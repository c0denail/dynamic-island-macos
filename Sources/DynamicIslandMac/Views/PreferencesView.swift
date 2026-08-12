import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var island: IslandController
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("hoverToExpand") private var hoverToExpand = true
    @AppStorage("showVolumeHUD") private var showVolumeHUD = true
    @AppStorage("showBrightnessHUD") private var showBrightnessHUD = true
    @AppStorage("showNotificationHUD") private var showNotificationHUD = true
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Davranış") {
                Toggle("İşaretçi adanın üzerindeyken genişlet", isOn: $hoverToExpand)
                Toggle("Ses değişikliklerini adada göster", isOn: $showVolumeHUD)
                Toggle("Ekran parlaklığı değişikliklerini adada göster", isOn: $showBrightnessHUD)
                Toggle("Gelen bildirimleri adada göster", isOn: $showNotificationHUD)
                    .onChange(of: showNotificationHUD) { _, enabled in
                        island.notifications.featurePreferenceDidChange(enabled: enabled)
                    }
                Toggle("Oturum açıldığında çalıştır", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                Text("Adayı her yerden açmak için ⌥ Boşluk tuşlarını kullanın.")
                    .foregroundStyle(.secondary)
            }

            Section("Entegrasyonlar") {
                Label("Music ve Spotify oynatma denetimi", systemImage: "music.note")
                Label("macOS Saat sayaç ve kronometre canlı eşitlemesi", systemImage: "stopwatch")
                Label("macOS bildirimleri", systemImage: "bell")
                Label("Pil, ağ, çıkış sesi ve ekran parlaklığı", systemImage: "macbook")
                Label("Wi‑Fi ağları ve Bluetooth aygıt denetimi", systemImage: "wifi")
                Text("İlk medya komutunda macOS, Music veya Spotify erişimi için izin isteyebilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bildirim erişimi") {
                NotificationAccessibilityRow(service: island.notifications)
                Button {
                    island.previewNotification()
                } label: {
                    Label("Bildirimi adada önizle", systemImage: "bell.badge")
                }
                Text("Bildirim başlığı ve içeriğini okuyabilmek için Erişilebilirlik izni gerekir. Veriler yalnızca cihazınızda işlenir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Section {
                HStack {
                    Text("Dynamic Island for macOS")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 440)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Otomatik başlatma değiştirilemedi: \(error.localizedDescription)"
            launchAtLogin = !enabled
        }
    }
}

private struct NotificationAccessibilityRow: View {
    @ObservedObject var service: NotificationMirrorService

    var body: some View {
        HStack {
            Label(
                service.isAccessibilityTrusted ? "Erişilebilirlik izni verildi" : "Erişilebilirlik izni gerekli",
                systemImage: service.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle"
            )
            Spacer()
            if !service.isAccessibilityTrusted {
                Button("İzin İste") { service.requestAccessibilityAccess() }
                Button("Ayarları Aç") { service.openAccessibilitySettings() }
            }
        }
    }
}
