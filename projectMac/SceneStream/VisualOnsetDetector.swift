import Foundation

/// Same detection shape as `BeatDetector`, but reduced from a per-frame visual-energy
/// scalar (mean RGB frame-diff) instead of streaming audio blocks — separate class since
/// the inputs are structurally different. Lives on `SceneReducer`'s background queue.
final class VisualOnsetDetector {
    private let historyCount: Int
    private let sensitivity: Double
    private let minOnsetInterval: CFAbsoluteTime

    private var energyHistory: [Double] = []
    private var lastOnsetTime: CFAbsoluteTime = 0
    private var recentIntervals: [Double] = []

    private(set) var currentBPM: Double = 120

    init(
        historySamples: Int = 32,
        sensitivity: Double = 1.3,
        minOnsetInterval: CFAbsoluteTime = 0.1
    ) {
        self.historyCount = max(4, historySamples)
        self.sensitivity = sensitivity
        self.minOnsetInterval = minOnsetInterval
    }

    /// One call per rendered frame; `minOnsetInterval` is shorter than `BeatDetector`'s
    /// since a strobing preset can cut faster than any real song's beat.
    @discardableResult
    func push(_ energy: Double) -> Bool {
        energyHistory.append(energy)
        if energyHistory.count > historyCount { energyHistory.removeFirst() }
        guard energyHistory.count >= historyCount / 2 else { return false }

        let mean = energyHistory.reduce(0, +) / Double(energyHistory.count)
        let variance = energyHistory.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(energyHistory.count)
        let stddev = variance.squareRoot()
        let threshold = mean + sensitivity * stddev

        let now = CFAbsoluteTimeGetCurrent()
        guard energy > threshold, energy > 1e-9, now - lastOnsetTime >= minOnsetInterval else {
            return false
        }

        if lastOnsetTime > 0 {
            let interval = now - lastOnsetTime
            if interval > 0.05 && interval < 2.0 {
                recentIntervals.append(interval)
                if recentIntervals.count > 8 { recentIntervals.removeFirst() }
                let sorted = recentIntervals.sorted()
                currentBPM = 60.0 / sorted[sorted.count / 2]
            }
        }
        lastOnsetTime = now
        return true
    }

    /// 0.0-1.0 position within the current estimated onset interval.
    var phase: Double {
        guard lastOnsetTime > 0, currentBPM > 0 else { return 0 }
        let interval = 60.0 / currentBPM
        let elapsed = CFAbsoluteTimeGetCurrent() - lastOnsetTime
        let raw = elapsed.truncatingRemainder(dividingBy: interval) / interval
        return raw < 0 ? raw + 1 : raw
    }
}
