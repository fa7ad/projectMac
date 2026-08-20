import AppKit
import CoreAudio

/// A running app currently producing audio output.
struct AudioApp: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    /// Process object IDs to pass to `CATapDescription(stereoMixdownOfProcesses:)`.
    let processObjectIDs: [AudioObjectID]

    var id: pid_t { pid }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.pid == rhs.pid
    }
}
