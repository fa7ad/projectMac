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
}
