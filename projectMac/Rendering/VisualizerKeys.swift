import AppKit

extension NSWindow {
    /// Native fullscreen, or a borderless window covering its whole screen (our own mode).
    var isVisualizerFullscreen: Bool {
        styleMask.contains(.fullScreen) || (styleMask == .borderless && frame == screen?.frame)
    }
}

/// The keys every visualizer window (the main one and every mirror) understands, so they all
/// behave the same. Returns false for a key it doesn't handle, so the caller can pass it on.
///
/// N/P/R and the arrows change preset, F toggles fullscreen, Z toggles span mode, D toggles the debug overlay (shown
/// in the main window), Q quits, Esc leaves fullscreen, or closes the window if it isn't in it.
@MainActor
func handleVisualizerKey(_ event: NSEvent, in window: NSWindow?, coordinator: AppCoordinator) -> Bool {
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "n":
        coordinator.nextPreset()
    case "p":
        coordinator.prevPreset()
    case "r":
        coordinator.randomPreset()
    case "f":
        coordinator.mirrorController.toggleFullscreen(of: window)
    case "z":
        coordinator.mirrorController.setSpan(!coordinator.mirrorController.isSpanning)
    case "d":
        coordinator.renderStats.isDebugOverlayVisible.toggle()
    case "q":
        NSApp.terminate(nil)
    case "\u{1b}": // Escape
        if coordinator.mirrorController.isFullscreen(window) { coordinator.mirrorController.toggleFullscreen(of: window) } else { window?.performClose(nil) }
    default:
        switch event.specialKey {
        case .rightArrow:
            coordinator.nextPreset()
        case .leftArrow:
            coordinator.prevPreset()
        default:
            return false
        }
    }
    return true
}
