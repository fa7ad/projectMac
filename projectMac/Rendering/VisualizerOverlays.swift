import SwiftUI

/// The debug overlay, the first-preset loading indicator and the audio error banner. Shown over
/// the main window's scene, and over the borderless cover that replaces it in borderless
/// fullscreen, so that mode doesn't lose them.
struct VisualizerOverlays: View {
    let coordinator: AppCoordinator

    var body: some View {
        ZStack(alignment: .topLeading) {
            if coordinator.renderStats.isLoadingFirstPreset {
                LoadingOverlayView()
            }
            if coordinator.renderStats.isDebugOverlayVisible {
                DebugOverlayView(stats: coordinator.renderStats)
            }
            if let audioError = coordinator.renderStats.audioError {
                AudioErrorBannerView(message: audioError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}
