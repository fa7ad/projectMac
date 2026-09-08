import AppKit
import Darwin
import Foundation

/// The user-facing app a HAL audio process belongs to.
///
/// Browsers and Electron apps render audio from helper processes nested inside the parent
/// bundle (`Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app`), so the
/// *outermost* `.app` on the executable path — not the process's own bundle — is both
/// what the user recognises and what stays stable as helpers are spawned and killed.
///
/// Main thread only (AppKit lookups).
struct AppIdentity {
    /// Groups every process of one app family.
    let key: String
    let name: String
    let bundleID: String?
    let icon: NSImage?
    /// Whether the app runs with a normal Dock presence, rather than as a menu-bar-only
    /// or background helper. Lets callers rank media apps above audio utilities.
    let isRegularApp: Bool
    /// The family's parent process where it is running, otherwise the process resolved.
    /// Display and aggregate-device naming only; taps address process objects, not PIDs.
    let pid: pid_t

    init(pid: pid_t) {
        let path = Self.executablePath(pid: pid)
        let rootAppURL = Self.outermostAppBundle(in: path)
        let rootBundleID = rootAppURL.flatMap(Bundle.init(url:))?.bundleIdentifier

        // The parent's localizedName, icon and PID are the ones the user sees in the Dock
        // and outlive any individual helper.
        let parent = rootBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        let own = NSRunningApplication(processIdentifier: pid)
        let executable = path.map { URL(fileURLWithPath: $0).lastPathComponent }

        bundleID = rootBundleID ?? own?.bundleIdentifier
        isRegularApp = (parent ?? own)?.activationPolicy == .regular
        self.pid = parent?.processIdentifier ?? pid
        key = rootBundleID ?? rootAppURL?.path ?? own?.bundleIdentifier ?? path ?? "pid-\(pid)"
        name = parent?.localizedName
            ?? rootAppURL.map { FileManager.default.displayName(atPath: $0.path) }
            ?? own?.localizedName
            ?? executable
            ?? "PID \(pid)"
        icon = parent?.icon
            ?? rootAppURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? own?.icon
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    private static func outermostAppBundle(in path: String?) -> URL? {
        guard let path else { return nil }
        var url = URL(fileURLWithPath: path)
        var outermost: URL?
        while url.path != "/" {
            if url.pathExtension == "app" { outermost = url }
            url.deleteLastPathComponent()
        }
        return outermost
    }
}
