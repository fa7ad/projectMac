import SwiftUI

/// Toggled on-screen with the `D` key (see `ProjectMGLView.keyDown`).
struct DebugOverlayView: View {
    let stats: RenderStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(stats.fps) fps")
            if !stats.presetName.isEmpty {
                Text(stats.presetName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(stats.tappedAppName.map { "Tapping: \($0)" } ?? "No audio source")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .allowsHitTesting(false)
    }
}
