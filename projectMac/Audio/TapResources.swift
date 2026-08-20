// SPDX-License-Identifier: MIT
// Written from Apple's public process-tap API, informed by patterns common to public
// reference implementations including pantafive/fader (MIT).

import AudioToolbox
import os

/// Core Audio tap and aggregate device resources.
///
/// Teardown order is dictated by the HAL and must not change: `AudioDeviceStop`, destroy
/// the IOProc ID (blocks until the callback finishes), destroy the aggregate device, then
/// destroy the tap. Out of order leaks HAL resources or crashes on shutdown.
nonisolated struct TapResources {
    private static let logger = Logger(subsystem: "com.projectmac.app", category: "TapResources")

    var tapID: AudioObjectID = .unknown
    var aggregateDeviceID: AudioObjectID = .unknown
    var deviceProcID: AudioDeviceIOProcID?
    var tapDescription: CATapDescription?

    var isActive: Bool {
        tapID.isValid || aggregateDeviceID.isValid
    }

    /// Safe to call multiple times; invalid IDs are skipped.
    mutating func destroy() {
        let aggID = aggregateDeviceID
        let tID = tapID

        if aggID.isValid {
            if let procID = deviceProcID {
                let stopErr = AudioDeviceStop(aggID, procID)
                if stopErr != noErr {
                    Self.logger.error("AudioDeviceStop failed for aggregate \(aggID): OSStatus \(stopErr)")
                }
                let destroyProcErr = AudioDeviceDestroyIOProcID(aggID, procID)
                if destroyProcErr != noErr {
                    Self.logger.error("AudioDeviceDestroyIOProcID failed for aggregate \(aggID): OSStatus \(destroyProcErr)")
                }
            }
        }
        deviceProcID = nil

        if aggID.isValid {
            let aggErr = AudioHardwareDestroyAggregateDevice(aggID)
            if aggErr != noErr {
                Self.logger.error("AudioHardwareDestroyAggregateDevice failed for \(aggID): OSStatus \(aggErr)")
            }
        }
        aggregateDeviceID = .unknown

        if tID.isValid {
            let tapErr = AudioHardwareDestroyProcessTap(tID)
            if tapErr != noErr {
                Self.logger.error("AudioHardwareDestroyProcessTap failed for \(tID): OSStatus \(tapErr)")
            }
        }
        tapID = .unknown

        tapDescription = nil
    }

    /// Clears instance state immediately; new resources can be created without waiting.
    mutating func destroyAsync(on queue: DispatchQueue = .global(qos: .utility), completion: (@Sendable () -> Void)? = nil) {
        let capturedTapID = tapID
        let capturedAggregateID = aggregateDeviceID
        let capturedProcID = deviceProcID

        tapID = .unknown
        aggregateDeviceID = .unknown
        deviceProcID = nil
        tapDescription = nil

        queue.async {
            if capturedAggregateID.isValid, let procID = capturedProcID {
                let stopErr = AudioDeviceStop(capturedAggregateID, procID)
                if stopErr != noErr {
                    Self.logger.error("AudioDeviceStop failed for aggregate \(capturedAggregateID): OSStatus \(stopErr)")
                }
                let destroyProcErr = AudioDeviceDestroyIOProcID(capturedAggregateID, procID)
                if destroyProcErr != noErr {
                    Self.logger.error("AudioDeviceDestroyIOProcID failed for aggregate \(capturedAggregateID): OSStatus \(destroyProcErr)")
                }
            }

            if capturedAggregateID.isValid {
                let aggErr = AudioHardwareDestroyAggregateDevice(capturedAggregateID)
                if aggErr != noErr {
                    Self.logger.error("AudioHardwareDestroyAggregateDevice failed for \(capturedAggregateID): OSStatus \(aggErr)")
                }
            }

            if capturedTapID.isValid {
                let tapErr = AudioHardwareDestroyProcessTap(capturedTapID)
                if tapErr != noErr {
                    Self.logger.error("AudioHardwareDestroyProcessTap failed for \(capturedTapID): OSStatus \(tapErr)")
                }
            }

            completion?()
        }
    }
}
