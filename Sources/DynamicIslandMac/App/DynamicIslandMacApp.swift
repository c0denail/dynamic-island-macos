import SwiftUI

@main
struct DynamicIslandMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var island = IslandController.shared

    var body: some Scene {
        MenuBarExtra("Dynamic Island", systemImage: "capsule.inset.filled") {
            Button(island.presentation == .expanded ? "Adayı Küçült" : "Adayı Aç") {
                island.toggleExpanded()
            }
            .keyboardShortcut(" ", modifiers: [.option])

            Divider()

            Button("Medya") {
                island.open(.media)
            }

            Button("Sayaç") {
                island.open(.timer)
            }

            Button("Sistem") {
                island.open(.system)
            }

            Divider()

            SettingsLink {
                Text("Ayarlar…")
            }

            Button("Dynamic Island'dan Çık") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
                .environmentObject(island)
                .environmentObject(island.theme)
        }
    }
}
