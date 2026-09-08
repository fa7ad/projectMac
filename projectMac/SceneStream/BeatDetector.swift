import Foundation

/// Causal energy-based onset detector: flags a beat the instant a block's energy
/// exceeds a rolling mean+stddev threshold, gated by a refractory period so one
/// beat can't double-trigger during its decay tail. No autocorrelation or
/// beat-grid alignment — just "did a beat happen" and a rough current BPM.
final class BeatDetector {
    private let blockSize: Int
    private let historyCount: Int
    private let sensitivity: Double
    private let minBeatInterval: CFAbsoluteTime

    private var blockAccum: Double = 0
    private var blockSampleCount = 0
    private var energyHistory: [Double] = []
    private var lastBeatTime: CFAbsoluteTime = 0
    private var recentIntervals: [Double] = []

    private(set) var currentBPM: Double = 120

    init(
        sampleRate: Double,
        blockMilliseconds: Double = 46,
        historySeconds: Double = 1.5,
        sensitivity: Double = 1.3,
        minBeatInterval: CFAbsoluteTime = 0.25
    ) {
        self.blockSize = max(1, Int(sampleRate * blockMilliseconds / 1000)) * 2 // stereo interleaved
        self.historyCount = max(4, Int(historySeconds * 1000 / blockMilliseconds))
        self.sensitivity = sensitivity
        self.minBeatInterval = minBeatInterval
    }

    /// At most one beat reported per call even if several blocks complete within it,
    /// matching the render loop's once-per-frame cadence.
    func push(_ samples: UnsafeBufferPointer<Float>) -> Bool {
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
                if processBlockEnergy(energy) {
                    detected = true
                }
            }
        }
        return detected
    }

    private func processBlockEnergy(_ energy: Double) -> Bool {
        energyHistory.append(energy)
        if energyHistory.count > historyCount { energyHistory.removeFirst() }
        guard energyHistory.count >= historyCount / 2 else { return false }

        let mean = energyHistory.reduce(0, +) / Double(energyHistory.count)
        let variance = energyHistory.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(energyHistory.count)
        let stddev = variance.squareRoot()
        let threshold = mean + sensitivity * stddev

        let now = CFAbsoluteTimeGetCurrent()
        guard energy > threshold, energy > 1e-9, now - lastBeatTime >= minBeatInterval else {
            return false
        }

        if lastBeatTime > 0 {
            let interval = now - lastBeatTime
            if interval > 0.25 && interval < 2.0 {
                recentIntervals.append(interval)
                if recentIntervals.count > 8 { recentIntervals.removeFirst() }
                let sorted = recentIntervals.sorted()
                currentBPM = 60.0 / sorted[sorted.count / 2]
            }
        }
        lastBeatTime = now
        return true
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
