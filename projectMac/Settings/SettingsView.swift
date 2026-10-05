import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    @AppStorage(AppSettingsKeys.beatSensitivity) private var beatSensitivity: Double = 1.0
    @AppStorage(AppSettingsKeys.presetDuration) private var presetDuration: Double = 15.0
    @AppStorage(AppSettingsKeys.meshSizeX) private var meshSizeX: Int = 96
    @AppStorage(AppSettingsKeys.meshSizeY) private var meshSizeY: Int = 72
    @AppStorage(AppSettingsKeys.shufflePresets) private var shufflePresets: Bool = false
    @AppStorage(AppSettingsKeys.broadcastSceneStream) private var broadcastSceneStream: Bool = false

    @AppStorage(AppSettingsKeys.hdrEnabled) private var hdrEnabled: Bool = false
    @AppStorage(AppSettingsKeys.borderlessFullscreen) private var borderlessFullscreen: Bool = false
    @AppStorage(AppSettingsKeys.hdrGain) private var hdrGain: Double = 2.0

    @AppStorage(AppSettingsKeys.oscDestination) private var oscDestination: String = AppSettingsKeys.defaultOSCDestination

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
        VStack(spacing: 0) {
            Form {
                Section("Display") {
                    Picker("Mesh quality", selection: meshQualityBinding) {
                        Text("Low (32×24)").tag(0)
                        Text("Medium (64×48)").tag(1)
                        Text("High (96×72)").tag(2)
                    }
                    Toggle("HDR output", isOn: $hdrEnabled)
                    hint("Takes effect after restarting the app.")
                    slider("HDR boost", value: $hdrGain, in: 1.0...4.0, format: "%.1f×")
                        .disabled(!hdrEnabled)
                    Toggle("Borderless mirror fullscreen", isOn: $borderlessFullscreen)
                    hint("Mirror windows fill the whole screen, notch included, instead of using a macOS fullscreen Space.")
                }
                Section("Audio & Presets") {
                    slider("Beat sensitivity", value: $beatSensitivity, in: 0.1...2.0, format: "%.1f")
                    Stepper("Preset duration: \(Int(presetDuration))s",
                            value: $presetDuration, in: 5...300, step: 5)
                    Toggle("Shuffle presets", isOn: $shufflePresets)
                }
                Section("Scene Stream (OSC)") {
                    Toggle("Broadcast", isOn: $broadcastSceneStream)
                    TextField("Receiver", text: $oscDestination, prompt: Text("ip:port"))
                        .autocorrectionDisabled()
                    hint("IPv4 address and UDP port of the OSC receiver: 127.0.0.1:9000 for this Mac, or a device on your network.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true) // size the window to the form instead of scrolling
            .fixedSize(horizontal: false, vertical: true) // a grouped Form's ideal height is tiny; use its full content height
            HStack {
                Text("Changes apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // Settings are already persisted by `@AppStorage` as they change; this just closes.
                Button("Done") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 420)
        .onAppear { applySettings() }
        .onChange(of: beatSensitivity) { applySettings() }
        .onChange(of: presetDuration) { applySettings() }
        .onChange(of: meshSizeX) { applySettings() }
        .onChange(of: shufflePresets) { applySettings() }
        .onChange(of: broadcastSceneStream) { applySettings() }
        .onChange(of: oscDestination) { applySettings() }
        .onChange(of: hdrGain) { applySettings() }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    /// Label left, live value right, same layout for every slider.
    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 160)
                Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func applySettings() {
        coordinator.applyPersistedSettings()
    }
}
