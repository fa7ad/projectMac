// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Accelerate
import Foundation

final class FourierFilterbank {
    let frameSize: Int
    let outputBinCount: Int

    private let sineTable: [Float] // flattened [bin * frameSize + sampleIndex]
    private let cosineTable: [Float] // flattened [bin * frameSize + sampleIndex]

    private var realProjectionScratch: [Float]
    private var imaginaryProjectionScratch: [Float]

    init(n: Int, fs: Float, minFreq: Float, maxFreq: Float, windowed: Bool) {
        frameSize = n

        let minimumBin = Int(floor((Float(n) * minFreq) / fs))
        let maximumBin = Int(ceil((Float(n) * maxFreq) / fs))
        outputBinCount = maximumBin - minimumBin + 1

        var sineTable = Array(repeating: Float(0), count: outputBinCount * n)
        var cosineTable = Array(repeating: Float(0), count: outputBinCount * n)

        let twoPi = Float.pi * 2
        for outputBinIndex in 0 ..< outputBinCount {
            let bin = outputBinIndex + minimumBin
            let binPhaseDelta = twoPi * Float(bin) / Float(n)
            let rowOffset = outputBinIndex * n

            for sampleIndex in 0 ..< n {
                let angle = Float(sampleIndex) * binPhaseDelta
                let windowValue: Float = windowed ? (0.5 - 0.5 * cos(twoPi * Float(sampleIndex) / Float(n))) : 1
                sineTable[rowOffset + sampleIndex] = sin(angle) * windowValue
                cosineTable[rowOffset + sampleIndex] = cos(angle) * windowValue
            }
        }

        self.sineTable = sineTable
        self.cosineTable = cosineTable
        realProjectionScratch = Array(repeating: 0, count: outputBinCount)
        imaginaryProjectionScratch = Array(repeating: 0, count: outputBinCount)
    }

    func forwardMagnitude(input: UnsafeBufferPointer<Float>, output: UnsafeMutableBufferPointer<Float>) {
        precondition(input.count >= frameSize && output.count >= outputBinCount)

        cosineTable.withUnsafeBufferPointer { cosineTablePointer in
            sineTable.withUnsafeBufferPointer { sineTablePointer in
                realProjectionScratch.withUnsafeMutableBufferPointer { realProjectionPointer in
                    imaginaryProjectionScratch.withUnsafeMutableBufferPointer { imaginaryProjectionPointer in
                        guard
                            let cosineBase = cosineTablePointer.baseAddress,
                            let sineBase = sineTablePointer.baseAddress,
                            let inputBase = input.baseAddress,
                            let realBase = realProjectionPointer.baseAddress,
                            let imaginaryBase = imaginaryProjectionPointer.baseAddress
                        else {
                            return
                        }

                        // Matrix-vector multiply using vDSP (A[outputBinCount x frameSize] * x[frameSize x 1]).
                        vDSP_mmul(
                            cosineBase, 1,
                            inputBase, 1,
                            realBase, 1,
                            vDSP_Length(outputBinCount), 1, vDSP_Length(frameSize)
                        )

                        vDSP_mmul(
                            sineBase, 1,
                            inputBase, 1,
                            imaginaryBase, 1,
                            vDSP_Length(outputBinCount), 1, vDSP_Length(frameSize)
                        )

                        for outputBinIndex in 0 ..< outputBinCount {
                            let realProjection = realProjectionPointer[outputBinIndex]
                            let imaginaryProjection = imaginaryProjectionPointer[outputBinIndex]
                            output[outputBinIndex] = sqrt(
                                realProjection * realProjection + imaginaryProjection * imaginaryProjection)
                        }
                    }
                }
            }
        }
    }
}
