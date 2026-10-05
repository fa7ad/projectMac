import Foundation

// Vendored from https://github.com/ryanfrancesconi/spfk-tempo (MIT, see LICENSE.txt;
// revision in scripts/spfktempo.rev; update with scripts/sync-spfktempo.sh): the BpmDetection engine
// only, not the file-analysis layer or its SPFKAudioBase dependency. This file is
// projectMac's addition: live, sliding-window use of the batch engine. It reads the
// engine's internal state, so a sync that renames things fails to compile here.
extension BpmDetection {
    /// Onset frames per second of audio.
    var onsetFramesPerSecond: Double { Double(inputSampleRate) / Double(stepSize) }

    /// Drops all but the most recent `frames` onset frames.
    func trimOnsetHistory(keepingLast frames: Int) {
        let excess = lowFrequencyFlux.count - frames
        guard excess > 0 else { return }
        lowFrequencyFlux.removeFirst(excess)
        midFrequencyFlux.removeFirst(excess)
        highFrequencyFlux.removeFirst(excess)
        blockRmsEnvelope.removeFirst(excess)
    }

    /// Tempo of the current window. Unlike `estimateTempo()`, doesn't flush the
    /// pending partial block zero-padded, which would inject silence mid-stream.
    func estimateTempoLive() -> Double { finish() }
}
