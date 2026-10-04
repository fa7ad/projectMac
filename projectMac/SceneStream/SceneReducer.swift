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
    private var beatDetector: BeatDetector?
    private var bandAnalyzer: AudioBandAnalyzer?
    private var previousPixels: [UInt8]?

    /// Drops this frame's work if the queue hasn't finished the last one, rather than
    /// backlogging — same policy `AudioFeed` uses for ring-buffer overflow.
    private let isProcessing = Atomic<Bool>(false)

    init(broadcaster: SceneStreamBroadcaster, renderStats: RenderStats) {
        self.broadcaster = broadcaster
        self.renderStats = renderStats
    }

    /// Called once per frame from the CVDisplayLink thread with that frame's drained PCM.
    /// Never dropped (unlike `processFrame`): tempo is timed by counting samples, so a
    /// skipped block would skew it. `at` is when the samples arrived.
    func pushAudio(_ pcm: [Float], sampleRate: Double, at now: CFAbsoluteTime) {
        queue.async { [self] in
            if beatDetector?.sampleRate != sampleRate { // a new tap can change the rate
                beatDetector = BeatDetector(sampleRate: sampleRate)
                bandAnalyzer = AudioBandAnalyzer(sampleRate: sampleRate)
            }
            pcm.withUnsafeBufferPointer { _ = beatDetector?.push($0, now: now) }
            bandAnalyzer?.push(interleavedStereo: pcm)
        }
    }

    /// Discards analyzer state after a gap in `pushAudio` (broadcasting was off).
    func resetAudio() {
        queue.async { [self] in
            beatDetector = nil
            bandAnalyzer = nil
        }
    }

    /// Called once per frame from the CVDisplayLink thread; `pixels` is an already
    /// copied value-type snapshot, so this doesn't reach back into render-thread state.
    func processFrame(pixels: [UInt8], gridSize: Int) {
        guard isProcessing.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.reduce(pixels: pixels, gridSize: gridSize)
            self.isProcessing.store(false, ordering: .relaxed)
        }
    }

    private func reduce(pixels: [UInt8], gridSize: Int) {
        let (vibrantRGB, mutedRGB) = DominantColor.vibrantAndMuted(pixels: pixels, gridSize: gridSize)
        let averageRGB = DominantColor.flatAverage(pixels: pixels, gridSize: gridSize)
        let brightness = DominantColor.luma(averageRGB)

        let energy = frameDiffEnergy(pixels: pixels, gridSize: gridSize)
        previousPixels = pixels
        let onset = visualOnsetDetector.push(energy)

        let update = SceneUpdate(
            brightness: brightness,
            audioBPM: beatDetector?.currentBPM ?? 120,
            audioPhase: beatDetector?.phase ?? 0,
            visualBPM: visualOnsetDetector.currentBPM,
            visualPhase: visualOnsetDetector.phase,
            visualOnset: onset,
            vibrant: DominantColor.rgbToHSV(vibrantRGB),
            muted: DominantColor.rgbToHSV(mutedRGB),
            average: DominantColor.rgbToHSV(averageRGB),
            bass: bandAnalyzer?.bass ?? 0,
            mid: bandAnalyzer?.mid ?? 0,
            treble: bandAnalyzer?.treble ?? 0
        )
        broadcaster.sendUpdate(update)

        let renderStats = renderStats
        let sendError = broadcaster.lastError.withLock { $0 }
        DispatchQueue.main.async {
            renderStats.sceneStream = update
            renderStats.sceneStreamError = sendError
        }
    }

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
