import AppKit
import CoreAudio
import Observation

/// Enumerates apps currently producing audio, via the CoreAudio HAL process object list.
///
/// Process objects are grouped into app families (see `AppIdentity`) so a browser appears
/// once under its own name rather than once per helper.
@Observable
final class AudioAppMonitor {
    private(set) var audioApps: [AudioApp] = []

    /// Fired on the main thread after every refresh, including `start()`'s.
    var onAppsChanged: (([AudioApp]) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// One process starting or stopping audio can fire the listener several times.
    private var debounceWorkItem: DispatchWorkItem?
    /// The HAL never delivers change notifications for `kAudioProcessPropertyIsRunningOutput`.
    private var pollTimer: Timer?
    /// `AppIdentity` resolution hits the filesystem and LaunchServices; `refresh` runs
    /// every second. Pruned to the PIDs still in the HAL list.
    private var identityCache: [pid_t: AppIdentity] = [:]

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
        identityCache.removeAll()
    }

    private func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private struct Family {
        let identity: AppIdentity
        var processObjectIDs: Set<AudioObjectID> = []
        /// At least one member is producing output; families without one stay hidden.
        var isPlaying = false
    }

    private func refresh() {
        guard let processIDs = try? AudioObjectID.readProcessObjectList() else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        var families: [String: Family] = [:]
        var seenPIDs = Set<pid_t>()

        for objectID in processIDs {
            guard let pid = try? objectID.readProcessPID(), pid > 0, pid != ownPID else { continue }
            seenPIDs.insert(pid)

            let identity: AppIdentity
            if let cached = identityCache[pid] {
                identity = cached
            } else {
                identity = AppIdentity(pid: pid)
                identityCache[pid] = identity
            }
            guard identity.bundleID != ownBundleID else { continue }

            var family = families[identity.key] ?? Family(identity: identity)
            family.processObjectIDs.insert(objectID)
            family.isPlaying = family.isPlaying || objectID.readProcessIsRunningOutput()
            families[identity.key] = family
        }
        identityCache = identityCache.filter { seenPIDs.contains($0.key) }

        let apps = families.values
            .filter(\.isPlaying)
            .map { family in
                AudioApp(
                    id: family.identity.key,
                    name: family.identity.name,
                    bundleID: family.identity.bundleID,
                    icon: family.identity.icon,
                    pid: family.identity.pid,
                    processObjectIDs: family.processObjectIDs.sorted()
                )
            }
            .sorted { $0.name < $1.name }

        guard apps != audioApps else { return }
        audioApps = apps
        onAppsChanged?(audioApps)
    }
}
