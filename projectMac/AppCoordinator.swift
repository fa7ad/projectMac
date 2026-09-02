import CoreAudio
import Foundation
import Observation
import os

/// State both the GL view and SwiftUI's `commands` menu reach: audio app discovery and
/// tap selection, plus preset navigation once the GL view attaches its `PresetManager`
/// during `prepareOpenGL()` (which needs a live GL context to exist first).
@Observable
final class AppCoordinator {
    let audioAppMonitor = AudioAppMonitor()
    let audioFeed = AudioFeed()
    let renderStats = RenderStats()

    private(set) var currentTappedAppID: String?
    private var tapController: ProcessTapController?
    fileprivate(set) var presetManager: PresetManager?

    /// The aggregate device pins the clock device chosen at activation, so a tap outlives
    /// neither that device being unplugged nor the system moving output elsewhere.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// A device change fires several notifications and the HAL needs a moment to settle.
    private var retapWorkItem: DispatchWorkItem?

    private let logger = Logger(subsystem: "com.projectmac.app", category: "AppCoordinator")

    /// Wires the callback before `start()` loads the first preset, so `renderStats` sees
    /// that load too.
    func attach(presetManager: PresetManager) {
        self.presetManager = presetManager
        presetManager.onPresetChanged = { [weak self] name in
            self?.renderStats.presetName = name
            self?.renderStats.isLoadingFirstPreset = false
        }
    }

    /// Called once `presetManager` attaches, then on every `SettingsView` change.
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
            self?.reconcileTap(with: apps)
        }
        audioAppMonitor.start()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRetapForOutputDeviceChange()
        }
        defaultOutputListener = block
        AudioObjectAddPropertyListenerBlock(.system, &defaultOutputAddress, .main, block)
    }

    func stop() {
        audioAppMonitor.stop()
        if let block = defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(.system, &defaultOutputAddress, .main, block)
            defaultOutputListener = nil
        }
        retapWorkItem?.cancel()
        retapWorkItem = nil
        tapController?.invalidate()
        tapController = nil
    }

    private func reconcileTap(with apps: [AudioApp]) {
        guard let tapped = tapController?.app else {
            if let first = apps.first { selectApp(first) }
            return
        }

        guard let current = apps.first(where: { $0.id == tapped.id }) else {
            clearTap()
            if let first = apps.first { selectApp(first) }
            return
        }

        // Members that dropped out are harmless — their process objects simply stop
        // producing. A member the tap does not cover is not: that helper's audio is lost
        // until the tap is rebuilt around it.
        let covered = Set(tapped.processObjectIDs)
        if !Set(current.processObjectIDs).isSubset(of: covered) {
            logger.info("Process family for \(current.name, privacy: .public) grew, rebuilding tap")
            selectApp(current)
        }
    }

    private func scheduleRetapForOutputDeviceChange() {
        retapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.retapForOutputDeviceChange()
        }
        retapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func retapForOutputDeviceChange() {
        guard let controller = tapController else { return }
        guard let uid = try? AudioObjectID.defaultOutputDevice().readDeviceUID() else {
            reportAudioError("Audio output device changed and no replacement could be read")
            return
        }
        guard uid != controller.clockDeviceUID else { return }

        logger.info("Default output device changed, rebuilding tap")
        let app = audioAppMonitor.audioApps.first { $0.id == controller.app.id } ?? controller.app
        selectApp(app)
    }

    func selectApp(_ app: AudioApp) {
        tapController?.invalidate()
        let controller = ProcessTapController(app: app, audioFeed: audioFeed)
        controller.onFailure = { [weak self] message in
            guard let self, self.tapController === controller else { return }
            self.reportAudioError(message)
        }
        do {
            try controller.activate()
            tapController = controller
            currentTappedAppID = app.id
            renderStats.tappedAppName = app.name
            renderStats.audioError = nil
        } catch {
            clearTap()
            reportAudioError("Could not tap \(app.name): \(error.localizedDescription)")
        }
    }

    private func clearTap() {
        tapController?.invalidate()
        tapController = nil
        currentTappedAppID = nil
        renderStats.tappedAppName = nil
    }

    private func reportAudioError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        renderStats.audioError = message
    }

    func nextPreset() { presetManager?.nextPreset() }
    func prevPreset() { presetManager?.prevPreset() }
    func randomPreset() { presetManager?.randomPreset() }
}
