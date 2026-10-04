// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

/// Configuration for the BPM detection algorithm.
public struct BpmDetectionOptions: Sendable {
    /// The analysis quality level, controlling the overlap between FFT windows.
    public var quality: AnalysisQuality

    /// The range of BPM values to consider. Candidates outside this range are discarded.
    public var bpmRange: ClosedRange<Float>

    /// Number of beats per bar, used for comb-filter periodicity scoring.
    public var beatsPerBar: Int

    /// Perceptual weighting amount that biases results toward mid-tempo ranges.
    /// 0.0 = no bias (most neutral/accurate),
    /// 1.0 = full legacy weighting toward ~130 BPM.
    public var perceptualWeightingAmount: Float

    /// Controls how aggressively the detector rejects non-rhythmic audio.
    public var confidenceLevel: ConfidenceLevel

    /// Creates detection options.
    ///
    /// - Parameters:
    ///   - quality: Analysis quality level. Defaults to `.balanced`.
    ///   - bpmRange: Valid BPM range. Defaults to 40–300.
    ///   - beatsPerBar: Beats per bar for comb filtering. Defaults to 4.
    ///   - perceptualWeightingAmount: Mid-tempo bias strength (0.0–1.0). Defaults to 0.0.
    ///   - confidenceLevel: How aggressively to reject non-rhythmic audio. Defaults to `.moderate`.
    public init(
        quality: AnalysisQuality = .balanced,
        bpmRange: ClosedRange<Float> = 40 ... 300,
        beatsPerBar: Int = 4,
        perceptualWeightingAmount: Float = 0.0,
        confidenceLevel: ConfidenceLevel = .moderate
    ) {
        self.quality = quality
        self.bpmRange = bpmRange
        self.beatsPerBar = beatsPerBar
        self.perceptualWeightingAmount = perceptualWeightingAmount
        self.confidenceLevel = confidenceLevel
    }
}
