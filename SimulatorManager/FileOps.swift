import AppKit
import ApplicationServices
import Foundation

struct ScannedFolder: Sendable {
    let udid: String
    let url: URL
    let plistName: String?
    let plistRuntime: String?
}

enum FileOps {
    static let devicesRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
    static let logsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CoreSimulator", isDirectory: true)

    /// Runs blocking file-system work on a background GCD queue.
    static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Lists every UUID-named folder in the CoreSimulator device set.
    static func scanDeviceFolders() async throws -> [ScannedFolder] {
        try await background {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: devicesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return [] }
            return entries.compactMap { url -> ScannedFolder? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      UUID(uuidString: url.lastPathComponent) != nil else { return nil }
                let plist = NSDictionary(contentsOf: url.appendingPathComponent("device.plist"))
                return ScannedFolder(
                    udid: url.lastPathComponent,
                    url: url,
                    plistName: plist?["name"] as? String,
                    plistRuntime: plist?["runtime"] as? String)
            }
        }
    }

    /// Total allocated size of a directory tree.
    static func directorySize(_ url: URL) async -> Int64 {
        (try? await background { directorySizeSync(url) }) ?? 0
    }

    private static func directorySizeSync(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func remove(_ url: URL) async throws {
        try await background {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Removes a root-owned path after the user authenticates in the standard macOS admin prompt.
    static func removeWithAdminPrivileges(_ path: String) async throws {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"/bin/rm -rf \" & quoted form of \"\(escaped)\" with administrator privileges"
        try await Shell.run("/usr/bin/osascript", ["-e", script])
    }

    static func removeLogs(for udid: String) async {
        try? await remove(logsRoot.appendingPathComponent(udid))
    }
}

/// Raises a specific Simulator device window using the Accessibility API.
@MainActor
enum WindowRaiser {
    static let simulatorBundleID = "com.apple.iphonesimulator"

    static var simulatorApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: simulatorBundleID).first
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Returns true if a matching window was found and raised.
    @discardableResult
    static func raise(deviceName: String, osDisplay: String) -> Bool {
        guard let app = simulatorApp else { return false }
        app.activate()
        guard isTrusted else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        func title(_ window: AXUIElement) -> String {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
            return t as? String ?? ""
        }

        let candidates = windows.filter { title($0).hasPrefix(deviceName) }
        let best = candidates.first { title($0).contains(osDisplay) } ?? candidates.first
        guard let window = best else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        return true
    }
}
