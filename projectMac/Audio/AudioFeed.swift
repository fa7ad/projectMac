import Foundation

/// Lock-free single-producer/single-consumer ring buffer bridging the CoreAudio HAL I/O
/// thread (producer, `write`) to the CVDisplayLink render thread (consumer, `drainInto`).
///
/// Only `writeIndex` is written by the producer and only `readIndex` is written by the
/// consumer; each side only reads the other's index. Aligned Int loads/stores are atomic
/// on Apple ARM64/x86-64, so no lock is needed. Indices grow monotonically and are only
/// reduced mod `capacity` at buffer access, avoiding the full/empty ambiguity of a plain
/// wrapping index scheme.
final class AudioFeed: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>

    private nonisolated(unsafe) var writeIndex: Int = 0
    private nonisolated(unsafe) var readIndex: Int = 0

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

    /// Called from the HAL I/O thread. `samples` is interleaved stereo float PCM;
    /// `sampleCount` is the total float count (frameCount * 2). Drops samples on overflow
    /// rather than blocking, visual latency from a full buffer isn't worth an RT stall.
    func write(samples: UnsafePointer<Float>, sampleCount: Int) {
        let write = writeIndex
        let used = write - readIndex
        let free = capacity - used
        let count = min(sampleCount, free)
        guard count > 0 else { return }

        for i in 0..<count {
            buffer[(write + i) % capacity] = samples[i]
        }
        writeIndex = write + count
    }

    /// Called from the render thread, once per frame. Drains up to
    /// `projectm_pcm_get_max_samples()` stereo frames into projectM.
    func drainInto(pm: projectm_handle) {
        let maxFrames = Int(projectm_pcm_get_max_samples())
        let maxSamples = min(maxFrames * 2, capacity)

        let read = readIndex
        let available = writeIndex - read
        guard available > 0 else { return }

        let count = min(available, maxSamples)
        for i in 0..<count {
            scratch[i] = buffer[(read + i) % capacity]
        }
        readIndex = read + count

        projectm_pcm_add_float(pm, scratch, UInt32(count / 2), PROJECTM_STEREO)
    }
}
