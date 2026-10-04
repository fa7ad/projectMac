import Observation

/// Backs the on-screen overlay (`D`). The render thread hops to main to update these.
@Observable
final class RenderStats {
    var fps: Int = 0
    var presetName: String = ""
    var tappedAppName: String?
    /// The tap's sample rate in Hz, shown next to the app name.
    var tapSampleRate: Double?
    /// Last tap failure, cleared by the next successful tap. Surfaced by
    /// `AudioErrorBannerView`, since a dead tap otherwise just looks like silence.
    var audioError: String?
    var isDebugOverlayVisible: Bool = false
    var isLoadingFirstPreset: Bool = true
    /// Peak sample magnitude seen in the audio ring buffer over the last ~1s. Exceeds 1
    /// when the tapped app's own output does; taps see it before the device clamps.
    var audioPeakLevel: Float = 0
    /// Ring-buffer writes that dropped samples because it was full.
    var audioOverflowCount: Int = 0
    /// Stereo frames queued in the ring buffer, and its capacity.
    var audioBacklogFrames: Int = 0
    var audioCapacityFrames: Int = 0
    /// Latest scene-stream reduction. `nil` when broadcasting is off, so the overlay
    /// section disappears instead of freezing on a stale reading.
    var sceneStream: SceneUpdate?
    /// Why OSC sends are failing (bad destination IP, network error), nil while they
    /// succeed. Only shown while broadcasting is on.
    var sceneStreamError: String?
}
