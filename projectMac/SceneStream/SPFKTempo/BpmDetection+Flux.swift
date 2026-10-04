// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

extension BpmDetection {
    @inline(__always)
    private func reserveForIncomingSamples(_ nsamples: Int) {
        let estimatedFrames = max(0, nsamples / max(stepSize, 1))
        if estimatedFrames > 0 {
            lowFrequencyFlux.reserveCapacity(lowFrequencyFlux.count + estimatedFrames)
            midFrequencyFlux.reserveCapacity(midFrequencyFlux.count + estimatedFrames)
            highFrequencyFlux.reserveCapacity(highFrequencyFlux.count + estimatedFrames)
            blockRmsEnvelope.reserveCapacity(blockRmsEnvelope.count + estimatedFrames)
        }
    }

    @inline(__always)
    private func positiveSpectralFlux(_ current: [Float], _ previous: [Float]) -> Float {
        // Compressed positive flux is more onset-focused and less noisy than raw power diff.
        let compression = max(0.0001, Tuning.fluxCompression)
        var total: Float = 0
        for i in 0 ..< current.count {
            let c = log1p(current[i] * compression)
            let p = log1p(previous[i] * compression)
            let d = c - p
            if d > 0 { total += d }
        }
        return total
    }

    func processInputBlock() {
        var blockEnergy: Float = 0
        for sample in inputBlock {
            blockEnergy += sample * sample
        }
        blockRmsEnvelope.append(sqrt(blockEnergy / Float(blockSize)))

        inputBlock.withUnsafeBufferPointer { inBuf in
            lowFrequencySpectrum.withUnsafeMutableBufferPointer { outBuf in
                lowFrequencyFilterbank.forwardMagnitude(input: inBuf, output: outBuf)
            }
        }
        lowFrequencyFlux.append(positiveSpectralFlux(lowFrequencySpectrum, lowFrequencyPreviousSpectrum))
        lowFrequencyPreviousSpectrum = lowFrequencySpectrum

        inputBlock.withUnsafeBufferPointer { inBuf in
            midFrequencySpectrum.withUnsafeMutableBufferPointer { outBuf in
                midFrequencyFilterbank.forwardMagnitude(input: inBuf, output: outBuf)
            }
        }
        midFrequencyFlux.append(positiveSpectralFlux(midFrequencySpectrum, midFrequencyPreviousSpectrum))
        midFrequencyPreviousSpectrum = midFrequencySpectrum

        inputBlock.withUnsafeBufferPointer { inBuf in
            highFrequencySpectrum.withUnsafeMutableBufferPointer { outBuf in
                highFrequencyFilterbank.forwardMagnitude(input: inBuf, output: outBuf)
            }
        }
        highFrequencyFlux.append(positiveSpectralFlux(highFrequencySpectrum, highFrequencyPreviousSpectrum))
        highFrequencyPreviousSpectrum = highFrequencySpectrum
    }

    func estimateTempoOfSamples(_ samples: UnsafeBufferPointer<Float>) -> Double {
        reserveForIncomingSamples(samples.count)

        var i = 0
        while i + blockSize <= samples.count {
            for j in 0 ..< blockSize {
                inputBlock[j] = samples[i + j]
            }
            processInputBlock()
            i += stepSize
        }

        return finish()
    }

    func process(_ samples: UnsafeBufferPointer<Float>) {
        reserveForIncomingSamples(samples.count)

        var consumedSampleCount = 0
        while consumedSampleCount < samples.count {
            let hole = blockSize - stepSize
            let remaining = samples.count - consumedSampleCount

            if pendingStepFillCount + remaining < stepSize {
                for i in 0 ..< remaining {
                    pendingStepSamples[pendingStepFillCount + i] = samples[consumedSampleCount + i]
                }
                pendingStepFillCount += remaining
                break
            }

            for i in 0 ..< pendingStepFillCount {
                inputBlock[hole + i] = pendingStepSamples[i]
            }

            let toConsume = stepSize - pendingStepFillCount
            for i in 0 ..< toConsume {
                inputBlock[hole + pendingStepFillCount + i] = samples[consumedSampleCount + i]
            }

            consumedSampleCount += toConsume
            pendingStepFillCount = 0

            processInputBlock()

            for i in 0 ..< hole {
                inputBlock[i] = inputBlock[i + stepSize]
            }
        }
    }

    /// Subtract a local moving average from the flux signal and half-wave rectify,
    /// producing a normalized onset function that is less sensitive to overall loudness.
    /// The window spans approximately 3 seconds of analysis frames.
    func normalizeFlux(_ flux: [Float]) -> [Float] {
        let count = flux.count
        guard count > 0 else { return flux }
        let hopsPerSec = inputSampleRate / Float(stepSize)
        let halfWindow = max(4, Int(hopsPerSec * 1.5))
        var normalized = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let windowStart = max(0, i - halfWindow)
            let windowEnd = min(count, i + halfWindow + 1)
            var sum: Float = 0
            for j in windowStart ..< windowEnd {
                sum += flux[j]
            }
            let localMean = sum / Float(windowEnd - windowStart)
            let diff = flux[i] - localMean
            normalized[i] = diff > 0 ? diff : 0
        }
        return normalized
    }
}
