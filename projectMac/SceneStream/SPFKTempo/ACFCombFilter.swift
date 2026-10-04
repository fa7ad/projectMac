// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

final class ACFCombFilter {
    private let beatsPerBar: Int
    private let minLag: Int
    private let maxLag: Int
    private let hopsPerSec: Float

    init(beatsPerBar: Int, minLag: Int, maxLag: Int, hopsPerSec: Float) {
        self.beatsPerBar = beatsPerBar
        self.minLag = minLag
        self.maxLag = maxLag
        self.hopsPerSec = hopsPerSec
    }

    @inline(__always)
    func filteredLength() -> Int {
        maxLag - minLag + 1
    }

    @inline(__always)
    static func contributingRange(lag: Int, multiple: Int) -> (base: Int, count: Int) {
        if multiple == 1 {
            return (lag, 1)
        }

        let center = lag * multiple
        let halfWindow = max(1, multiple / 4)
        let base = max(0, center - halfWindow)
        let count = halfWindow * 2 + 1
        return (base, count)
    }

    func filter(autocorrelation: [Float], autocorrelationLength: Int, filtered: inout [Float]) {
        let filteredLength = filteredLength()

        for filteredIndex in 0 ..< filteredLength {
            filtered[filteredIndex] = 0
            let lag = minLag + filteredIndex
            var multiple = 1
            var contributionCount = 0

            while true {
                let (base, count) = Self.contributingRange(lag: lag, multiple: multiple)
                if base + count > autocorrelationLength { break }

                var peak: Float = 0
                for j in base ..< (base + count) {
                    if j == base || autocorrelation[j] > peak {
                        peak = autocorrelation[j]
                    }
                }

                filtered[filteredIndex] += peak
                contributionCount += 1
                multiple = (multiple == 1) ? beatsPerBar : (multiple * 2)
            }

            if contributionCount != 0 {
                filtered[filteredIndex] /= Float(contributionCount)
            }
        }
    }

    func refine(lag: Int, autocorrelation: [Float], autocorrelationLength: Int) -> Float {
        var multiple = 1
        let seedLag = Float(lag)

        var candidateLags: [Float] = []
        var candidatePeaks: [Float] = []
        candidateLags.reserveCapacity(6)
        candidatePeaks.reserveCapacity(6)

        var maxPeak: Float = 0

        while multiple <= 16 {
            let (base, count) = Self.contributingRange(lag: lag, multiple: multiple)
            if base + count > autocorrelationLength { break }

            var peak: Float = 0
            var peakIndex = base
            let end = min(base + count, autocorrelationLength)

            for sampleIndex in base ..< end {
                if sampleIndex == base || autocorrelation[sampleIndex] > peak {
                    peak = autocorrelation[sampleIndex]
                    peakIndex = sampleIndex
                }
            }

            if peak > 0 {
                var interpolatedPeakIndex = Float(peakIndex)
                if peakIndex > 0, peakIndex + 1 < autocorrelationLength {
                    let leftValue = autocorrelation[peakIndex - 1]
                    let centerValue = autocorrelation[peakIndex]
                    let rightValue = autocorrelation[peakIndex + 1]
                    if centerValue > leftValue, centerValue > rightValue {
                        let denominator = leftValue - 2 * centerValue + rightValue
                        if denominator != 0 {
                            interpolatedPeakIndex += ((leftValue - rightValue) / denominator) / 2
                        }
                    }
                }

                candidateLags.append(interpolatedPeakIndex / Float(multiple))
                candidatePeaks.append(peak)
                if peak > maxPeak { maxPeak = peak }
            }

            multiple = (multiple == 1) ? beatsPerBar : (multiple * 2)
        }

        if candidateLags.isEmpty {
            return AutocorrelationFFT.lagToBpm(seedLag, hopsPerSec: hopsPerSec)
        }

        // Use a weighted consensus over strong harmonics to reduce
        // systematic drift from single-window peak picks.
        let keepThreshold = maxPeak * 0.9
        var weightedLag: Float = 0
        var totalWeight: Float = 0

        for i in 0 ..< candidateLags.count {
            let peak = candidatePeaks[i]
            if peak < keepThreshold { continue }

            let candidateLag = candidateLags[i]
            // Prefer consensus close to the seed lag from comb peak.
            let distanceFromSeedLag = abs(candidateLag - seedLag)
            let proximity = 1.0 / (1.0 + distanceFromSeedLag)
            let weightedPeak = peak * proximity
            weightedLag += candidateLag * weightedPeak
            totalWeight += weightedPeak
        }

        let refinedLag: Float = if totalWeight > 0 {
            weightedLag / totalWeight
        } else {
            seedLag
        }

        return AutocorrelationFFT.lagToBpm(refinedLag, hopsPerSec: hopsPerSec)
    }
}
