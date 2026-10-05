import Foundation

/// Shared between `@AppStorage` in `SettingsView` and
/// `AppCoordinator.applyPersistedSettings()`, so the two can't drift.
enum AppSettingsKeys {
    static let beatSensitivity = "beatSensitivity"
    static let presetDuration = "presetDuration"
    static let meshSizeX = "meshSizeX"
    static let meshSizeY = "meshSizeY"
    static let shufflePresets = "shufflePresets"
    static let broadcastSceneStream = "broadcastSceneStream"
    static let oscDestination = "oscDestination"
    static let hdrEnabled = "hdrEnabled" // read once at launch (pixel format)
    static let hdrGain = "hdrGain"
    static let borderlessFullscreen = "borderlessFullscreen" // read at toggle time
    static let hideIdleCursor = "hideIdleCursor" // read at each mouse event
    static let hideCursorDelay = "hideCursorDelay" // seconds
    static let spanLayout = "spanLayout" // "displays" | "arrangement"
    static let renderScale = "renderScale" // scene pixels per window pixel (0.5...2)
    /// Per-display span tuning, keyed by `NSScreen.spanKey`: how big that display's picture is
    /// (1 = as laid out) and its vertical shift as a fraction of its height.
    static let spanPhysicalSize = "spanPhysicalSize" // start from the displays' real sizes (default on)
    static func spanScaleKey(_ display: String) -> String { "spanScale.\(display)" }
    static func spanOffsetKey(_ display: String) -> String { "spanOffset.\(display)" }
    static let defaultOSCDestination = "127.0.0.1:9000"

    static var defaults: [String: Any] {[
        beatSensitivity: 1.0,
        presetDuration: 15.0,
        meshSizeX: 96,
        meshSizeY: 72,
        shufflePresets: false,
        broadcastSceneStream: false,
        oscDestination: defaultOSCDestination,
        hdrEnabled: false,
        hdrGain: 2.0,
        borderlessFullscreen: false,
        renderScale: 1.0,
        spanLayout: "displays",
        spanPhysicalSize: true,
        hideIdleCursor: true,
        hideCursorDelay: 2.5,
    ]}
}
