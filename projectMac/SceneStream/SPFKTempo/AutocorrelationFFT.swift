// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Accelerate
import Foundation

final class AutocorrelationFFT {
    private var fftSetup: FFTSetup?
    private var fftLength: Int = 0
    private var fftLog2Length: vDSP_Length = 0

    private var realPartBuffer: [Float] = []
    private var imaginaryPartBuffer: [Float] = []

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    @inline(__always)
    private func nextPowerOfTwo(_ value: Int) -> Int {
        var powerOfTwo = 1
        while powerOfTwo < value {
            powerOfTwo <<= 1
        }
        return powerOfTwo
    }

    private func ensureCapacity(inputCount: Int) {
        let requiredLength = nextPowerOfTwo(max(2, inputCount * 2))
        if requiredLength == fftLength { return }

        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }

        fftLength = requiredLength
        fftLog2Length = vDSP_Length(Int.bitWidth - 1 - requiredLength.leadingZeroBitCount)
        fftSetup = vDSP_create_fftsetup(fftLog2Length, FFTRadix(kFFTRadix2))

        realPartBuffer = Array(repeating: 0, count: fftLength)
        imaginaryPartBuffer = Array(repeating: 0, count: fftLength)
    }

    func acfUnityNormalized(input: [Float], lagCount requestedLagCount: Int, output: inout [Float]) {
        let inputCount = input.count
        guard inputCount > 0, requestedLagCount > 0 else { return }
        ensureCapacity(inputCount: inputCount)
        guard let setup = fftSetup else { return }

        realPartBuffer.withUnsafeMutableBufferPointer { realBufferPointer in
            imaginaryPartBuffer.withUnsafeMutableBufferPointer { imaginaryBufferPointer in
                guard
                    let realPointer = realBufferPointer.baseAddress,
                    let imaginaryPointer = imaginaryBufferPointer.baseAddress
                else {
                    return
                }

                // Input signal padded to FFT length.
                for sampleIndex in 0 ..< inputCount {
                    realPointer[sampleIndex] = input[sampleIndex]
                }
                if inputCount < fftLength {
                    realPointer.advanced(by: inputCount).update(repeating: 0, count: fftLength - inputCount)
                }
                imaginaryPointer.update(repeating: 0, count: fftLength)

                var splitComplex = DSPSplitComplex(realp: realPointer, imagp: imaginaryPointer)
                vDSP_fft_zip(setup, &splitComplex, 1, fftLog2Length, FFTDirection(FFT_FORWARD))

                // Power spectrum |X|^2
                for binIndex in 0 ..< fftLength {
                    let realPart = realPointer[binIndex]
                    let imaginaryPart = imaginaryPointer[binIndex]
                    realPointer[binIndex] = realPart * realPart + imaginaryPart * imaginaryPart
                    imaginaryPointer[binIndex] = 0
                }

                // IFFT -> autocorrelation (circular). Zero-padding avoids overlap for desired lags.
                vDSP_fft_zip(setup, &splitComplex, 1, fftLog2Length, FFTDirection(FFT_INVERSE))
            }
        }

        let effectiveLagCount = min(requestedLagCount, inputCount)
        if output.count < effectiveLagCount {
            output = Array(repeating: 0, count: effectiveLagCount)
        }

        let inverseFFTLength = 1.0 / Float(fftLength)
        var maxVal: Float = 0

        for lagIndex in 0 ..< effectiveLagCount {
            let lagValue = (realPartBuffer[lagIndex] * inverseFFTLength) / Float(inputCount - lagIndex)
            output[lagIndex] = lagValue
            if lagValue > maxVal { maxVal = lagValue }
        }

        if maxVal > 0 {
            let inverseMaxValue = 1.0 / maxVal
            for lagIndex in 0 ..< effectiveLagCount {
                output[lagIndex] *= inverseMaxValue
            }
        }
    }

    @inline(__always)
    static func bpmToLag(_ bpm: Float, hopsPerSec: Float) -> Int {
        Int((60.0 / bpm) * hopsPerSec + 0.5)
    }

    @inline(__always)
    static func lagToBpm(_ lag: Float, hopsPerSec: Float) -> Float {
        (60.0 * hopsPerSec) / lag
    }
}
