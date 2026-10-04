// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

/// Controls how aggressively the detector rejects non-rhythmic audio.
///
/// After scoring tempo candidates, the detector compares the best peak's
/// score against the median of all scores. Rhythmic audio produces a sharp
/// dominant peak (ratio 3–10×), while noise-like signals have a flat
/// distribution (ratio ~1–2×). Higher thresholds reject more ambiguous results.
public enum ConfidenceLevel: Sendable {
    /// Accept any result that produces peaks, even for noise-like audio.
    case disabled
    /// Reject only clearly non-rhythmic signals (threshold 1.8).
    case low
    /// Balanced rejection of non-rhythmic content (threshold 2.5).
    case moderate
    /// Aggressively reject ambiguous results (threshold 3.5).
    case high

    var threshold: Float {
        switch self {
        case .disabled: 0
        case .low: 1.8
        case .moderate: 2.5
        case .high: 3.5
        }
    }
}
