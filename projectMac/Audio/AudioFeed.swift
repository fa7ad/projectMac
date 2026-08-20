import Foundation
import Synchronization

/// Lock-free SPSC ring buffer bridging the CoreAudio HAL I/O thread (producer, `write`)
/// to the CVDisplayLink render thread (consumer, `drainInto`).
///
/// Each side writes only its own index: loads that one relaxed, the peer's with acquire,
/// and publishes its own with release, so the samples an index exposes are visible before
/// the index is. Indices grow monotonically, reduced mod `capacity` only at buffer access.
/// `@unchecked` is for the raw pointers alone; all mutable state is atomic.
final class AudioFeed: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>

    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    // Overlay diagnostics: they order nothing else, hence relaxed. `Float` isn't
    // `AtomicRepresentable`, hence the bit pattern.
    private let peakLevelBits = Atomic<UInt32>(0)
    private let overflowCount = Atomic<Int>(0)

    /// `capacityFrames` stereo frames (2 floats/frame). Default ~93ms at 44.1kHz.
    init(capacityFrames: Int = 4096) {
        capacity = capacityFrames * 2
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        scratch = .allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
        scratch.deallocate()
    }

    /// HAL I/O thread. Interleaved stereo float PCM, `sampleCount` = frames * 2. Drops
    /// samples on overflow rather than blocking.
    func write(samples: UnsafePointer<Float>, sampleCount: Int) {
        let write = writeIndex.load(ordering: .relaxed)
        let used = write - readIndex.load(ordering: .acquiring)
        let free = capacity - used
        let count = min(sampleCount, free)
        guard count > 0 else {
            if sampleCount > 0 { overflowCount.wrappingAdd(1, ordering: .relaxed) }
            return
        }

        var peak: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            buffer[(write + i) % capacity] = sample
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        raisePeakLevel(to: peak)
        writeIndex.store(write + count, ordering: .releasing)

        if count < sampleCount {
            overflowCount.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Peak magnitude since the previous call, which it resets.
    func consumePeakLevel() -> Float {
        Float(bitPattern: peakLevelBits.exchange(0, ordering: .relaxed))
    }

    /// CAS rather than a store: the consumer can reset the peak concurrently.
    private func raisePeakLevel(to peak: Float) {
        var current = peakLevelBits.load(ordering: .relaxed)
        while peak > Float(bitPattern: current) {
            let (exchanged, original) = peakLevelBits.compareExchange(
                expected: current,
                desired: peak.bitPattern,
                ordering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }

    /// Cumulative count of `write` calls that dropped samples because the buffer was full.
    var totalOverflowCount: Int { overflowCount.load(ordering: .relaxed) }

    /// Queued stereo frames. Diagnostic only — the indices are read separately, so the
    /// difference can be a frame or two stale.
    var backlogFrames: Int {
        (writeIndex.load(ordering: .relaxed) - readIndex.load(ordering: .relaxed)) / 2
    }
    var capacityFrames: Int { capacity / 2 }

    /// Render thread, once per frame. Drains up to `projectm_pcm_get_max_samples()`.
    func drainInto(pm: projectm_handle) {
        let maxFrames = Int(projectm_pcm_get_max_samples())
        let maxSamples = min(maxFrames * 2, capacity)

        let read = readIndex.load(ordering: .relaxed)
        let available = writeIndex.load(ordering: .acquiring) - read
        guard available > 0 else { return }

        let count = min(available, maxSamples)
        for i in 0..<count {
            scratch[i] = buffer[(read + i) % capacity]
        }
        readIndex.store(read + count, ordering: .releasing)

        projectm_pcm_add_float(pm, scratch, UInt32(count / 2), PROJECTM_STEREO)
    }
}
