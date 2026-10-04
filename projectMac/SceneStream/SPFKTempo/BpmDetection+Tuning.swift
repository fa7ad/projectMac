// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

extension BpmDetection {
    // MARK: - Internal DSP tuning constants

    /// Compile-time constants for the detection algorithm. Grouped by function
    /// and declared `static` since they don't vary per instance.
    enum Tuning {
        /// Log-compression factor applied to spectral magnitudes before computing
        /// onset flux. Higher values emphasize quieter onsets; lower values favor
        /// loud transients.
        static let fluxCompression: Float = 2.0

        /// Blend between comb-filter score (0.0) and harmonic template score (1.0)
        /// for the final candidate ranking.
        static let templateBlend: Float = 0.35

        /// Per-band autocorrelation weights controlling how much each frequency
        /// range contributes to the combined periodicity signal.
        enum BandWeights {
            /// Low band (0–550 Hz): kick drums and bass onsets.
            static let low: Float = 1.0
            /// Mid band (550–4000 Hz): snare, vocals, harmonic content.
            static let mid: Float = 0.8
            /// High band (4–16 kHz): hi-hats and cymbal transients.
            static let high: Float = 0.5
            /// Broadband RMS energy envelope.
            static let rms: Float = 0.1
        }

        /// Weights and penalties for the harmonic template scorer that reduces
        /// octave errors (e.g. picking 120 instead of 60 BPM).
        enum HarmonicTemplate {
            /// Weight for the fundamental lag.
            static let weight1: Float = 1.0
            /// Weight for the 2× lag (half-tempo harmonic).
            static let weight2: Float = 0.25
            /// Weight for the 3× lag (third-tempo harmonic).
            static let weight3: Float = 0.10
            /// Weight for the 4× lag (quarter-tempo harmonic).
            static let weight4: Float = 0.05
            /// Penalty when the half-lag (double-tempo) shows a strong peak.
            static let penalty2: Float = 0.10
            /// Penalty when the third-lag (triple-tempo) shows a strong peak.
            static let penalty3: Float = 0.20
        }

    }
}
