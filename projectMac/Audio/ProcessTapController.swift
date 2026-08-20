// SPDX-License-Identifier: MIT
// Written from Apple's public process-tap API, informed by patterns common to public
// reference implementations including pantafive/fader (MIT).

import AudioToolbox
import Foundation
import Synchronization
import os

/// Captures one app's audio output via a CoreAudio process tap into an `AudioFeed`.
///
/// Mute behavior is `.unmuted`, so the tapped app keeps playing normally; the wrapping
/// aggregate device exists only to give the tap's IOProc a clock source.
///
/// `activate()`/`invalidate()` are main-thread only.
final class ProcessTapController {
    let app: AudioApp
    private let logger: Logger
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)
    private let audioFeed: AudioFeed

    private var resources = TapResources()
    private var activated = false

    /// Generation guard: the IOProc captures its own ID and compares on each call, so one
    /// still firing during async teardown zeroes output rather than writing into a feed a
    /// newly-activated tap may already own.
    private let callbackID = Atomic<UInt32>(0)
    private var nextCallbackID: UInt32 = 0

    // Input buffer layout, captured on the first callback (plain value writes, no
    // allocation) and logged below. Same serial queue on both ends.
    private var diagCaptured = false
    private var diagBufferCount = 0
    private var diagChannels: (Int, Int, Int, Int) = (0, 0, 0, 0)
    private var diagByteSizes: (Int, Int, Int, Int) = (0, 0, 0, 0)

    init(app: AudioApp, audioFeed: AudioFeed) {
        self.app = app
        self.audioFeed = audioFeed
        self.logger = Logger(subsystem: "com.projectmac.app", category: "ProcessTapController(\(app.name))")
    }

    func activate() throws {
        guard !activated else { return }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: app.processObjectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }
        resources.tapDescription = tapDescription
        resources.tapID = tapID

        guard let clockDeviceUID = try? AudioObjectID.defaultOutputDevice().readDeviceUID() else {
            resources.destroy()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not read default output device UID"])
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "projectMac-\(app.pid)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: clockDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: false,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var aggID: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard err == noErr else {
            resources.destroy()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(err)"])
        }
        resources.aggregateDeviceID = aggID

        guard aggID.waitUntilReady(timeout: 2.0) else {
            resources.destroy()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aggregate device not ready within timeout"])
        }

        nextCallbackID += 1
        callbackID.store(nextCallbackID, ordering: .releasing)
        let activateCallbackID = nextCallbackID
        let feed = audioFeed
        err = AudioDeviceCreateIOProcIDWithBlock(&resources.deviceProcID, aggID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self, self.callbackID.load(ordering: .acquiring) == activateCallbackID else {
                let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)
                for buf in outputs {
                    if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
                }
                return
            }
            self.processAudioCallback(inInputData, to: outOutputData, feed: feed)
        }
        guard err == noErr else {
            resources.destroy()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        err = AudioDeviceStart(aggID, resources.deviceProcID)
        guard err == noErr else {
            resources.destroy()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        activated = true
        logger.info("Tap activated for \(self.app.name, privacy: .public)")

        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let diag = self.consumeDiagnosticsIfReady() else { return }
            let shape = """
                buffers=\(diag.bufferCount) \
                channels=(\(diag.channels.0),\(diag.channels.1),\(diag.channels.2),\(diag.channels.3)) \
                byteSizes=(\(diag.byteSizes.0),\(diag.byteSizes.1),\(diag.byteSizes.2),\(diag.byteSizes.3))
                """
            // `processAudioCallback` assumes the tap's audio is the last buffer and
            // 2-channel — guaranteed by one sub-device + one stereo mixdown tap.
            let allChannels = [diag.channels.0, diag.channels.1, diag.channels.2, diag.channels.3]
            let lastChannels = (1...4).contains(diag.bufferCount) ? allChannels[diag.bufferCount - 1] : -1
            if diag.bufferCount != 2 || lastChannels != 2 {
                self.logger.warning("Tap input buffer shape is unexpected, audio capture may be broken: \(shape, privacy: .public)")
            } else {
                self.logger.debug("Tap input buffer shape: \(shape, privacy: .public)")
            }
        }
    }

    private func consumeDiagnosticsIfReady() -> (bufferCount: Int, channels: (Int, Int, Int, Int), byteSizes: (Int, Int, Int, Int))? {
        guard diagCaptured else { return nil }
        return (diagBufferCount, diagChannels, diagByteSizes)
    }

    /// Safe to call multiple times, subsequent calls are no-ops.
    func invalidate() {
        guard activated else { return }
        activated = false
        callbackID.store(0, ordering: .releasing)
        resources.destroyAsync()
        logger.info("Tap invalidated for \(self.app.name, privacy: .public)")
    }

    deinit {
        if activated {
            resources.destroyAsync()
        }
    }

    // MARK: - Audio callback, under real-time constraints
    // DO NOT: allocate, lock, use ObjC, log, or perform file/network I/O in here.

    nonisolated private func processAudioCallback(
        _ inputBufferList: UnsafePointer<AudioBufferList>,
        to outputBufferList: UnsafeMutablePointer<AudioBufferList>,
        feed: AudioFeed
    ) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        // SAFETY: mutable cast required by the API; we only read through this pointer.
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        if !diagCaptured {
            var channels = (0, 0, 0, 0)
            var byteSizes = (0, 0, 0, 0)
            for (index, buf) in inputBuffers.enumerated() where index < 4 {
                switch index {
                case 0: channels.0 = Int(buf.mNumberChannels); byteSizes.0 = Int(buf.mDataByteSize)
                case 1: channels.1 = Int(buf.mNumberChannels); byteSizes.1 = Int(buf.mDataByteSize)
                case 2: channels.2 = Int(buf.mNumberChannels); byteSizes.2 = Int(buf.mDataByteSize)
                case 3: channels.3 = Int(buf.mNumberChannels); byteSizes.3 = Int(buf.mDataByteSize)
                default: break
                }
            }
            diagBufferCount = inputBuffers.count
            diagChannels = channels
            diagByteSizes = byteSizes
            diagCaptured = true
        }

        for (index, inputBuffer) in inputBuffers.enumerated() {
            guard let inputData = inputBuffer.mData else { continue }
            let channels = Int(inputBuffer.mNumberChannels)
            let byteSize = Int(inputBuffer.mDataByteSize)
            let sampleCount = byteSize / MemoryLayout<Float>.size

            // Only the last buffer is the tap's audio; the earlier ones are the
            // aggregate's sub-devices (just the clock source) and carry silence.
            if index == inputBuffers.count - 1, channels == 2 {
                let samples = inputData.assumingMemoryBound(to: Float.self)
                feed.write(samples: samples, sampleCount: sampleCount)
            }

            guard index < outputBuffers.count, let outputData = outputBuffers[index].mData else { continue }
            let outputByteSize = Int(outputBuffers[index].mDataByteSize)
            let copyLength = min(byteSize, outputByteSize)
            memcpy(outputData, inputData, copyLength)
            if copyLength < outputByteSize {
                memset(outputData.advanced(by: copyLength), 0, outputByteSize - copyLength)
            }
        }

        if outputBuffers.count > inputBuffers.count {
            for index in inputBuffers.count..<outputBuffers.count {
                if let data = outputBuffers[index].mData {
                    memset(data, 0, Int(outputBuffers[index].mDataByteSize))
                }
            }
        }
    }
}
