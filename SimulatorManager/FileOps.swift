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
