import AppKit
import ApplicationServices
import Foundation

struct ScannedFolder: Sendable {
    let udid: String
    let url: URL
    let plistName: String?
    let plistRuntime: String?
    let apps: [SimApp]
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
                    plistRuntime: plist?["runtime"] as? String,
                    apps: scanApps(in: url))
            }
        }
    }

    private static let metadataName = ".com.apple.mobile_container_manager.metadata.plist"

    /// Maps bundle identifiers to the containers in `data/Containers/<kind>`.
    private static func containers(_ device: URL, _ kind: String) -> [(id: String, url: URL)] {
        let root = device.appendingPathComponent("data/Containers/\(kind)", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { url in
            let metadata = NSDictionary(contentsOf: url.appendingPathComponent(metadataName))
            guard let id = metadata?["MCMMetadataIdentifier"] as? String else { return nil }
            return (id, url)
        }
    }

    /// Lists the apps the user installed in a simulator. System apps live in the runtime, not here.
    static func scanApps(in device: URL) -> [SimApp] {
        let udid = device.lastPathComponent
        let data = Dictionary(containers(device, "Data/Application"), uniquingKeysWith: { a, _ in a })
        let plugins = containers(device, "Data/PluginKitPlugin")
        return containers(device, "Bundle/Application").compactMap { bundleID, container in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: container, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else { return nil }
            let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))
            let name = (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? appURL.deletingPathExtension().lastPathComponent
            let short = info?["CFBundleShortVersionString"] as? String
            let build = info?["CFBundleVersion"] as? String
            let version = switch (short, build) {
            case let (s?, b?) where s != b: "\(s) (\(b))"
            case let (s?, _): s
            case let (nil, b?): b
            default: ""
            }
            return SimApp(
                udid: udid, bundleID: bundleID, name: name, version: version,
                appURL: appURL, bundleContainer: container, dataContainer: data[bundleID],
                extensionContainers: plugins.filter { $0.id.hasPrefix(bundleID + ".") }.map(\.url))
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

    /// Deletes a shut-down simulator's LaunchServices database so it's rebuilt from the app containers
    /// on the next boot. The separate system-apps database is left alone.
    static func resetLaunchServicesCache(in device: URL) async throws {
        try await background {
            let lsd = device.appendingPathComponent("data/var/db/lsd", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: lsd, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.lastPathComponent.hasPrefix("com.apple.LaunchServices-")
                && url.pathExtension == "csstore" {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func removeLogs(for udid: String) async {
        try? await remove(logsRoot.appendingPathComponent(udid))
    }
}
