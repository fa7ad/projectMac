// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

extension BpmDetection {
    /// Runs the full scoring pipeline on accumulated onset data and returns the best BPM.
    ///
    /// Computes weighted multi-band autocorrelation, applies comb-filter and harmonic
    /// template scoring, then picks the strongest peak. A confidence gate rejects
    /// results where the peak doesn't stand out from the background distribution.
    ///
    /// - Returns: The estimated tempo in BPM, or 0 if detection failed or confidence was too low.
    func finish() -> Double {
        _tempoCandidates.removeAll(keepingCapacity: true)

        let onsetFrameCount = lowFrequencyFlux.count
        if onsetFrameCount == 0 { return 0 }

        // Normalize onset flux signals to reduce loudness bias.
        let normalizedLowFlux = normalizeFlux(lowFrequencyFlux)
        let normalizedMidFlux = normalizeFlux(midFrequencyFlux)
        let normalizedHighFlux = normalizeFlux(highFrequencyFlux)

        let hopsPerSec = inputSampleRate / Float(stepSize)

        let minBPM = options.bpmRange.lowerBound
        let maxBPM = options.bpmRange.upperBound
        let barPM = minBPM / Float(4 * options.beatsPerBar)
        var acfLength = AutocorrelationFFT.bpmToLag(barPM, hopsPerSec: hopsPerSec)
        while acfLength > onsetFrameCount {
            acfLength /= 2
        }
        if acfLength <= 0 { return 0 }

        if autocorrelationBuffer.count < acfLength { autocorrelationBuffer = Array(repeating: 0, count: acfLength) }
        if autocorrelationScratch.count < acfLength { autocorrelationScratch = Array(repeating: 0, count: acfLength) }

        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] = 0
        }

        autocorrelation.acfUnityNormalized(
            input: normalizedLowFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.low
        }

        autocorrelation.acfUnityNormalized(
            input: normalizedMidFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.mid
        }

        autocorrelation.acfUnityNormalized(
            input: normalizedHighFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.high
        }

        autocorrelation.acfUnityNormalized(
            input: blockRmsEnvelope, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.rms
        }

        let minLag = AutocorrelationFFT.bpmToLag(maxBPM, hopsPerSec: hopsPerSec)
        let maxLag = AutocorrelationFFT.bpmToLag(minBPM, hopsPerSec: hopsPerSec)
        if acfLength < maxLag {
            return 0
        }

        let comb = ACFCombFilter(
            beatsPerBar: options.beatsPerBar, minLag: minLag, maxLag: maxLag, hopsPerSec: hopsPerSec
        )
        let combFilterLength = comb.filteredLength()
        if combFilterBuffer.count < combFilterLength { combFilterBuffer = Array(repeating: 0, count: combFilterLength) }
        if templateScores.count < combFilterLength { templateScores = Array(repeating: 0, count: combFilterLength) }

        comb.filter(
            autocorrelation: autocorrelationBuffer, autocorrelationLength: acfLength, filtered: &combFilterBuffer
        )
        unityNormalize(&combFilterBuffer, count: combFilterLength)

        let blend = max(0.0, min(1.0, options.perceptualWeightingAmount))
        if blend > 0 {
            let center: Float = 130
            for i in 0 ..< combFilterLength {
                let bpm = AutocorrelationFFT.lagToBpm(Float(minLag + i), hopsPerSec: hopsPerSec)
                let dev = abs(center - bpm)
                let width: Float = bpm < center ? 100 : 80
                var legacyWeight = 1.0 - pow(dev / width, 2.4)
                if legacyWeight < 0 { legacyWeight = 0 }

                // Blend legacy weighting with neutral weighting (1.0).
                let weight = 1.0 + (legacyWeight - 1.0) * blend
                combFilterBuffer[i] *= weight
            }
        }

        let templateMix = max(0.0, min(1.0, Tuning.templateBlend))
        for i in 0 ..< combFilterLength {
            let templateScore = harmonicTemplateScore(
                index: i,
                minLag: minLag,
                maxLag: maxLag,
                combResponse: combFilterBuffer,
                combResponseLength: combFilterLength
            )
            templateScores[i] = combFilterBuffer[i] * (1.0 - templateMix) + templateScore * templateMix
        }
        unityNormalize(&templateScores, count: combFilterLength)

        var peaks: [(score: Float, idx: Int)] = []
        peaks.reserveCapacity(max(8, combFilterLength / 8))

        if combFilterLength >= 3 {
            for i in 1 ..< (combFilterLength - 1) {
                if templateScores[i] > templateScores[i - 1], templateScores[i] > templateScores[i + 1] {
                    peaks.append((templateScores[i], i))
                }
            }
        }

        if peaks.isEmpty {
            return 0
        }
        peaks.sort { $0.score > $1.score }

        // Confidence gate: reject results where the best peak doesn't stand out
        // from the background score distribution. For noise-like signals the
        // template scores are nearly uniform, producing a low peak-to-median ratio.
        let confidenceThreshold = options.confidenceLevel.threshold
        if confidenceThreshold > 0 {
            let peakScore = peaks[0].score
            let sortedScores = Array(templateScores[0 ..< combFilterLength]).sorted()
            let medianScore = sortedScores[combFilterLength / 2]
            if medianScore > 0, peakScore / medianScore < confidenceThreshold {
                return 0
            }
        }

        var seen = Set<Int>()
        seen.reserveCapacity(peaks.count)

        for peak in peaks {
            let lag = peak.idx + minLag
            let coarseBPM = comb.refine(
                lag: lag, autocorrelation: autocorrelationBuffer, autocorrelationLength: acfLength
            )
            let lagGuess = (60.0 * hopsPerSec) / coarseBPM
            let refinedLag = refineFundamentalLag(
                guessLag: lagGuess,
                autocorrelationSequence: autocorrelationBuffer,
                acfLength: acfLength,
                minLag: minLag,
                maxLag: maxLag
            )
            let bpm = AutocorrelationFFT.lagToBpm(refinedLag, hopsPerSec: hopsPerSec)
            // Scale dedup quantization relative to BPM: ~1 BPM resolution at all tempos.
            let quantised = Int(Double(bpm).rounded())
            if seen.insert(quantised).inserted {
                _tempoCandidates.append(Double(bpm))
            }
        }

        return _tempoCandidates.first ?? 0
    }

    @inline(__always)
    private func harmonicTemplateScore(
        index: Int,
        minLag: Int,
        maxLag: Int,
        combResponse: [Float],
        combResponseLength: Int
    ) -> Float {
        let lag = minLag + index
        let maxAllowedLag = minLag + combResponseLength - 1
        if lag < minLag || lag > maxAllowedLag || lag > maxLag { return 0 }

        @inline(__always)
        func atLag(_ l: Int) -> Float {
            if l < minLag || l > maxAllowedLag { return 0 }
            return combResponse[l - minLag]
        }

        // Reward consistency at integer multiples of the same period (slower tempos / longer lags).
        var score = atLag(lag) * Tuning.HarmonicTemplate.weight1
        score += atLag(lag * 2) * Tuning.HarmonicTemplate.weight2
        score += atLag(lag * 3) * Tuning.HarmonicTemplate.weight3
        score += atLag(lag * 4) * Tuning.HarmonicTemplate.weight4

        // Penalize candidates whose faster harmonics (shorter lags) are strong,
        // reducing over-fast octave errors (e.g. picking 120 instead of 60).
        score -= atLag(max(1, lag / 2)) * Tuning.HarmonicTemplate.penalty2
        score -= atLag(max(1, lag / 3)) * Tuning.HarmonicTemplate.penalty3

        return max(0, score)
    }

    @inline(__always)
    private func unityNormalize(_ values: inout [Float], count: Int) {
        guard count > 0 else { return }

        var maxValue = values[0]
        var minValue = values[0]

        for i in 1 ..< count {
            let value = values[i]
            if value > maxValue { maxValue = value }
            if value < minValue { minValue = value }
        }

        if maxValue > minValue {
            let scale = 1.0 / (maxValue - minValue)
            for i in 0 ..< count {
                values[i] = (values[i] - minValue) * scale
            }
        }
    }

    @inline(__always)
    private func refineFundamentalLag(
        guessLag: Float,
        autocorrelationSequence: [Float],
        acfLength: Int,
        minLag: Int,
        maxLag: Int
    ) -> Float {
        let center = Int(guessLag.rounded())
        let searchRadius = 5
        let low = max(minLag, max(1, center - searchRadius))
        let high = min(maxLag, min(acfLength - 2, center + searchRadius))
        if low > high { return guessLag }

        var peakIndex = low
        var peak = autocorrelationSequence[low]
        if low < high {
            for i in (low + 1) ... high {
                if autocorrelationSequence[i] > peak {
                    peak = autocorrelationSequence[i]
                    peakIndex = i
                }
            }
        }

        var interpolatedPeakIndex = Float(peakIndex)
        if peakIndex > 0, peakIndex + 1 < acfLength {
            let leftValue = autocorrelationSequence[peakIndex - 1]
            let centerValue = autocorrelationSequence[peakIndex]
            let rightValue = autocorrelationSequence[peakIndex + 1]
            if centerValue > leftValue, centerValue > rightValue {
                let denominator = leftValue - 2 * centerValue + rightValue
                if denominator != 0 {
                    interpolatedPeakIndex += ((leftValue - rightValue) / denominator) / 2
                }
            }
        }
        return interpolatedPeakIndex
    }

}
