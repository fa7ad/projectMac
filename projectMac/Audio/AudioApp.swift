import AppKit
import CoreAudio

/// One app family currently producing audio output.
struct AudioApp: Identifiable, Equatable {
    /// `AppIdentity.key`: stable across helper-process churn.
    let id: String
    let name: String
    let bundleID: String?
    let icon: NSImage?
    /// Representative PID, for display and the aggregate device name only.
    let pid: pid_t
    /// Every process object in the family, passed to
    /// `CATapDescription(stereoMixdownOfProcesses:)` so helpers that begin playing mid-tap
    /// are already covered. Sorted, so `==` is order-independent.
    let processObjectIDs: [AudioObjectID]

    /// Includes the process set: a family that gained a member needs its tap rebuilt.
    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.processObjectIDs == rhs.processObjectIDs
    }
}
