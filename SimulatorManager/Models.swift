import Foundation

/// A dotted numeric version ("17.4", "26.0.1") that sorts numerically, not lexically.
struct OSVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let components: [Int]

    init(_ string: String) {
        components = string
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == " " })
            .compactMap { Int($0) }
    }

    init(components: [Int]) { self.components = components }

    var description: String {
        components.isEmpty ? "—" : components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: OSVersion, rhs: OSVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

enum PlatformNames {
    /// Parses "com.apple.CoreSimulator.SimRuntime.iOS-17-4" → ("iOS", 17.4).
    static func parse(runtimeKey: String) -> (platform: String, version: OSVersion) {
        let tail = runtimeKey.components(separatedBy: "SimRuntime.").last ?? runtimeKey
        let parts = tail.split(separator: "-").map(String.init)
        let platform = normalize(parts.first ?? tail)
        let numbers = parts.dropFirst().prefix { Int($0) != nil }.compactMap { Int($0) }
        return (platform, OSVersion(components: numbers))
    }

    static func normalize(_ platform: String) -> String {
        switch platform.lowercased() {
        case "xros", "visionos": return "visionOS"
        case "ios": return "iOS"
        case "tvos": return "tvOS"
        case "watchos": return "watchOS"
        default: return platform
        }
    }

    static func from(platformIdentifier: String) -> String {
        switch platformIdentifier {
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        default: return platformIdentifier.components(separatedBy: ".").last ?? platformIdentifier
        }
    }
}

struct SimDevice: Identifiable, Hashable, Sendable {
    var id: String { udid }
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let availabilityError: String?
    let dataPath: String?
    let dataPathSize: Int64?
    let runtimeKey: String
    let platform: String
    let version: OSVersion
    let deviceType: String

    var osDisplay: String { "\(platform) \(version)" }
    var isBooted: Bool { state == "Booted" }
    var isActive: Bool { state == "Booted" || state == "Booting" || state == "Shutting Down" }
    var dataSizeSort: Int64 { dataPathSize ?? -1 }
    var availabilitySort: String { isAvailable ? "Available" : "Unavailable" }
    var folderURL: URL {
        if let dataPath { return URL(fileURLWithPath: dataPath).deletingLastPathComponent() }
        return FileOps.devicesRoot.appendingPathComponent(udid)
    }
}

enum RuntimeKind: String, Sendable {
    case diskImage = "Disk Image"
    case bundle = "Bundle"
}

struct SimRuntime: Identifiable, Hashable, Sendable {
    /// Disk image UUID (for `simctl runtime delete`) or runtime identifier for bundle runtimes.
    let id: String
    let runtimeIdentifier: String
    let platform: String
    let version: OSVersion
    let build: String
    var sizeBytes: Int64?
    let state: String
    let deletable: Bool
    let kind: RuntimeKind
    let path: String?
    let lastUsed: Date?

    var displayName: String { "\(platform) \(version)" }
    var sizeSort: Int64 { sizeBytes ?? -1 }
    var lastUsedSort: Date { lastUsed ?? .distantPast }
    var kindSort: String { kind.rawValue }
}

enum FolderStatus: String, Sendable, Comparable {
    case active = "Active"
    case orphaned = "Orphaned"          // registered, but runtime is missing
    case unregistered = "Unregistered"  // not known to CoreSimulator at all

    var isOrphan: Bool { self != .active }

    static func < (lhs: FolderStatus, rhs: FolderStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DataFolder: Identifiable, Hashable, Sendable {
    var id: String { udid }
    let udid: String
    let url: URL
    let name: String
    let platform: String
    let version: OSVersion
    let status: FolderStatus
    let isRegistered: Bool
    let isBooted: Bool
    var sizeBytes: Int64?
    var apps: [SimApp] = []

    var osDisplay: String { platform.isEmpty ? "Unknown" : "\(platform) \(version)" }
    var sizeSort: Int64 { sizeBytes ?? -1 }
}

/// An app installed in a simulator, found from its containers on disk.
struct SimApp: Identifiable, Hashable, Sendable {
    var id: String { "\(udid)/\(bundleID)" }
    let udid: String
    let bundleID: String
    let name: String
    let version: String
    /// The `.app` bundle.
    let appURL: URL
    /// The folder installd created to hold the bundle.
    let bundleContainer: URL
    /// The app's sandbox (Documents, Library, tmp). Missing until the app first runs.
    let dataContainer: URL?
    /// Sandboxes of the app's extensions.
    let extensionContainers: [URL]
    var sizeBytes: Int64?

    var documentsURL: URL? {
        guard let dataContainer else { return nil }
        let documents = dataContainer.appendingPathComponent("Documents", isDirectory: true)
        return FileManager.default.fileExists(atPath: documents.path) ? documents : dataContainer
    }
    /// Everything removed when the app is deleted from a simulator that isn't running.
    var allContainers: [URL] { [bundleContainer] + [dataContainer].compactMap(\.self) + extensionContainers }
}

/// A row in the Data Folders outline: a simulator's folder, or one of its apps.
enum DataRow: Identifiable, Hashable {
    case folder(DataFolder)
    case app(SimApp)

    var id: String {
        switch self {
        case .folder(let f): f.id
        case .app(let a): a.id
        }
    }

    // Sort keys for the table's columns. Apps are always listed by name under their simulator.
    var name: String {
        switch self {
        case .folder(let f): f.name
        case .app(let a): a.name
        }
    }
    var version: OSVersion {
        if case .folder(let f) = self { f.version } else { OSVersion(components: []) }
    }
    var status: String {
        if case .folder(let f) = self { f.status.rawValue } else { "" }
    }
    var sizeSort: Int64 {
        switch self {
        case .folder(let f): f.sizeSort
        case .app(let a): a.sizeBytes ?? -1
        }
    }
    var detail: String {
        switch self {
        case .folder(let f): f.udid
        case .app(let a): a.bundleID
        }
    }

    var children: [DataRow]? {
        guard case .folder(let f) = self, !f.apps.isEmpty else { return nil }
        return f.apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(DataRow.app)
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
