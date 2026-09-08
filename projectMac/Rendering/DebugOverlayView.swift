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
            if let audioError = stats.audioError {
                Text(audioError)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(String(format: "Audio peak: %.3f", stats.audioPeakLevel))
                .foregroundStyle(stats.audioPeakLevel > 0.001 ? .green : .white)
            Text("Buffer: \(stats.audioBacklogFrames)/\(stats.audioCapacityFrames) frames")
            if stats.audioOverflowCount > 0 {
                Text("Buffer overflows: \(stats.audioOverflowCount)")
                    .foregroundStyle(.orange)
            }
            if let scene = stats.sceneStream {
                sceneStreamSection(scene)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .allowsHitTesting(false)
    }

    /// Audio- vs. visual-derived tempo, plus the vibrant/muted/average swatches.
    @ViewBuilder
    private func sceneStreamSection(_ scene: SceneUpdate) -> some View {
        Text(String(format: "Audio %.0fbpm (φ%.2f)  Visual %.0fbpm (φ%.2f)",
                     scene.audioBPM, scene.audioPhase, scene.visualBPM, scene.visualPhase))
            .foregroundStyle(scene.visualOnset ? .yellow : .white)
        HStack(spacing: 8) {
            swatch("Vibrant", scene.vibrant)
            swatch("Muted", scene.muted)
            swatch("Avg", scene.average)
        }
        Text(String(format: "Bass %.2f  Mid %.2f  Treble %.2f", scene.bass, scene.mid, scene.treble))
    }

    private func swatch(_ label: String, _ hsv: HSV) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hue: Double(hsv.h), saturation: Double(hsv.s), brightness: Double(hsv.v)))
                .frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.4), lineWidth: 0.5))
            Text(label)
        }
    }
}
