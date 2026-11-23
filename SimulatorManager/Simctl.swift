import Foundation

/// Async wrappers around `xcrun simctl`.
enum Simctl {
    private static let xcrun = "/usr/bin/xcrun"

    @discardableResult
    static func simctl(_ args: String...) async throws -> Data {
        try await Shell.run(xcrun, ["simctl"] + args)
    }

    // MARK: Devices

    private struct DevicesResponse: Decodable {
        let devices: [String: [DeviceDTO]]
    }

    private struct DeviceDTO: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let availabilityError: String?
        let dataPath: String?
        let dataPathSize: Int64?
        let deviceTypeIdentifier: String?
    }

    static func listDevices(runtimeNames: [String: (String, OSVersion)] = [:]) async throws -> [SimDevice] {
        let data = try await simctl("list", "devices", "-j")
        let response = try JSONDecoder().decode(DevicesResponse.self, from: data)
        return response.devices.flatMap { key, devices -> [SimDevice] in
            let (platform, version) = runtimeNames[key] ?? PlatformNames.parse(runtimeKey: key)
            return devices.map { d in
                SimDevice(
                    udid: d.udid,
                    name: d.name,
                    state: d.state,
                    isAvailable: d.isAvailable ?? true,
                    availabilityError: d.availabilityError,
                    dataPath: d.dataPath,
                    dataPathSize: d.dataPathSize,
                    runtimeKey: key,
                    platform: platform,
                    version: version,
                    deviceType: (d.deviceTypeIdentifier ?? "")
                        .components(separatedBy: "SimDeviceType.").last?
                        .replacingOccurrences(of: "-", with: " ") ?? "")
            }
        }
    }

    // MARK: Runtimes

    private struct RuntimesResponse: Decodable {
        let runtimes: [RuntimeDTO]
    }

    private struct RuntimeDTO: Decodable {
        let identifier: String
        let name: String?
        let version: String
        let platform: String?
        let buildversion: String?
        let isAvailable: Bool?
        let bundlePath: String?
    }

    private struct ImageDTO: Decodable {
        let identifier: String
        let build: String?
        let deletable: Bool?
        let kind: String?
        let lastUsedAt: String?
        let runtimeIdentifier: String?
        let sizeBytes: Int64?
        let state: String?
        let version: String?
        let platformIdentifier: String?
        let path: String?
    }

    /// Maps runtime identifiers to platform/version for labelling devices.
    static func runtimeNameMap() async throws -> [String: (String, OSVersion)] {
        let data = try await simctl("list", "runtimes", "-j")
        let response = try JSONDecoder().decode(RuntimesResponse.self, from: data)
        var map: [String: (String, OSVersion)] = [:]
        for r in response.runtimes {
            let platform = PlatformNames.normalize(r.platform ?? PlatformNames.parse(runtimeKey: r.identifier).platform)
            map[r.identifier] = (platform, OSVersion(r.version))
        }
        return map
    }

    /// Merges `simctl runtime list` (disk images, with sizes) with `simctl list runtimes`
    /// (which also includes legacy bundle-based runtimes).
    static func listRuntimes() async throws -> [SimRuntime] {
        async let imagesData = simctl("runtime", "list", "-j")
        async let listData = simctl("list", "runtimes", "-j")

        let images = (try? JSONDecoder().decode([String: ImageDTO].self, from: try await imagesData)) ?? [:]
        let listed = try JSONDecoder().decode(RuntimesResponse.self, from: try await listData).runtimes

        let iso = ISO8601DateFormatter()
        var result: [SimRuntime] = images.values.map { img in
            let parsed = PlatformNames.parse(runtimeKey: img.runtimeIdentifier ?? "")
            let platform = img.platformIdentifier.map(PlatformNames.from(platformIdentifier:)) ?? parsed.platform
            return SimRuntime(
                id: img.identifier,
                runtimeIdentifier: img.runtimeIdentifier ?? "",
                platform: platform,
                version: OSVersion(img.version ?? parsed.version.description),
                build: img.build ?? "",
                sizeBytes: img.sizeBytes,
                state: img.state ?? "Unknown",
                deletable: img.deletable ?? true,
                kind: .diskImage,
                path: img.path,
                lastUsed: img.lastUsedAt.flatMap { iso.date(from: $0) })
        }

        let imageRuntimeIDs = Set(images.values.compactMap(\.runtimeIdentifier))
        let imageBuilds = Set(images.values.compactMap(\.build))
        for r in listed where !imageRuntimeIDs.contains(r.identifier) {
            if let build = r.buildversion, imageBuilds.contains(build) { continue }
            let path = r.bundlePath
            // Runtimes bundled inside Xcode.app can't be removed independently.
            let insideApp = path?.contains(".app/") ?? true
            result.append(SimRuntime(
                id: r.identifier,
                runtimeIdentifier: r.identifier,
                platform: PlatformNames.normalize(r.platform ?? PlatformNames.parse(runtimeKey: r.identifier).platform),
                version: OSVersion(r.version),
                build: r.buildversion ?? "",
                sizeBytes: nil,
                state: (r.isAvailable ?? true) ? "Ready" : "Unavailable",
                deletable: !insideApp,
                kind: .bundle,
                path: path,
                lastUsed: nil))
        }
        return result
    }

    // MARK: Actions

    static func boot(_ udid: String) async throws {
        try await simctl("boot", udid)
    }

    static func shutdown(_ udid: String) async throws {
        try await simctl("shutdown", udid)
    }

    static func shutdownAll() async throws {
        try await simctl("shutdown", "all")
    }

    static func delete(_ udid: String) async throws {
        try await simctl("delete", udid)
    }

    static func deleteUnavailable() async throws {
        try await simctl("delete", "unavailable")
    }

    static func deleteRuntime(_ imageID: String) async throws {
        try await simctl("runtime", "delete", imageID)
    }
}
