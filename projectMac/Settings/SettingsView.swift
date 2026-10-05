import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    @AppStorage(AppSettingsKeys.beatSensitivity) private var beatSensitivity: Double = 1.0
    @AppStorage(AppSettingsKeys.presetDuration) private var presetDuration: Double = 15.0
    @AppStorage(AppSettingsKeys.meshSizeX) private var meshSizeX: Int = 96
    @AppStorage(AppSettingsKeys.meshSizeY) private var meshSizeY: Int = 72
    @AppStorage(AppSettingsKeys.shufflePresets) private var shufflePresets: Bool = false
    @AppStorage(AppSettingsKeys.broadcastSceneStream) private var broadcastSceneStream: Bool = false

    @AppStorage(AppSettingsKeys.hideIdleCursor) private var hideIdleCursor: Bool = true
    @AppStorage(AppSettingsKeys.hideCursorDelay) private var hideCursorDelay: Double = 2.5
    @AppStorage(AppSettingsKeys.spanLayout) private var spanLayout: String = "displays"
    @AppStorage(AppSettingsKeys.spanPhysicalSize) private var spanPhysicalSize: Bool = true
    @State private var screens = NSScreen.screens
    @State private var formHeight: CGFloat = 600
    @AppStorage(AppSettingsKeys.renderScale) private var renderScale: Double = 1.0
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
            // Scrolls only if the form is taller than the smallest screen allows (e.g. with the
            // span tuning open on a laptop); otherwise the window sizes to the form.
            ScrollView {
                Form {
                    Section("Display") {
                        Picker("Mesh quality", selection: meshQualityBinding) {
                            Text("Low (32×24)").tag(0)
                            Text("Medium (64×48)").tag(1)
                            Text("High (96×72)").tag(2)
                        }
                        Picker("Render scale", selection: $renderScale) {
                            Text("200% (supersampled)").tag(2.0)
                            Text("100%").tag(1.0)
                            Text("75%").tag(0.75)
                            Text("50%").tag(0.5)
                        }
                        hint("Pixels rendered relative to the window. Lower is faster (helps heavy presets and transitions); 200% is sharper but needs a powerful GPU.")
                        Toggle("HDR output", isOn: $hdrEnabled)
                        hint("Takes effect after restarting the app.")
                        slider("HDR boost", value: $hdrGain, in: 1.0...4.0, format: "%.1f×")
                            .disabled(!hdrEnabled)
                        Picker("Span layout", selection: $spanLayout) {
                            Text("Match displays").tag("displays")
                            Text("Match arrangement").tag("arrangement")
                        }
                        hint("How Span Across Displays slices the picture. Displays: side by side at equal height, no gaps. Arrangement: as laid out in System Settings, vertical offsets included.")
                        Toggle("Borderless mirror fullscreen", isOn: $borderlessFullscreen)
                        hint("Mirror windows fill the whole screen, notch included, instead of using a macOS fullscreen Space.")
                        Toggle("Hide idle cursor in fullscreen", isOn: $hideIdleCursor)
                        slider("Hide cursor after", value: $hideCursorDelay, in: 1...10, format: "%.1fs")
                            .disabled(!hideIdleCursor)
                    }
                    if screens.count > 1 {
                        Section {
                            DisclosureGroup("Span tuning") {
                                Toggle("Match real display sizes", isOn: $spanPhysicalSize)
                            hint("Starts from each display's real size (as it reports it) so shapes come out the same size on all of them. Turn off if a display reports a wrong size.")
                            hint("Then trim each display with Display > Span Test Pattern: lines should continue across the gap. Lower picture size makes the picture smaller on that display.")
                                ForEach(screens, id: \.spanKey) { screen in
                                    SpanTuningRow(name: screen.localizedName, key: screen.spanKey)
                                }
                            }
                        }
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
            }
            .frame(height: min(formHeight, Self.maxFormHeight))
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onAppear { applySettings() }
        .onChange(of: beatSensitivity) { applySettings() }
        .onChange(of: presetDuration) { applySettings() }
        .onChange(of: meshSizeX) { applySettings() }
        .onChange(of: shufflePresets) { applySettings() }
        .onChange(of: broadcastSceneStream) { applySettings() }
        .onChange(of: oscDestination) { applySettings() }
        .onChange(of: hdrGain) { applySettings() }
    }

    /// Room for the title bar, the footer and the Dock/menu bar on the smallest connected screen.
    private static var maxFormHeight: CGFloat {
        (NSScreen.screens.map(\.visibleFrame.height).min() ?? 800) - 140
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

/// Span tuning for one display: picture size and vertical shift, stored per display.
private struct SpanTuningRow: View {
    let name: String
    @AppStorage private var scale: Double
    @AppStorage private var offset: Double

    init(name: String, key: String) {
        self.name = name
        _scale = AppStorage(wrappedValue: 1.0, AppSettingsKeys.spanScaleKey(key))
        _offset = AppStorage(wrappedValue: 0.0, AppSettingsKeys.spanOffsetKey(key))
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(name).fontWeight(.semibold)
                Spacer()
                Button("Reset") { scale = 1; offset = 0 }
                    .disabled(scale == 1 && offset == 0)
            }
            row("Picture size", value: $scale, range: 0.7...1.3, text: String(format: "%.0f%%", scale * 100))
            row("Vertical shift", value: $offset, range: -0.25...0.25, text: String(format: "%+.1f%%", offset * 100))
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 160)
                Text(text).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
    }
}
