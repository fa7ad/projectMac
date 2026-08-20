import Foundation

/// Shared between `@AppStorage` in `SettingsView` and
/// `AppCoordinator.applyPersistedSettings()`, so the two can't drift.
enum AppSettingsKeys {
    static let beatSensitivity = "beatSensitivity"
    static let presetDuration = "presetDuration"
    static let meshSizeX = "meshSizeX"
    static let meshSizeY = "meshSizeY"
    static let shufflePresets = "shufflePresets"

    static var defaults: [String: Any] {[
        beatSensitivity: 1.0,
        presetDuration: 15.0,
        meshSizeX: 96,
        meshSizeY: 72,
        shufflePresets: false,
    ]}
}
