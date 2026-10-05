import AppKit

/// Hides the mouse cursor after a short idle while the view's window is fullscreen (native
/// or the borderless mode); the next mouse movement brings it back. macOS has no setting
/// for this. A view owns one, calls `updateTracking` from `updateTrackingAreas`, and
/// `poke` from `mouseMoved`/`mouseDown`/`keyDown`.
@MainActor
final class CursorAutoHider {
    private var timer: Timer?
    private var trackingArea: NSTrackingArea?

    func updateTracking(on view: NSView) {
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: view)
        view.addTrackingArea(area)
        trackingArea = area
    }

    /// Restarts the idle countdown (Settings: on/off and delay, read each time).
    func poke(_ view: NSView) {
        timer?.invalidate()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettingsKeys.hideIdleCursor) else { return }
        let delay = max(0.5, defaults.double(forKey: AppSettingsKeys.hideCursorDelay))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak view] _ in
            guard let window = view?.window, Self.isFullscreen(window) else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private static func isFullscreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen)
            || (window.styleMask == .borderless && window.frame == window.screen?.frame)
    }
}
