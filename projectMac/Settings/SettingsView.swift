import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    @AppStorage(AppSettingsKeys.beatSensitivity) private var beatSensitivity: Double = 1.0
    @AppStorage(AppSettingsKeys.presetDuration) private var presetDuration: Double = 15.0
    @AppStorage(AppSettingsKeys.meshSizeX) private var meshSizeX: Int = 96
    @AppStorage(AppSettingsKeys.meshSizeY) private var meshSizeY: Int = 72
    @AppStorage(AppSettingsKeys.shufflePresets) private var shufflePresets: Bool = false

    private var meshQualityBinding: Binding<Int> {
        Binding(
            get: {
                switch (meshSizeX, meshSizeY) {
                case (64, 48): return 1
                case (96, 72): return 2
                default: return 0
                }
            },
            set: { newValue in
                switch newValue {
                case 1: (meshSizeX, meshSizeY) = (64, 48)
                case 2: (meshSizeX, meshSizeY) = (96, 72)
                default: (meshSizeX, meshSizeY) = (32, 24)
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Rendering") {
                Picker("Mesh quality", selection: meshQualityBinding) {
                    Text("Low (32×24)").tag(0)
                    Text("Medium (64×48)").tag(1)
                    Text("High (96×72)").tag(2)
                }
            }
            Section("Audio") {
                Slider(value: $beatSensitivity, in: 0.1...2.0) {
                    Text("Beat sensitivity: \(beatSensitivity, specifier: "%.1f")")
                }
            }
            Section("Presets") {
                Stepper("Duration: \(Int(presetDuration))s",
                        value: $presetDuration, in: 5...300, step: 5)
                Toggle("Shuffle", isOn: $shufflePresets)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
        .onAppear { applySettings() }
        .onChange(of: beatSensitivity) { applySettings() }
        .onChange(of: presetDuration) { applySettings() }
        .onChange(of: meshSizeX) { applySettings() }
        .onChange(of: shufflePresets) { applySettings() }
    }

    private func applySettings() {
        coordinator.applyPersistedSettings()
    }
}
