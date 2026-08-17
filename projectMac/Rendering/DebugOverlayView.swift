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
            Text(String(format: "Audio peak: %.3f", stats.audioPeakLevel))
                .foregroundStyle(stats.audioPeakLevel > 0.001 ? .green : .white)
            Text("Buffer: \(stats.audioBacklogFrames)/\(stats.audioCapacityFrames) frames")
            if stats.audioOverflowCount > 0 {
                Text("Buffer overflows: \(stats.audioOverflowCount)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .allowsHitTesting(false)
    }
}
