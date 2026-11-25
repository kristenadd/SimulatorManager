import AppKit
import Foundation
import Observation

enum SettingsKey {
    static let autoCleanAfterRuntimeDelete = "autoCleanAfterRuntimeDelete"
    static let autoCleanOnLaunch = "autoCleanOnLaunch"
}

@MainActor
@Observable
final class AppModel {
    var devices: [SimDevice] = []
    var runtimes: [SimRuntime] = []
    var folders: [DataFolder] = []

    /// Titles of in-flight operations, shown in the status bar.
    private(set) var activities: [UUID: String] = [:]
    var lastMessage: String?
    var errorMessage: String?
    private(set) var isRefreshing = false
    private var runtimeNames: [String: (String, OSVersion)] = [:]
    private var didInitialLoad = false

    var runningDevices: [SimDevice] { devices.filter(\.isActive) }
    var orphanFolders: [DataFolder] { folders.filter { $0.status.isOrphan } }
    var isBusy: Bool { !activities.isEmpty }

    private var defaults: UserDefaults { .standard }
    private var autoCleanAfterRuntimeDelete: Bool {
        defaults.object(forKey: SettingsKey.autoCleanAfterRuntimeDelete) as? Bool ?? true
    }
    private var autoCleanOnLaunch: Bool {
        defaults.object(forKey: SettingsKey.autoCleanOnLaunch) as? Bool ?? false
    }

    // MARK: - Activity tracking

    /// Runs an operation while showing it in the status bar; errors surface in an alert.
    private func perform(_ title: String, _ body: () async throws -> Void) async {
        let token = UUID()
        activities[token] = title
        defer { activities[token] = nil }
        do {
            try await body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setActivity(_ title: String, token: UUID) { activities[token] = title }

    // MARK: - Loading

    func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        await refreshAll()
        if autoCleanOnLaunch, !orphanFolders.isEmpty {
            await cleanUpOrphans()
        }
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            runtimeNames = (try? await Simctl.runtimeNameMap()) ?? runtimeNames
            async let devicesTask = Simctl.listDevices(runtimeNames: runtimeNames)
            async let runtimesTask = Simctl.listRuntimes()
            let (newDevices, newRuntimes) = try await (devicesTask, runtimesTask)
            devices = newDevices
            mergeRuntimes(newRuntimes)
            try await refreshFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshDevices() async {
        do {
            devices = try await Simctl.listDevices(runtimeNames: runtimeNames)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps previously computed bundle sizes, then computes missing ones in the background.
    private func mergeRuntimes(_ fresh: [SimRuntime]) {
        let known = Dictionary(runtimes.map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        runtimes = fresh.map { r in
            var r = r
            if r.sizeBytes == nil, let size = known[r.id] ?? nil { r.sizeBytes = size }
            return r
        }
        let needSizes = runtimes.filter { $0.sizeBytes == nil && $0.path != nil }
        guard !needSizes.isEmpty else { return }
        Task {
            await withTaskGroup(of: (String, Int64).self) { group in
                for r in needSizes {
                    let url = URL(fileURLWithPath: r.path!)
                    group.addTask { (r.id, await FileOps.directorySize(url)) }
                }
                for await (id, size) in group {
                    if let i = self.runtimes.firstIndex(where: { $0.id == id }) {
                        self.runtimes[i].sizeBytes = size
                    }
                }
            }
        }
    }

    func refreshFolders() async throws {
        let scanned = try await FileOps.scanDeviceFolders()
        let byUDID = Dictionary(devices.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
        let previousSizes = Dictionary(folders.map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        let previousAppSizes = Dictionary(
            folders.flatMap(\.apps).map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
        func apps(_ s: ScannedFolder) -> [SimApp] {
            s.apps.map { var app = $0; app.sizeBytes = previousAppSizes[app.id] ?? nil; return app }
        }

        folders = scanned.map { s in
            if let d = byUDID[s.udid] {
                return DataFolder(
                    udid: s.udid, url: s.url, name: d.name, platform: d.platform, version: d.version,
                    status: d.isAvailable ? .active : .orphaned, isRegistered: true, isBooted: d.isActive,
                    sizeBytes: previousSizes[s.udid] ?? nil, apps: apps(s))
            }
            let parsed = s.plistRuntime.map { runtimeNames[$0] ?? PlatformNames.parse(runtimeKey: $0) }
            return DataFolder(
                udid: s.udid, url: s.url, name: s.plistName ?? "Unknown device",
                platform: parsed?.0 ?? "", version: parsed?.1 ?? OSVersion(components: []),
                status: .unregistered, isRegistered: false, isBooted: false,
                sizeBytes: previousSizes[s.udid] ?? nil, apps: apps(s))
        }

        let targets = folders.map { ($0.udid, $0.url) }
        let appTargets = folders.flatMap(\.apps).map { ($0.id, $0.allContainers) }
        Task {
            await withTaskGroup(of: (String, Int64).self) { group in
                for (udid, url) in targets {
                    group.addTask { (udid, await FileOps.directorySize(url)) }
                }
                for (id, urls) in appTargets {
                    group.addTask {
                        var total: Int64 = 0
                        for url in urls { total += await FileOps.directorySize(url) }
                        return (id, total)
                    }
                }
                for await (id, size) in group {
                    if let i = self.folders.firstIndex(where: { $0.udid == id }) {
                        self.folders[i].sizeBytes = size
                    } else if let i = self.folders.firstIndex(where: { id.hasPrefix($0.udid + "/") }),
                              let j = self.folders[i].apps.firstIndex(where: { $0.id == id }) {
                        self.folders[i].apps[j].sizeBytes = size
                    }
                }
            }
        }
    }

    // MARK: - Devices

    func launch(_ ids: Set<SimDevice.ID>) async {
        let targets = devices.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        await perform("Launching \(label(targets.count, "simulator"))…") {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for d in targets where !d.isBooted {
                    group.addTask { try await Simctl.boot(d.udid) }
                }
                try await group.waitForAll()
            }
            // Show the last one; Simulator.app also opens a window for every other booted device,
            // and DeviceHub lists them in its sidebar.
            let names = targets.map(\.name).joined(separator: ", ")
            let outcome = try await SimulatorViewer.show(targets.last!)
            lastMessage = message(for: outcome, prefix: "Launched \(names)", device: targets.last!)
        }
        await refreshDevices()
    }

    func bringToFront(_ device: SimDevice) async {
        await perform("Bringing \(device.name) to front…") {
            let outcome = try await SimulatorViewer.show(device)
            lastMessage = message(for: outcome, prefix: "Showing \(device.name)", device: device)
        }
    }

    private func message(for outcome: SimulatorViewer.Outcome, prefix: String, device: SimDevice) -> String {
        switch outcome {
        case .shown:
            return prefix
        case .needsAccessibility:
            SimulatorViewer.requestTrust()
            return "\(prefix). Grant Accessibility access so \(device.name) can be selected in \(SimulatorViewer.displayName) automatically."
        case .notFound:
            return "\(prefix). It didn't appear in \(SimulatorViewer.displayName) yet; select it there."
        }
    }

    func shutdown(_ ids: Set<SimDevice.ID>) async {
        let targets = devices.filter { ids.contains($0.id) && $0.isActive }
        guard !targets.isEmpty else { return }
        await perform("Shutting down \(label(targets.count, "simulator"))…") {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for d in targets { group.addTask { try await Simctl.shutdown(d.udid) } }
                try await group.waitForAll()
            }
            lastMessage = "Shut down \(label(targets.count, "simulator"))"
        }
        await refreshDevices()
    }

    func shutdownAll() async {
        await perform("Shutting down all simulators…") {
            try await Simctl.shutdownAll()
            lastMessage = "All simulators shut down"
        }
        await refreshDevices()
    }

    func quitSimulatorApp() {
        SimulatorViewer.runningApp?.terminate()
    }

    func deleteDevices(_ ids: Set<SimDevice.ID>) async {
        let targets = devices.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        await perform("Deleting \(label(targets.count, "simulator"))…") {
            for d in targets {
                if d.isActive { try? await Simctl.shutdown(d.udid) }
                try await Simctl.delete(d.udid)
            }
            lastMessage = "Deleted \(label(targets.count, "simulator"))"
        }
        await refreshAll()
    }

    // MARK: - Runtimes

    func deviceCount(for runtime: SimRuntime) -> Int {
        devices.filter { $0.platform == runtime.platform && $0.version == runtime.version }.count
    }

    func deleteRuntimes(_ ids: Set<SimRuntime.ID>) async {
        let targets = runtimes.filter { ids.contains($0.id) && $0.deletable }
        guard !targets.isEmpty else { return }
        let token = UUID()
        activities[token] = "Deleting runtimes…"
        defer { activities[token] = nil }

        var deleted: [SimRuntime] = []
        var failures: [String] = []
        for (index, r) in targets.enumerated() {
            setActivity("Deleting \(r.displayName) (\(index + 1) of \(targets.count))…", token: token)
            do {
                switch r.kind {
                case .diskImage:
                    try await Simctl.deleteRuntime(r.id)
                case .bundle:
                    guard let path = r.path else { continue }
                    if FileManager.default.isDeletableFile(atPath: path) {
                        try await FileOps.remove(URL(fileURLWithPath: path))
                    } else {
                        try await FileOps.removeWithAdminPrivileges(path)
                    }
                }
                deleted.append(r)
            } catch {
                failures.append("\(r.displayName): \(error.localizedDescription)")
            }
        }

        let freed = deleted.compactMap(\.sizeBytes).reduce(0, +)
        lastMessage = "Deleted \(label(deleted.count, "runtime")), freeing \(freed.byteString)"
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }

        await refreshAll()

        if autoCleanAfterRuntimeDelete, !deleted.isEmpty {
            // Devices whose platform/version no longer has any runtime installed are orphans.
            let remaining = Set(runtimes.map { "\($0.platform) \($0.version)" })
            let orphanedDevices = devices.filter { d in
                deleted.contains { $0.platform == d.platform && $0.version == d.version }
                    && !remaining.contains(d.osDisplay)
            }
            setActivity("Cleaning up orphaned simulator data…", token: token)
            for d in orphanedDevices {
                if d.isActive { try? await Simctl.shutdown(d.udid) }
                try? await Simctl.delete(d.udid)
            }
            await refreshAll()
            await cleanUpOrphans()
        }
    }

    // MARK: - Data folders

    func deleteFolders(_ ids: Set<DataFolder.ID>) async {
        let targets = folders.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let freed = targets.compactMap(\.sizeBytes).reduce(0, +)
        await perform("Deleting \(label(targets.count, "data folder"))…") {
            for f in targets {
                try await deleteFolder(f)
            }
            lastMessage = "Deleted \(label(targets.count, "data folder")), freeing \(freed.byteString)"
        }
        await refreshAll()
    }

    private func deleteFolder(_ f: DataFolder) async throws {
        if f.isRegistered {
            if f.isBooted { try? await Simctl.shutdown(f.udid) }
            do {
                try await Simctl.delete(f.udid)
            } catch {
                try await FileOps.remove(f.url)
            }
        } else {
            try await FileOps.remove(f.url)
        }
        await FileOps.removeLogs(for: f.udid)
    }

    var allApps: [SimApp] { folders.flatMap(\.apps) }

    /// Uninstalls apps, removing their bundles, documents and other data.
    func deleteApps(_ ids: Set<SimApp.ID>) async {
        let targets = allApps.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let freed = targets.compactMap(\.sizeBytes).reduce(0, +)
        let byDevice = Dictionary(grouping: targets, by: \.udid)
        await perform("Deleting \(label(targets.count, "app"))…") {
            for (udid, apps) in byDevice {
                guard let folder = folders.first(where: { $0.udid == udid }) else { continue }
                if folder.isBooted {
                    for app in apps { try await Simctl.uninstall(app.bundleID, from: udid) }
                } else {
                    // Booting just to uninstall is slow and can fail when memory is tight, so remove
                    // the containers, then drop the simulator's LaunchServices cache. It rebuilds from the
                    // containers on the next boot; otherwise it would still list the deleted apps.
                    for app in apps {
                        for url in app.allContainers { try await FileOps.remove(url) }
                    }
                    try await FileOps.resetLaunchServicesCache(in: folder.url)
                }
            }
            lastMessage = "Deleted \(label(targets.count, "app"))" + (freed > 0 ? ", freeing \(freed.byteString)" : "")
        }
        await refreshAll()
    }

    /// Deletes every data folder whose runtime is gone, plus folders CoreSimulator doesn't know about.
    func cleanUpOrphans() async {
        await perform("Cleaning up orphaned data folders…") {
            try await refreshFolders()
            let orphans = orphanFolders
            let freed = orphans.compactMap(\.sizeBytes).reduce(0, +)
            try? await Simctl.deleteUnavailable()
            for f in orphans {
                try? await deleteFolder(f)
            }
            lastMessage = orphans.isEmpty
                ? "No orphaned data folders found"
                : "Removed \(label(orphans.count, "orphaned folder"))" + (freed > 0 ? ", freeing \(freed.byteString)" : "")
        }
        await refreshAll()
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func label(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
