import Foundation
import Observation
import os

/// Shared app-level state that both the GL view and SwiftUI's `commands` menu need to
/// reach: audio app discovery/tap selection, and (once the GL view creates it)
/// preset navigation. Created once at app launch; the GL view attaches its
/// `PresetManager` during `prepareOpenGL()`, since that needs a live GL context.
@Observable
final class AppCoordinator {
    let audioAppMonitor = AudioAppMonitor()
    let audioFeed = AudioFeed()
    let renderStats = RenderStats()

    private(set) var currentTappedPID: pid_t?
    private nonisolated(unsafe) var tapController: ProcessTapController?
    fileprivate(set) var presetManager: PresetManager?

    private let logger = Logger(subsystem: "com.projectmac.app", category: "AppCoordinator")

    /// Wires up the preset-changed callback before `PresetManager.start()` loads the
    /// first preset, so `renderStats` picks up that initial load too, not just later
    /// next/prev/random calls.
    func attach(presetManager: PresetManager) {
        self.presetManager = presetManager
        presetManager.onPresetChanged = { [weak self] name in
            self?.renderStats.presetName = name
            self?.renderStats.isLoadingFirstPreset = false
        }
    }

    /// Applies the current (or default) `@AppStorage`-backed settings to the running
    /// projectM instance. Called once presetManager is attached, and again whenever
    /// `SettingsView` changes a value.
    func applyPersistedSettings() {
        guard let presetManager else { return }
        let defaults = UserDefaults.standard
        presetManager.setBeatSensitivity(Float(defaults.double(forKey: AppSettingsKeys.beatSensitivity)))
        presetManager.setPresetDuration(defaults.double(forKey: AppSettingsKeys.presetDuration))
        presetManager.setMeshSize(
            width: defaults.integer(forKey: AppSettingsKeys.meshSizeX),
            height: defaults.integer(forKey: AppSettingsKeys.meshSizeY)
        )
        presetManager.setShuffle(defaults.bool(forKey: AppSettingsKeys.shufflePresets))
    }

    func start() {
        audioAppMonitor.onAppsChanged = { [weak self] apps in
            guard let self else { return }
            if let pid = self.currentTappedPID, !apps.contains(where: { $0.pid == pid }) {
                self.tapController?.invalidate()
                self.tapController = nil
                self.currentTappedPID = nil
                self.renderStats.tappedAppName = nil
            }
            if self.tapController == nil, let first = apps.first {
                self.selectApp(first)
            }
        }
        audioAppMonitor.start()
    }

    func stop() {
        audioAppMonitor.stop()
        tapController?.invalidate()
        tapController = nil
    }

    func selectApp(_ app: AudioApp) {
        tapController?.invalidate()
        let controller = ProcessTapController(app: app, audioFeed: audioFeed)
        do {
            try controller.activate()
            tapController = controller
            currentTappedPID = app.pid
            renderStats.tappedAppName = app.name
        } catch {
            tapController = nil
            currentTappedPID = nil
            renderStats.tappedAppName = nil
            logger.error("Failed to activate tap for \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func nextPreset() { presetManager?.nextPreset() }
    func prevPreset() { presetManager?.prevPreset() }
    func randomPreset() { presetManager?.randomPreset() }
}
