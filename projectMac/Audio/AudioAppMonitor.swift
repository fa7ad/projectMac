import AppKit
import CoreAudio
import Observation

/// Enumerates running applications currently producing audio output, via the
/// CoreAudio HAL process object list.
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
    /// A single process starting/stopping audio can fire the list listener several times
    /// in quick succession.
    private var debounceWorkItem: DispatchWorkItem?
    /// The HAL never delivers change notifications for `kAudioProcessPropertyIsRunningOutput`.
    private var pollTimer: Timer?

    func start() {
        guard listenerBlock == nil else { return }
        refresh()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(.system, &address, .main, block)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, block)
            listenerBlock = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
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

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var apps: [AudioApp] = []
        var seenPIDs = Set<pid_t>()
        for objectID in processIDs {
            guard objectID.readProcessIsRunningOutput() else { continue }
            guard let pid = try? objectID.readProcessPID() else { continue }
            guard pid != ownPID else { continue }
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

        let sorted = apps.sorted { $0.name < $1.name }
        guard sorted != audioApps else { return }
        audioApps = sorted
        onAppsChanged?(audioApps)
    }
}
