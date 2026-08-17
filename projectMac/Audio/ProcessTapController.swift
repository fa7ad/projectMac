// SPDX-License-Identifier: MIT
// Written from Apple's public process-tap API, informed by patterns common to public
// reference implementations including pantafive/fader (MIT).

import AudioToolbox
import Foundation
import os

/// Captures one app's audio output via a CoreAudio process tap and feeds it into an
/// `AudioFeed` ring buffer for visualization.
///
/// The tap's mute behavior is `.unmuted`, so the tapped app keeps playing through its own
/// normal output path untouched. The wrapping aggregate device exists only to give the
/// tap's IOProc a clock source.
///
/// Call `activate()`/`invalidate()` from the main thread only. The audio callback itself
/// runs on CoreAudio's real-time HAL I/O thread; see the RT-safety notes on
/// `processAudioCallback`.
final class ProcessTapController {
    let app: AudioApp
    private let logger: Logger
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)
    private let audioFeed: AudioFeed

    private var resources = TapResources()
    private var activated = false

    /// RT-safe generation guard: the IOProc closure captures its own callbackID at
    /// creation and compares against this on every invocation, so a stale callback
    /// firing during/after invalidate() (async teardown) zeroes output instead of
    /// writing into a feed that may be getting reused by a newly-activated tap.
    private nonisolated(unsafe) var callbackID: UInt32 = 0
    private var nextCallbackID: UInt32 = 0

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
        callbackID = nextCallbackID
        let activateCallbackID = nextCallbackID
        let feed = audioFeed
        err = AudioDeviceCreateIOProcIDWithBlock(&resources.deviceProcID, aggID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self, self.callbackID == activateCallbackID else {
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
    }

    /// Safe to call multiple times, subsequent calls are no-ops.
    func invalidate() {
        guard activated else { return }
        activated = false
        callbackID = 0
        resources.destroyAsync()
        logger.info("Tap invalidated for \(self.app.name, privacy: .public)")
    }

    deinit {
        if activated {
            resources.destroyAsync()
        }
    }

    // MARK: - RT-Safe Audio Callback (runs on CoreAudio's real-time HAL I/O thread)
    // DO NOT: allocate, lock, use ObjC, log, or perform file/network I/O in here.

    nonisolated private func processAudioCallback(
        _ inputBufferList: UnsafePointer<AudioBufferList>,
        to outputBufferList: UnsafeMutablePointer<AudioBufferList>,
        feed: AudioFeed
    ) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        // SAFETY: mutable cast required by the API; we only read through this pointer.
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        for (index, inputBuffer) in inputBuffers.enumerated() {
            guard let inputData = inputBuffer.mData else { continue }
            let channels = Int(inputBuffer.mNumberChannels)
            let byteSize = Int(inputBuffer.mDataByteSize)
            let sampleCount = byteSize / MemoryLayout<Float>.size

            if channels == 2 {
                let samples = inputData.assumingMemoryBound(to: Float.self)
                feed.write(samples: samples, sampleCount: sampleCount)
            }

            // Pass-through: mirror input into the matching output buffer so the
            // aggregate's own output stream isn't left with undefined memory.
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
