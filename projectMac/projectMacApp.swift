import SwiftUI

@main
struct projectMacApp: App {
    @State private var coordinator = AppCoordinator()

    init() {
        UserDefaults.standard.register(defaults: AppSettingsKeys.defaults)
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .topLeading) {
                ProjectMViewRepresentable(coordinator: coordinator)
                    .ignoresSafeArea()
                if coordinator.renderStats.isLoadingFirstPreset {
                    LoadingOverlayView()
                }
                if coordinator.renderStats.isDebugOverlayVisible {
                    DebugOverlayView(stats: coordinator.renderStats)
                }
            }
            .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1920, height: 1080)
        .commands {
            CommandMenu("Presets") {
                Button("Next Preset") { coordinator.nextPreset() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Preset") { coordinator.prevPreset() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Random Preset") { coordinator.randomPreset() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("Audio") {
                if coordinator.audioAppMonitor.audioApps.isEmpty {
                    Text("No apps playing audio")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.audioAppMonitor.audioApps) { app in
                        Button {
                            coordinator.selectApp(app)
                        } label: {
                            if coordinator.currentTappedPID == app.pid {
                                Label(app.name, systemImage: "checkmark")
                            } else {
                                Text(app.name)
                            }
                        }
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(coordinator)
        }
    }
}
