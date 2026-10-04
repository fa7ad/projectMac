import Foundation

/// Two jobs. Onsets: causal and immediate — a block's energy above a rolling
/// mean+stddev threshold flags a beat, gated by a refractory period so one beat can't
/// double-trigger during its decay tail (drives `push`'s result and `phase`). Tempo:
/// the vendored SPFKTempo engine (see SPFKTempo/) over a sliding window of the last few
/// seconds — three-band spectral flux, autocorrelation, comb + harmonic template scoring.
///
/// A homegrown autocorrelation over a single energy envelope passed synthetic tracks but
/// still read a real 150bpm song as 100, 120 or 75; splitting kick, snare and hat bands
/// is what dense real mixes need. Searched over 40-300bpm then octave-folded into
/// `bpmRange` (searching only 80-160 directly tested much worse), and the reported tempo
/// is the median of the last three estimates, which hides the odd early-window miss.
/// Tempo is timed in samples, so `sampleRate` must be the tap's real rate.
final class BeatDetector {
    let sampleRate: Double
    private let blockSize: Int
    private let historyCount: Int
    private let sensitivity: Double
    private let minBeatInterval: CFAbsoluteTime
    private let bpmRange: ClosedRange<Double>

    private var blockAccum: Double = 0
    private var blockSampleCount = 0
    private var energyHistory: [Double] = []
    private var lastBeatTime: CFAbsoluteTime = 0

    private let tempo: BpmDetection
    private let tempoWindowFrames: Int
    private let tempoEverySamples: Int
    private var samplesSinceTempo = 0
    private var mono: [Float] = []
    private var recentEstimates: [Double] = []

    private(set) var currentBPM: Double = 120

    init(
        sampleRate: Double,
        blockMilliseconds: Double = 12,
        historySeconds: Double = 1.5,
        sensitivity: Double = 1.3,
        minBeatInterval: CFAbsoluteTime = 0.25,
        bpmRange: ClosedRange<Double> = 80...160,
        tempoWindowSeconds: Double = 8
    ) {
        self.sampleRate = sampleRate
        self.blockSize = max(1, Int(sampleRate * blockMilliseconds / 1000)) * 2 // stereo interleaved
        self.historyCount = max(4, Int(historySeconds * 1000 / blockMilliseconds))
        self.sensitivity = sensitivity
        self.minBeatInterval = minBeatInterval
        self.bpmRange = bpmRange
        tempo = BpmDetection(sampleRate: Float(sampleRate))
        tempoWindowFrames = Int(tempoWindowSeconds * tempo.onsetFramesPerSecond)
        tempoEverySamples = Int(sampleRate / 2) // re-estimate twice a second
    }

    /// At most one beat reported per call even if several blocks complete within it,
    /// matching the render loop's once-per-frame cadence. `now` is when `samples`
    /// arrived; each block is timestamped back from it by the audio that followed it,
    /// so a frame's batch of blocks doesn't collapse onto one instant.
    func push(_ samples: UnsafeBufferPointer<Float>, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        trackTempo(samples)

        var detected = false
        var i = 0
        while i < samples.count {
            let remaining = blockSize - blockSampleCount
            let take = min(remaining, samples.count - i)
            for j in 0..<take {
                let s = Double(samples[i + j])
                blockAccum += s * s
            }
            blockSampleCount += take
            i += take

            if blockSampleCount >= blockSize {
                let energy = blockAccum
                blockAccum = 0
                blockSampleCount = 0
                let blockTime = now - Double(samples.count - i) / 2 / sampleRate
                if processBlockEnergy(energy, at: blockTime) {
                    detected = true
                }
            }
        }
        return detected
    }

    private func processBlockEnergy(_ energy: Double, at now: CFAbsoluteTime) -> Bool {
        energyHistory.append(energy)
        if energyHistory.count > historyCount { energyHistory.removeFirst() }
        guard energyHistory.count >= historyCount / 2 else { return false }

        let mean = energyHistory.reduce(0, +) / Double(energyHistory.count)
        let variance = energyHistory.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(energyHistory.count)
        let stddev = variance.squareRoot()
        let threshold = mean + sensitivity * stddev

        guard energy > threshold, energy > 1e-9, now - lastBeatTime >= minBeatInterval else {
            return false
        }
        lastBeatTime = now
        return true
    }

    /// Feeds the tempo engine a mono downmix; every ~0.5s trims it to the window and
    /// re-estimates.
    private func trackTempo(_ samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / 2
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        for k in 0..<frames {
            mono[k] = (samples[2 * k] + samples[2 * k + 1]) / 2
        }
        mono.withUnsafeBufferPointer { tempo.process($0.baseAddress!, count: frames) }

        samplesSinceTempo += frames
        guard samplesSinceTempo >= tempoEverySamples else { return }
        samplesSinceTempo = 0
        tempo.trimOnsetHistory(keepingLast: tempoWindowFrames)
        var bpm = tempo.estimateTempoLive()
        guard bpm > 0 else { return } // no confident periodicity (silence, noise)
        while bpm >= bpmRange.upperBound { bpm /= 2 }
        while bpm < bpmRange.lowerBound { bpm *= 2 }

        recentEstimates.append(bpm)
        if recentEstimates.count > 3 { recentEstimates.removeFirst() }
        currentBPM = recentEstimates.sorted()[recentEstimates.count / 2]
    }

    /// 0.0-1.0 position within the current estimated beat interval.
    var phase: Double {
        guard lastBeatTime > 0, currentBPM > 0 else { return 0 }
        let interval = 60.0 / currentBPM
        let elapsed = CFAbsoluteTimeGetCurrent() - lastBeatTime
        let raw = elapsed.truncatingRemainder(dividingBy: interval) / interval
        return raw < 0 ? raw + 1 : raw
    }
}
