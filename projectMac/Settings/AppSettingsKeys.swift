import Foundation

/// UserDefaults keys + defaults for Settings, shared between `@AppStorage` in
/// `SettingsView` and `AppCoordinator.applyPersistedSettings()` (which applies them to
/// the running projectM instance on launch and whenever they change).
enum AppSettingsKeys {
    static let beatSensitivity = "beatSensitivity"
    static let presetDuration = "presetDuration"
    static let meshSizeX = "meshSizeX"
    static let meshSizeY = "meshSizeY"
    static let shufflePresets = "shufflePresets"

    nonisolated(unsafe) static let defaults: [String: Any] = [
        beatSensitivity: 1.0,
        presetDuration: 16.0,
        meshSizeX: 96,
        meshSizeY: 72,
        shufflePresets: true,
    ]
}
