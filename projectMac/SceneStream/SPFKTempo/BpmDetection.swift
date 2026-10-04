// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

/// Core BPM detection engine using multi-band spectral flux and autocorrelation.
///
/// Decomposes mono audio into three frequency bands (low, mid, high), computes
/// onset strength via positive spectral flux, then runs FFT-based autocorrelation
/// and comb-filter scoring to identify the dominant periodicity. A harmonic
/// template matcher reduces octave errors (e.g. 120 vs 60 BPM).
///
/// Supports both batch and streaming usage:
/// - **Batch**: Call ``estimateTempoOfSamples(_:count:)`` with a complete audio buffer.
/// - **Streaming**: Feed chunks via ``process(_:count:)``, then call ``estimateTempo()``
///   when ready for a result.
///
/// For file-level analysis with consensus voting and early exit, use ``BpmAnalysis`` instead.
public final class BpmDetection {
    /// The current detection options. Can be modified between calls.
    public var options: BpmDetectionOptions

    /// The sample rate of the input audio signal in Hz.
    let inputSampleRate: Float

    /// FFT analysis frame size in samples. Fixed at 2048 for frequency resolution.
    let blockSize: Int

    /// Hop size between successive analysis frames, derived from blockSize / quality.
    /// Smaller values increase overlap and accuracy at the cost of speed.
    let stepSize: Int

    /// Filterbank extracting spectral energy in the low frequency band (0–550 Hz).
    /// Captures kick drum and bass content.
    let lowFrequencyFilterbank: FourierFilterbank

    /// Filterbank extracting spectral energy in the mid frequency band (550–4000 Hz).
    /// Captures snare, vocals, and harmonic content.
    let midFrequencyFilterbank: FourierFilterbank

    /// Filterbank extracting spectral energy in the high frequency band (4–16 kHz).
    /// Captures hi-hats, cymbals, and transient content.
    let highFrequencyFilterbank: FourierFilterbank

    /// FFT-based autocorrelation engine used to find periodic peaks in onset signals.
    let autocorrelation = AutocorrelationFFT()

    /// Accumulated spectral flux values for the low frequency band across all analyzed frames.
    var lowFrequencyFlux: [Float] = []

    /// Accumulated spectral flux values for the mid frequency band across all analyzed frames.
    var midFrequencyFlux: [Float] = []

    /// Accumulated spectral flux values for the high frequency band across all analyzed frames.
    var highFrequencyFlux: [Float] = []

    /// RMS energy envelope computed per analysis block, used as a broadband onset signal.
    var blockRmsEnvelope: [Float] = []

    /// BPM candidates collected from each `estimateTempo()` call for final consensus.
    var _tempoCandidates: [Double] = []

    /// Scratch buffer for accumulating incoming audio samples into full analysis blocks.
    var inputBlock: [Float]

    /// Buffer holding leftover samples that didn't fill a complete step in the previous call.
    var pendingStepSamples: [Float]

    /// Number of valid samples currently stored in `pendingStepSamples`.
    var pendingStepFillCount = 0

    /// Previous frame's magnitude spectrum for the low frequency band (used to compute flux).
    var lowFrequencyPreviousSpectrum: [Float]

    /// Previous frame's magnitude spectrum for the mid frequency band (used to compute flux).
    var midFrequencyPreviousSpectrum: [Float]

    /// Previous frame's magnitude spectrum for the high frequency band (used to compute flux).
    var highFrequencyPreviousSpectrum: [Float]

    /// Current frame's magnitude spectrum for the low frequency band.
    var lowFrequencySpectrum: [Float]

    /// Current frame's magnitude spectrum for the mid frequency band.
    var midFrequencySpectrum: [Float]

    /// Current frame's magnitude spectrum for the high frequency band.
    var highFrequencySpectrum: [Float]

    /// Scratch buffer for the weighted sum of per-band autocorrelation results.
    var autocorrelationBuffer: [Float] = []

    /// Temporary buffer used internally by the autocorrelation engine.
    var autocorrelationScratch: [Float] = []

    /// Scratch buffer for comb filter scoring of tempo candidates.
    var combFilterBuffer: [Float] = []

    /// Scratch buffer for harmonic template matching scores at each candidate lag.
    var templateScores: [Float] = []

    /// Creates a BPM detection engine for audio at the given sample rate.
    ///
    /// - Parameters:
    ///   - sampleRate: The sample rate of the input audio in Hz.
    ///   - options: Detection algorithm options.
    public init(sampleRate: Float, options: BpmDetectionOptions = .init()) {
        self.options = options
        inputSampleRate = sampleRate

        let lfMin: Float = 0
        let lfMax: Float = 550
        let mfMin: Float = 550
        let mfMax: Float = 4000
        let hfMin: Float = 4000
        let hfMax: Float = 16000
        let lfBinMax = 6

        blockSize = Int((inputSampleRate * Float(lfBinMax)) / lfMax)
        stepSize = max(1, blockSize / options.quality.rawValue)

        lowFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: lfMin, maxFreq: lfMax, windowed: true
        )
        midFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: mfMin, maxFreq: mfMax, windowed: true
        )
        highFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: hfMin, maxFreq: hfMax, windowed: true
        )

        inputBlock = Array(repeating: 0, count: blockSize)
        pendingStepSamples = Array(repeating: 0, count: stepSize)

        lowFrequencyPreviousSpectrum = Array(repeating: 0, count: lowFrequencyFilterbank.outputBinCount)
        midFrequencyPreviousSpectrum = Array(repeating: 0, count: midFrequencyFilterbank.outputBinCount)
        highFrequencyPreviousSpectrum = Array(repeating: 0, count: highFrequencyFilterbank.outputBinCount)
        lowFrequencySpectrum = Array(repeating: 0, count: lowFrequencyFilterbank.outputBinCount)
        midFrequencySpectrum = Array(repeating: 0, count: midFrequencyFilterbank.outputBinCount)
        highFrequencySpectrum = Array(repeating: 0, count: highFrequencyFilterbank.outputBinCount)
    }

    /// Processes a buffer of audio samples and returns the estimated tempo.
    ///
    /// This is a batch convenience method — it processes all samples at once and
    /// returns the result. For streaming usage, call ``process(_:count:)`` followed
    /// by ``estimateTempo()`` separately.
    ///
    /// - Parameters:
    ///   - samples: Pointer to mono Float32 audio samples.
    ///   - count: Number of samples in the buffer.
    /// - Returns: The estimated tempo in BPM, or 0 if detection failed.
    public func estimateTempoOfSamples(_ samples: UnsafePointer<Float>, count: Int) -> Double {
        let buf = UnsafeBufferPointer(start: samples, count: count)
        return estimateTempoOfSamples(buf)
    }

    /// Feeds audio samples into the detection engine for later tempo estimation.
    ///
    /// Call this repeatedly with sequential audio chunks, then call ``estimateTempo()``
    /// to retrieve the result. Handles partial blocks internally.
    ///
    /// - Parameters:
    ///   - samples: Pointer to mono Float32 audio samples.
    ///   - count: Number of samples in the buffer.
    public func process(_ samples: UnsafePointer<Float>, count: Int) {
        let buf = UnsafeBufferPointer(start: samples, count: count)
        process(buf)
    }

    /// Processes a buffer of audio samples and returns the estimated tempo.
    ///
    /// Array convenience overload of ``estimateTempoOfSamples(_:count:)``.
    public func estimateTempoOfSamples(_ samples: [Float]) -> Double {
        samples.withUnsafeBufferPointer { estimateTempoOfSamples($0) }
    }

    /// Feeds audio samples into the detection engine for later tempo estimation.
    ///
    /// Array convenience overload of ``process(_:count:)``.
    public func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// Returns the estimated tempo from all audio processed so far.
    ///
    /// Flushes any buffered partial block, then runs the full autocorrelation,
    /// comb-filter, and harmonic-template scoring pipeline. The top candidate
    /// BPM values are available via ``tempoCandidates`` after this call.
    ///
    /// - Returns: The estimated tempo in BPM, or 0 if detection failed.
    public func estimateTempo() -> Double {
        if pendingStepFillCount > 0 {
            let hole = blockSize - stepSize
            for i in 0 ..< pendingStepFillCount {
                inputBlock[hole + i] = pendingStepSamples[i]
            }
            for i in pendingStepFillCount ..< stepSize {
                inputBlock[hole + i] = 0
            }
            pendingStepFillCount = 0
            processInputBlock()
        }
        return finish()
    }

    /// The ranked BPM candidates from the most recent ``estimateTempo()`` call.
    ///
    /// The first element is the top candidate (same value returned by `estimateTempo()`).
    /// Subsequent entries are alternative candidates in descending score order.
    public var tempoCandidates: [Double] { _tempoCandidates }

    /// Clears all accumulated onset data, tempo candidates, and internal buffers.
    ///
    /// Call this to reuse the engine for a different audio signal without
    /// reallocating the DSP resources.
    public func reset() {
        lowFrequencyFlux.removeAll(keepingCapacity: true)
        midFrequencyFlux.removeAll(keepingCapacity: true)
        highFrequencyFlux.removeAll(keepingCapacity: true)
        blockRmsEnvelope.removeAll(keepingCapacity: true)
        _tempoCandidates.removeAll(keepingCapacity: true)
        pendingStepFillCount = 0

        lowFrequencyPreviousSpectrum = Array(repeating: 0, count: lowFrequencyPreviousSpectrum.count)
        midFrequencyPreviousSpectrum = Array(repeating: 0, count: midFrequencyPreviousSpectrum.count)
        highFrequencyPreviousSpectrum = Array(repeating: 0, count: highFrequencyPreviousSpectrum.count)
    }
}
