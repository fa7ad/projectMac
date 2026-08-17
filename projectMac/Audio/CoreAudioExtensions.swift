import CoreAudio
import Foundation

enum CoreAudioError: Error {
    case status(OSStatus)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown: AudioObjectID = kAudioObjectUnknown

    var isValid: Bool { self != AudioObjectID.unknown }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func readScalar<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var addr = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let err = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, raw)
        guard err == noErr else { throw CoreAudioError.status(err) }
        return raw.assumingMemoryBound(to: T.self).pointee
    }

    private func readCFString(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = Self.address(selector, scope: scope)
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &unmanaged)
        guard err == noErr, let unmanaged else { throw CoreAudioError.status(err) }
        return unmanaged.takeRetainedValue() as String
    }

    // MARK: - Process object list (system object only)

    static func readProcessObjectList() throws -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(.system, &addr, 0, nil, &size)
        guard err == noErr else { throw CoreAudioError.status(err) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID.unknown, count: count)
        err = AudioObjectGetPropertyData(.system, &addr, 0, nil, &size, &ids)
        guard err == noErr else { throw CoreAudioError.status(err) }
        return ids
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.readScalar(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - Process object properties

    func readProcessPID() throws -> pid_t {
        try readScalar(kAudioProcessPropertyPID)
    }

    func readProcessBundleID() -> String? {
        try? readCFString(kAudioProcessPropertyBundleID)
    }

    func readProcessIsRunningOutput() -> Bool {
        ((try? readScalar(kAudioProcessPropertyIsRunningOutput)) ?? UInt32(0)) == 1
    }

    // MARK: - Device properties

    func readDeviceUID() throws -> String {
        try readCFString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Double {
        try readScalar(kAudioDevicePropertyNominalSampleRate)
    }

    private func streamCount(scope: AudioObjectPropertyScope) -> Int {
        var addr = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size)
        guard err == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Polls until the device reports at least one stream, or `timeout` elapses.
    func waitUntilReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if streamCount(scope: kAudioObjectPropertyScopeOutput) > 0 || streamCount(scope: kAudioObjectPropertyScopeInput) > 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}
