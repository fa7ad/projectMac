import Accelerate
import Foundation

/// Bass/mid/treble band-split via FFT, mirroring `BeatDetector`'s fixed-block
/// accumulation shape but reducing to three band-energy scalars. Runs on
/// `SceneReducer`'s background queue, not the render thread — vDSP's FFT is fast enough
/// either way, but this is new/unproven code so it stays off the hot path regardless.
final class AudioBandAnalyzer {
    private let windowSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    let sampleRate: Double
    private let hannWindow: [Float]

    private var accum: [Float] = []

    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var treble: Float = 0

    /// `sampleRate` is the tap's real rate (`AudioFeed.sampleRate`): band edges are in Hz.
    /// `windowSize` 2048 is ~43-46ms at 44.1-48kHz.
    init(sampleRate: Double, windowSize: Int = 2048) {
        self.sampleRate = sampleRate
        self.windowSize = windowSize
        self.log2n = vDSP_Length(log2(Double(windowSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
        accum.reserveCapacity(windowSize)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Downmixes to mono, then windows in non-overlapping chunks of `windowSize`.
    func push(interleavedStereo: [Float]) {
        var i = 0
        while i < interleavedStereo.count {
            let l = interleavedStereo[i]
            let r = i + 1 < interleavedStereo.count ? interleavedStereo[i + 1] : l
            accum.append((l + r) * 0.5)
            i += 2
            if accum.count >= windowSize {
                analyze(Array(accum.prefix(windowSize)))
                accum.removeAll(keepingCapacity: true)
            }
        }
    }

    private func analyze(_ samples: [Float]) {
        var windowed = [Float](repeating: 0, count: windowSize)
        vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(windowSize))

        var real = [Float](repeating: 0, count: windowSize / 2)
        var imag = [Float](repeating: 0, count: windowSize / 2)
        var magnitudes = [Float](repeating: 0, count: windowSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: windowSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(windowSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(windowSize / 2))
            }
        }

        let binHz = sampleRate / Double(windowSize)
        func bandEnergy(_ lowHz: Double, _ highHz: Double) -> Float {
            let lowBin = max(1, Int(lowHz / binHz))
            let highBin = min(magnitudes.count - 1, Int(highHz / binHz))
            guard lowBin <= highBin else { return 0 }
            var sum: Float = 0
            for bin in lowBin...highBin { sum += magnitudes[bin] }
            return sum / Float(highBin - lowBin + 1)
        }

        // Rough calibration — tune against real material rather than deriving it.
        let gain: Float = 0.05
        bass = min(1, bandEnergy(20, 250) * gain)
        mid = min(1, bandEnergy(250, 4000) * gain)
        treble = min(1, bandEnergy(4000, sampleRate / 2) * gain)
    }
}
