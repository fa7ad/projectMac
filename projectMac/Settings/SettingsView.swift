import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    @AppStorage(AppSettingsKeys.beatSensitivity) private var beatSensitivity: Double = 1.0
    @AppStorage(AppSettingsKeys.presetDuration) private var presetDuration: Double = 15.0
    @AppStorage(AppSettingsKeys.meshSizeX) private var meshSizeX: Int = 96
    @AppStorage(AppSettingsKeys.meshSizeY) private var meshSizeY: Int = 72
    @AppStorage(AppSettingsKeys.shufflePresets) private var shufflePresets: Bool = false
    @AppStorage(AppSettingsKeys.broadcastSceneStream) private var broadcastSceneStream: Bool = false

    @AppStorage(AppSettingsKeys.fullscreenOnLaunch) private var fullscreenOnLaunch: Bool = false
    @AppStorage(AppSettingsKeys.hideIdleCursor) private var hideIdleCursor: Bool = true
    @AppStorage(AppSettingsKeys.hideCursorDelay) private var hideCursorDelay: Double = 2.5
    @AppStorage(AppSettingsKeys.spanLayout) private var spanLayout: String = "displays"
    @AppStorage(AppSettingsKeys.spanPhysicalSize) private var spanPhysicalSize: Bool = true
    @State private var screens = NSScreen.screens
    @AppStorage(AppSettingsKeys.renderScale) private var renderScale: Double = 1.0
    @AppStorage(AppSettingsKeys.hdrEnabled) private var hdrEnabled: Bool = false
    @AppStorage(AppSettingsKeys.borderlessMode) private var borderlessMode: String = "off"
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
        TabView {
            Tab("General", systemImage: "slider.horizontal.3") { tab(generalTab) }
            Tab("Displays", systemImage: "display.2") { tab(displaysTab) }
            Tab("Audio & Presets", systemImage: "waveform") { tab(audioTab) }
            Tab("Scene Stream", systemImage: "antenna.radiowaves.left.and.right") { tab(streamTab) }
        }
        .frame(width: 480)
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

    /// A grouped form that sizes the window to its content (a grouped Form's own ideal
    /// height is tiny, so without `fixedSize` the tab would be clipped).
    private func tab<Content: View>(_ content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var generalTab: some View {
        Form {
            Section("Rendering") {
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
            }
            Section("HDR") {
                Toggle("HDR output", isOn: $hdrEnabled)
                hint("Takes effect after restarting the app.")
                slider("HDR boost", value: $hdrGain, in: 1.0...4.0, format: "%.1f×")
                    .disabled(!hdrEnabled)
            }
            Section("Fullscreen") {
                Toggle("Fullscreen on launch", isOn: $fullscreenOnLaunch)
                Picker("Borderless fullscreen", selection: $borderlessMode) {
                    Text("Off").tag("off")
                    Text("Mirrors and span windows").tag("others")
                    Text("All windows").tag("all")
                }
                hint("Borderless windows fill the whole screen, notch included, instead of using a macOS fullscreen Space, which leaves a black band under the notch. \"All windows\" includes the main window.")
                Toggle("Hide idle cursor", isOn: $hideIdleCursor)
                slider("Hide cursor after", value: $hideCursorDelay, in: 1...10, format: "%.1fs")
                    .disabled(!hideIdleCursor)
            }
        }
    }

    private var displaysTab: some View {
        Form {
            Section("Span across displays") {
                Toggle("Span across displays", isOn: Binding(
                    get: { coordinator.isSpanning },
                    set: { coordinator.mirrorController.setSpan($0) }
                ))
                .disabled(screens.count < 2)
                hint(screens.count < 2
                     ? "Needs a second display."
                     : "Same as Display > Span Across Displays. Open a mirror window on each other display and fullscreen it first; displays without one get a window of their own.")
                Picker("Layout", selection: $spanLayout) {
                    Text("Match displays").tag("displays")
                    Text("Match arrangement").tag("arrangement")
                }
                hint("How Display > Span Across Displays slices the picture. Displays: side by side at equal height, no gaps. Arrangement: as laid out in System Settings, vertical offsets included.")
                if screens.count > 1 {
                    Toggle("Match real display sizes", isOn: $spanPhysicalSize)
                    hint("Starts from each display's real size (as it reports it) so shapes come out the same size on all of them. Turn off if a display reports a wrong size.")
                }
            }
            if screens.count > 1 {
                Section("Tuning") {
                    hint("Trim each display with Display > Span Test Pattern: lines should continue across the gap. Lower picture size makes the picture smaller on that display.")
                    ForEach(screens, id: \.spanKey) { screen in
                        SpanTuningRow(name: screen.localizedName, key: screen.spanKey)
                    }
                }
            }
        }
    }

    private var audioTab: some View {
        Form {
            Section("Audio") {
                slider("Beat sensitivity", value: $beatSensitivity, in: 0.1...2.0, format: "%.1f")
            }
            Section("Presets") {
                Stepper("Preset duration: \(Int(presetDuration))s",
                        value: $presetDuration, in: 5...300, step: 5)
                Toggle("Shuffle presets", isOn: $shufflePresets)
            }
        }
    }

    private var streamTab: some View {
        Form {
            Section("OSC") {
                Toggle("Broadcast", isOn: $broadcastSceneStream)
                if broadcastSceneStream { oscStatus }
                TextField("Receiver", text: $oscDestination, prompt: Text("ip:port"))
                    .autocorrectionDisabled()
                hint("IPv4 address and UDP port of the OSC receiver: 127.0.0.1:9000 for this Mac, or a device on your network.")
            }
        }
    }

    /// Same source the debug overlay reads; `sceneStream` stays nil until the first frame is sent.
    private var oscStatus: some View {
        let stats = coordinator.renderStats
        let (text, color): (String, Color) =
            if let error = stats.sceneStreamError { (error, .red) }
            else if stats.sceneStream == nil { ("Waiting for frames", .secondary) }
            else { ("Sending", .green) }
        return Label(text, systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(color)
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
