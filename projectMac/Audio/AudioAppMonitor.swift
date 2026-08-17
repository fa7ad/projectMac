import AppKit
import CoreAudio
import Observation

/// Enumerates running applications currently producing audio output, via the
/// CoreAudio HAL process object list. Debounces HAL notifications since the list can
/// fire several times in quick succession as processes start/stop audio IO.
@Observable
final class AudioAppMonitor {
    private(set) var audioApps: [AudioApp] = []

    /// Fired after every refresh (including the initial one from `start()`), on the main thread.
    var onAppsChanged: (([AudioApp]) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var debounceWorkItem: DispatchWorkItem?

    func start() {
        guard listenerBlock == nil else { return }
        refresh()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(.system, &address, .main, block)
    }

    func stop() {
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, block)
            listenerBlock = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    private func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func refresh() {
        guard let processIDs = try? AudioObjectID.readProcessObjectList() else { return }

        var apps: [AudioApp] = []
        var seenPIDs = Set<pid_t>()
        for objectID in processIDs {
            guard objectID.readProcessIsRunningOutput() else { continue }
            guard let pid = try? objectID.readProcessPID() else { continue }
            guard seenPIDs.insert(pid).inserted else { continue }
            guard let runningApp = NSRunningApplication(processIdentifier: pid) else { continue }

            let name = runningApp.localizedName ?? objectID.readProcessBundleID() ?? "PID \(pid)"
            apps.append(AudioApp(
                pid: pid,
                name: name,
                bundleID: runningApp.bundleIdentifier,
                icon: runningApp.icon,
                processObjectIDs: [objectID]
            ))
        }

        audioApps = apps.sorted { $0.name < $1.name }
        onAppsChanged?(audioApps)
    }
}
