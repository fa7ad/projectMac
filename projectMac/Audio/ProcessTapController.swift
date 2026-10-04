// SPDX-License-Identifier: MIT
// Written from Apple's public process-tap API, informed by patterns common to public
// reference implementations including pantafive/fader (MIT).

import AudioToolbox
import Foundation
import Synchronization
import os

/// Captures one app family's audio output via a CoreAudio process tap into an `AudioFeed`.
///
/// Mute behavior is `.unmuted`, so the tapped app keeps playing normally; the wrapping
/// aggregate device exists only to give the tap's IOProc a clock source.
///
/// `activate()`/`invalidate()` are main-thread only.
final class ProcessTapController {
    let app: AudioApp
    /// The device the aggregate is clocked by, captured at activation. Once the default
    /// output device moves off it, `AppCoordinator` rebuilds the tap.
    private(set) var clockDeviceUID: String?
    /// Reports a tap that activated cleanly but is not delivering audio. Main thread.
    var onFailure: ((String) -> Void)?

    private let logger: Logger
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)
    private let audioFeed: AudioFeed

    private var resources = TapResources()
    private var activated = false
    private var deliveryCheck: DispatchWorkItem?

    /// Generation guard: the IOProc captures its own ID and compares on each call, so one
    /// still firing during async teardown zeroes output rather than writing into a feed a
    /// newly-activated tap may already own.
    private let callbackID = Atomic<UInt32>(0)
    private var nextCallbackID: UInt32 = 0

    /// Liveness counters for `reportDeliveryFailure`. The validated tap format promises a
    /// stereo float32 buffer, but not where the aggregate places it in the input list, so
    /// the callback's choice is still checked at runtime — loudly, since a miss means
    /// silence rather than a crash.
    private let callbackCount = Atomic<Int>(0)
    private let unusableCallbackCount = Atomic<Int>(0)
    private let lastInputBufferCount = Atomic<Int>(0)
    private let lastTapBufferChannels = Atomic<Int>(0)

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

        try validateTapFormat(tapID)

        guard let clockDeviceUID = try? AudioObjectID.defaultOutputDevice().readDeviceUID() else {
            resources.destroy()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not read default output device UID"])
        }
        self.clockDeviceUID = clockDeviceUID

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
        logger.info("Tap activated for \(self.app.name, privacy: .public) over \(self.app.processObjectIDs.count) process object(s)")

        // On main: the check reads nothing but atomics, and `onFailure` lands where the
        // UI can use it without a second hop.
        let check = DispatchWorkItem { [weak self] in
            self?.reportDeliveryFailure(for: activateCallbackID)
        }
        deliveryCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: check)
    }

    /// The tap's format is fixed once it exists, so an unusable one fails activation here
    /// rather than turning into a callback that quietly writes nothing.
    private func validateTapFormat(_ tapID: AudioObjectID) throws {
        guard let asbd = try? tapID.readTapStreamBasicDescription() else {
            // Not fatal: `reportDeliveryFailure` still catches a tap that delivers nothing.
            logger.warning("Could not read tap stream format, proceeding on the callback's own checks")
            return
        }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat, isInterleaved,
              asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame == 2 else {
            let actual = "\(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)-bit \(Int(asbd.mSampleRate))Hz flags=0x\(String(asbd.mFormatFlags, radix: 16))"
            resources.destroy()
            throw NSError(domain: "ProcessTapController", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Tap for \(app.name) has an unsupported format (\(actual)); expected interleaved stereo float32"
            ])
        }
        logger.debug("Tap format: 2ch float32 \(Int(asbd.mSampleRate), privacy: .public)Hz")
        audioFeed.sampleRate = asbd.mSampleRate
    }

    /// Runs on the main thread once, a second after activation: a tap that is running but
    /// feeding nothing is indistinguishable from silence, so say so instead of rendering a
    /// still frame.
    private func reportDeliveryFailure(for generation: UInt32) {
        guard callbackID.load(ordering: .acquiring) == generation else { return }

        let callbacks = callbackCount.load(ordering: .relaxed)
        let unusable = unusableCallbackCount.load(ordering: .relaxed)
        let message: String
        if callbacks == 0 {
            message = "No audio from \(app.name): the tap started but never delivered a buffer"
        } else if unusable == callbacks {
            let buffers = lastInputBufferCount.load(ordering: .relaxed)
            let channels = lastTapBufferChannels.load(ordering: .relaxed)
            message = "No audio from \(app.name): unexpected tap buffer layout (\(buffers) input buffers, \(channels) channels)"
        } else {
            logger.debug("Tap delivering: \(callbacks, privacy: .public) callbacks, \(unusable, privacy: .public) unusable")
            return
        }

        logger.error("\(message, privacy: .public)")
        onFailure?(message)
    }

    /// Safe to call multiple times, subsequent calls are no-ops.
    func invalidate() {
        guard activated else { return }
        activated = false
        deliveryCheck?.cancel()
        deliveryCheck = nil
        callbackID.store(0, ordering: .releasing)
        resources.destroyAsync()
        logger.info("Tap invalidated for \(self.app.name, privacy: .public)")
    }

    deinit {
        deliveryCheck?.cancel()
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

        callbackCount.wrappingAdd(1, ordering: .relaxed)
        var wroteSamples = false

        for (index, inputBuffer) in inputBuffers.enumerated() {
            guard let inputData = inputBuffer.mData else { continue }
            let channels = Int(inputBuffer.mNumberChannels)
            let byteSize = Int(inputBuffer.mDataByteSize)
            let sampleCount = byteSize / MemoryLayout<Float>.size

            // Only the last buffer is the tap's audio; the earlier ones are the
            // aggregate's sub-devices (just the clock source) and carry silence.
            if index == inputBuffers.count - 1 {
                lastTapBufferChannels.store(channels, ordering: .relaxed)
                if channels == 2 {
                    let samples = inputData.assumingMemoryBound(to: Float.self)
                    feed.write(samples: samples, sampleCount: sampleCount)
                    wroteSamples = true
                }
            }

            guard index < outputBuffers.count, let outputData = outputBuffers[index].mData else { continue }
            let outputByteSize = Int(outputBuffers[index].mDataByteSize)
            let copyLength = min(byteSize, outputByteSize)
            memcpy(outputData, inputData, copyLength)
            if copyLength < outputByteSize {
                memset(outputData.advanced(by: copyLength), 0, outputByteSize - copyLength)
            }
        }

        lastInputBufferCount.store(inputBuffers.count, ordering: .relaxed)
        if !wroteSamples {
            unusableCallbackCount.wrappingAdd(1, ordering: .relaxed)
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
