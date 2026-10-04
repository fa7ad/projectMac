import Foundation
import Synchronization

/// Owns everything that happens after each frame's GL readback — dominant-color
/// clustering, visual-onset detection, FFT band split — off the CVDisplayLink thread.
/// `ProjectMGLView.renderFrame` does only the GL-bound readback and hands the result to
/// `processFrame`; state here is touched only from `queue`, so it needs no locking.
final class SceneReducer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.projectmac.sceneReducer")
    private let broadcaster: SceneStreamBroadcaster
    private let renderStats: RenderStats

    private let visualOnsetDetector = VisualOnsetDetector()
    private let bandAnalyzer = AudioBandAnalyzer()
    private var previousPixels: [UInt8]?

    /// Drops this frame's work if the queue hasn't finished the last one, rather than
    /// backlogging — same policy `AudioFeed` uses for ring-buffer overflow.
    private let isProcessing = Atomic<Bool>(false)

    init(broadcaster: SceneStreamBroadcaster, renderStats: RenderStats) {
        self.broadcaster = broadcaster
        self.renderStats = renderStats
    }

    /// Called once per frame from the CVDisplayLink thread; `pixels`/`pcm` are already
    /// copied value-type snapshots, so this doesn't reach back into render-thread state.
    func processFrame(pixels: [UInt8], gridSize: Int, audioBPM: Double, audioPhase: Double, pcm: [Float]?) {
        guard isProcessing.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.reduce(pixels: pixels, gridSize: gridSize, audioBPM: audioBPM, audioPhase: audioPhase, pcm: pcm)
            self.isProcessing.store(false, ordering: .relaxed)
        }
    }

    private func reduce(pixels: [UInt8], gridSize: Int, audioBPM: Double, audioPhase: Double, pcm: [Float]?) {
        let (vibrantRGB, mutedRGB) = DominantColor.vibrantAndMuted(pixels: pixels, gridSize: gridSize)
        let averageRGB = DominantColor.flatAverage(pixels: pixels, gridSize: gridSize)
        let brightness = DominantColor.luma(averageRGB)

        let energy = frameDiffEnergy(pixels: pixels, gridSize: gridSize)
        previousPixels = pixels
        let onset = visualOnsetDetector.push(energy)

        if let pcm {
            bandAnalyzer.push(interleavedStereo: pcm)
        }

        let update = SceneUpdate(
            brightness: brightness,
            audioBPM: audioBPM,
            audioPhase: audioPhase,
            visualBPM: visualOnsetDetector.currentBPM,
            visualPhase: visualOnsetDetector.phase,
            visualOnset: onset,
            vibrant: DominantColor.rgbToHSV(vibrantRGB),
            muted: DominantColor.rgbToHSV(mutedRGB),
            average: DominantColor.rgbToHSV(averageRGB),
            bass: bandAnalyzer.bass,
            mid: bandAnalyzer.mid,
            treble: bandAnalyzer.treble
        )
        broadcaster.sendUpdate(update)

        let renderStats = renderStats
        DispatchQueue.main.async {
            renderStats.sceneStream = update
        }
        let sendError = broadcaster.lastError.withLock { $0 }
    }

            renderStats.sceneStreamError = sendError
    /// Mean RGB (not luma) absolute diff — luma washes out a red<->cyan style flip that's
    /// perceptually huge but nets to almost no luma change.
    private func frameDiffEnergy(pixels: [UInt8], gridSize: Int) -> Double {
        guard let previous = previousPixels, previous.count == pixels.count else { return 0 }
        let texelCount = gridSize * gridSize
        var sum: Double = 0
        for i in 0..<texelCount {
            let base = i * 4
            let dr = abs(Int(pixels[base]) - Int(previous[base]))
            let dg = abs(Int(pixels[base + 1]) - Int(previous[base + 1]))
            let db = abs(Int(pixels[base + 2]) - Int(previous[base + 2]))
            sum += Double(dr + dg + db)
        }
        return sum / Double(texelCount) / 255.0
    }
}
