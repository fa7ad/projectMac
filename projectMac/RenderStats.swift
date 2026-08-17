import Observation

/// Debug/status info surfaced to the on-screen overlay (toggled with the `D` key) and,
/// for FPS, updated once per second from the CVDisplayLink thread, hop to main first.
@Observable
final class RenderStats {
    var fps: Int = 0
    var presetName: String = ""
    var tappedAppName: String?
    var isDebugOverlayVisible: Bool = false
    var isLoadingFirstPreset: Bool = true
    /// Peak sample magnitude (0...1) seen in the audio ring buffer over the last ~1s.
    var audioPeakLevel: Float = 0
    /// Cumulative count of ring-buffer writes that dropped samples because it was full.
    var audioOverflowCount: Int = 0
    /// Stereo frames currently queued in the ring buffer, and its total capacity.
    var audioBacklogFrames: Int = 0
    var audioCapacityFrames: Int = 0
}
