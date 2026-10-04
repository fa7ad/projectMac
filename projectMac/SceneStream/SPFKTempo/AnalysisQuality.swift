// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

/// Controls the tradeoff between detection speed and accuracy.
/// Higher quality uses more overlapping analysis windows for finer onset resolution.
public enum AnalysisQuality: Int, Sendable {
    /// No overlap. ~4x faster than `.accurate`, suitable for strong rhythmic material.
    case fast = 1
    /// 50% overlap. ~2x faster than `.accurate`, good general-purpose default.
    case balanced = 2
    /// 75% overlap. Most accurate onset detection, highest CPU cost.
    case accurate = 4
}
