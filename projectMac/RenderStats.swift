import Observation

/// Backs the on-screen overlay (`D`). The render thread hops to main to update these.
@Observable
final class RenderStats {
    var fps: Int = 0
    var presetName: String = ""
    var tappedAppName: String?
    var isDebugOverlayVisible: Bool = false
    var isLoadingFirstPreset: Bool = true
    /// Peak sample magnitude (0...1) seen in the audio ring buffer over the last ~1s.
    var audioPeakLevel: Float = 0
    /// Ring-buffer writes that dropped samples because it was full.
    var audioOverflowCount: Int = 0
    /// Stereo frames queued in the ring buffer, and its capacity.
    var audioBacklogFrames: Int = 0
    var audioCapacityFrames: Int = 0
}
