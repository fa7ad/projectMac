import Darwin
import Foundation
import Synchronization
import os

/// One `SceneReducer.reduce` call's worth of broadcastable state, handed to
/// `SceneStreamBroadcaster.sendUpdate` to encode and send.
struct SceneUpdate: Sendable {
    var brightness: Float
    var audioBPM: Double
    var audioPhase: Double
    var visualBPM: Double
    var visualPhase: Double
    var visualOnset: Bool
    var vibrant: HSV
    var muted: HSV
    var average: HSV
    var bass: Float
    var mid: Float
    var treble: Float
}

/// Broadcasts scene/tempo/color state as OSC (Open Sound Control) messages over a
/// UDP socket to a configurable IPv4 destination (loopback by default). A generic OSC source — broadcasts both audio- and visual-derived
/// rate estimates side by side rather than picking a winner — for any OSC-aware tool
/// (Chataigne, TouchDesigner, a custom script) to consume. Each address is its own
/// message, all of a frame's messages sent in one OSC bundle:
///
///   /projectmac/tempo/bpm         f       — audio energy-onset BPM estimate
///   /projectmac/tempo/phase       f       — 0.0-1.0 position within the current audio beat interval
///   /projectmac/visual/bpm        f       — visual onset detector's rate estimate, same units/shape as tempo/bpm
///   /projectmac/visual/phase      f       — same, visual-onset-side
///   /projectmac/visual/onset      (bang)  — fired the instant a visual onset is detected
///   /projectmac/scene/brightness  f       — Rec. 709 luma of the sampled color, 0.0-1.0
///   /projectmac/scene/vibrant     f f f   — saturation/population-weighted dominant swatch, HSV (h as a fraction of the circle)
///   /projectmac/scene/muted       f f f   — second, larger/less-saturated surviving cluster, HSV
///   /projectmac/scene/average     f f f   — flat-average color, HSV
///   /projectmac/audio/bass        f       — FFT band energy, 0.0-1.0
///   /projectmac/audio/mid         f
///   /projectmac/audio/treble      f
///   /projectmac/preset/changed    (bang)  — fired on every projectM preset switch
///   /projectmac/preset/name       s       — the new preset's name, sent alongside the bang
final class SceneStreamBroadcaster: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.projectmac.sceneStreamBroadcaster")
    private let logger = Logger(subsystem: "com.projectmac.app", category: "SceneStreamBroadcaster")
    /// nil while the configured host isn't a valid IPv4 address -- nothing is sent.
    private var destAddr: sockaddr_in?
    private var fd: Int32

    /// Toggled from Settings (main thread), read from the render thread to skip
    /// sampling/broadcasting entirely when off.
    let isEnabled = Atomic<Bool>(false)

    /// Why the last send batch failed (bad destination IP, network error), nil if it
    /// succeeded. Written on `queue`, read from anywhere.
    let lastError = Mutex<String?>(nil)

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            fatalError("failed to create SceneStreamBroadcaster socket: \(String(cString: strerror(errno)))")
        }
        // Non-blocking: a send the network can't take right now is dropped, never
        // stalls the queue (a blocked sendto used to freeze the whole stream).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        // ~12 datagrams/frame at 60fps; the default buffer overflows on slow links (Wi-Fi).
        var sndbuf: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Safe to call from any thread; takes effect on the next send. `host` must be an
    /// IPv4 address (a LAN device's IP, 127.0.0.1, or a broadcast address).
    func setDestination(host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let valid = inet_pton(AF_INET, host, &addr.sin_addr) == 1
        if !valid {
            logger.error("invalid scene stream host \(host, privacy: .public), not sending")
        }
        queue.async { [weak self] in
            self?.destAddr = valid ? addr : nil
            self?.lastError.withLock { $0 = valid ? nil : "Invalid destination IP: \(host)" }
        }
    }

    /// Safe to call from any thread — the send is handed off to `queue`.
    func sendUpdate(_ update: SceneUpdate) {
        var messages = [
            Self.oscMessage(address: "/projectmac/tempo/bpm", args: [.float(Float(update.audioBPM))]),
            Self.oscMessage(address: "/projectmac/tempo/phase", args: [.float(Float(update.audioPhase))]),
            Self.oscMessage(address: "/projectmac/visual/bpm", args: [.float(Float(update.visualBPM))]),
            Self.oscMessage(address: "/projectmac/visual/phase", args: [.float(Float(update.visualPhase))]),
            Self.oscMessage(address: "/projectmac/scene/brightness", args: [.float(update.brightness)]),
            Self.oscMessage(address: "/projectmac/scene/vibrant", args: [.float(update.vibrant.h), .float(update.vibrant.s), .float(update.vibrant.v)]),
            Self.oscMessage(address: "/projectmac/scene/muted", args: [.float(update.muted.h), .float(update.muted.s), .float(update.muted.v)]),
            Self.oscMessage(address: "/projectmac/scene/average", args: [.float(update.average.h), .float(update.average.s), .float(update.average.v)]),
            Self.oscMessage(address: "/projectmac/audio/bass", args: [.float(update.bass)]),
            Self.oscMessage(address: "/projectmac/audio/mid", args: [.float(update.mid)]),
            Self.oscMessage(address: "/projectmac/audio/treble", args: [.float(update.treble)]),
        ]
        if update.visualOnset {
            messages.append(Self.oscMessage(address: "/projectmac/visual/onset"))
        }
        send(messages)
    }

    /// `PresetManager.onPresetChanged` forwarded verbatim.
    func sendPresetChanged(name: String) {
        guard isEnabled.load(ordering: .relaxed) else { return }
        send([
            Self.oscMessage(address: "/projectmac/preset/changed"),
            Self.oscMessage(address: "/projectmac/preset/name", args: [.string(String(name.prefix(200)))]),
        ])
    }

    private func send(_ messages: [Data]) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0, var addr = self.destAddr else { return }
            var failure: String?
            let bundle = Self.oscBundle(messages)
            let result = bundle.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) { addrPtr -> Int in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        sendto(self.fd, buf.baseAddress, buf.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            // EAGAIN = send buffer momentarily full: an intended drop, not an error
            // (the next frame resends everything), so don't surface it in the UI.
            if result < 0, errno != EAGAIN {
                failure = String(cString: strerror(errno))
                self.logger.debug("send failed: \(failure!)")
            }
            self.lastError.withLock { $0 = failure.map { "OSC send failed: \($0)" } }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd)
            self.fd = -1
        }
    }

    private enum OSCArg {
        case float(Float)
        case string(String)

        var typeTag: Character {
            switch self {
            case .float: return "f"
            case .string: return "s"
            }
        }
    }

    /// Encodes one OSC 1.0 message: address, type tag (`,` + one char per arg, or bare
    /// `,` for a bang), then each arg's payload.
    private static func oscMessage(address: String, args: [OSCArg] = []) -> Data {
        var data = oscString(address)
        data.append(oscString("," + String(args.map(\.typeTag))))
        for arg in args {
            switch arg {
            case .float(let value):
                withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            case .string(let value):
                data.append(oscString(value))
            }
        }
        return data
    }

    /// One OSC 1.0 bundle (timetag 1 = "immediately") holding every message, so a frame is
    /// one datagram. ponytail: no splitting, a bundle must stay under the MTU (~1.4KB; a
    /// frame is ~0.5KB, preset names are capped at 200 characters).
    private static func oscBundle(_ messages: [Data]) -> Data {
        var data = oscString("#bundle")
        withUnsafeBytes(of: UInt64(1).bigEndian) { data.append(contentsOf: $0) }
        for message in messages {
            withUnsafeBytes(of: Int32(message.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(message)
        }
        return data
    }

    private static func oscString(_ string: String) -> Data {
        var data = Data(string.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
}
