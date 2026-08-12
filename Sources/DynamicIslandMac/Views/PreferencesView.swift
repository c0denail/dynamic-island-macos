import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var island: IslandController
    @EnvironmentObject private var theme: IslandTheme
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("hoverToExpand") private var hoverToExpand = true
    @AppStorage("showVolumeHUD") private var showVolumeHUD = true
    @AppStorage("showBrightnessHUD") private var showBrightnessHUD = true
    @AppStorage("showNotificationHUD") private var showNotificationHUD = true
    @AppStorage("islandPetEnabled") private var isPetEnabled = true
    @AppStorage("islandPetKind") private var selectedPet = IslandPetKind.byte.rawValue
    @AppStorage("islandPetSpeed") private var petSpeed = 1.0
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

            Section("Kişiselleştirme") {
                HStack {
                    Label("HUD ve ilerleme rengi", systemImage: "slider.horizontal.below.square.filled.and.square")
                    Spacer()
                    ColorPicker("HUD ve ilerleme rengi", selection: hudColor, supportsOpacity: false)
                        .labelsHidden()
                }

                HStack {
                    Label("Uygulama yazı rengi", systemImage: "textformat")
                    Spacer()
                    ColorPicker("Uygulama yazı rengi", selection: textColor, supportsOpacity: false)
                        .labelsHidden()
                }

                HStack(spacing: 10) {
                    Capsule()
                        .fill(theme.hudColor)
                        .frame(width: 74, height: 7)
                    Text("Dynamic Island önizleme")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textColor)
                    Spacer()
                    Button("Varsayılana Dön") { theme.reset() }
                        .disabled(theme.hud == .white && theme.text == .white)
                }

                Text("HUD rengi; ses, parlaklık, medya ve sayaç ilerleme göstergelerinde kullanılır. Seçimler bu Mac’te saklanır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Ada maskotunu göster", isOn: $isPetEnabled)

                if isPetEnabled {
                    Picker("Maskot", selection: $selectedPet) {
                        ForEach(IslandPetKind.allCases) { pet in
                            HStack {
                                IslandPetAvatar(kind: pet, behavior: .idle)
                                    .frame(width: 26, height: 26)
                                Text(pet.title)
                            }
                            .tag(pet.rawValue)
                        }
                    }

                    HStack(spacing: 12) {
                        IslandPetAvatar(
                            kind: IslandPetKind.resolved(selectedPet),
                            behavior: .idle
                        )
                        .frame(width: 32, height: 32)
                        .padding(5)
                        .background(.black, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(IslandPetKind.resolved(selectedPet).title)
                                .font(.system(size: 11, weight: .bold))
                            Text(IslandPetKind.resolved(selectedPet).subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Slider(value: $petSpeed, in: 0.55...1.8)
                            .frame(width: 120)
                        Text("Hız")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Maskot yürür, yuvarlanır, zıplar ve bazen ipe tutunup sallanır; yalnızca adanın sol, alt ve sağ kenarlarında dolaşır.")
                    .font(.caption)
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
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.7")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 680)
        .onAppear {
            let resolvedPet = IslandPetKind.resolved(selectedPet).rawValue
            if selectedPet != resolvedPet {
                selectedPet = resolvedPet
            }
        }
    }

    private var hudColor: Binding<Color> {
        Binding(
            get: { theme.hudColor },
            set: { newColor in theme.setHUDColor(newColor) }
        )
    }

    private var textColor: Binding<Color> {
        Binding(
            get: { theme.textColor },
            set: { newColor in theme.setTextColor(newColor) }
        )
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
