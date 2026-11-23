import AppKit
import ApplicationServices

/// The app that displays simulators: Simulator.app up to Xcode 26, DeviceHub from Xcode 27 on.
/// Showing a particular device uses the Accessibility API, since neither app has a public way to
/// pick one once it's running.
@MainActor
enum SimulatorViewer {
    enum Kind {
        /// Simulator.app: one window per booted device, titled "<name> – <OS>".
        case simulator
        /// DeviceHub: a sidebar of devices whose rows are identified as "TableRow.Device.<UDID>".
        case deviceHub
    }

    enum Outcome {
        case shown
        /// The viewer is open, but picking the device needs Accessibility access.
        case needsAccessibility
        /// The viewer is open, but the device didn't appear in it in time.
        case notFound
    }

    struct ViewerError: LocalizedError {
        var errorDescription: String? {
            "Couldn't find Simulator or DeviceHub. Make sure Xcode is installed and selected with xcode-select."
        }
    }

    static let simulatorBundleID = "com.apple.iphonesimulator"
    static let deviceHubBundleID = "com.apple.dt.Devices"

    static var installed: (kind: Kind, url: URL)? {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: simulatorBundleID) { return (.simulator, url) }
        if let url = workspace.urlForApplication(withBundleIdentifier: deviceHubBundleID) { return (.deviceHub, url) }
        return nil
    }

    static var displayName: String {
        switch installed?.kind {
        case .deviceHub: "DeviceHub"
        default: "Simulator"
        }
    }

    static var runningApp: NSRunningApplication? {
        for id in [simulatorBundleID, deviceHubBundleID] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return app }
        }
        return nil
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens the viewer (launching it if needed), brings it forward and shows the given booted device.
    static func show(_ device: SimDevice) async throws -> Outcome {
        guard let viewer = installed else { throw ViewerError() }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if viewer.kind == .simulator {
            // Only applies when Simulator launches; once running we raise the window ourselves.
            configuration.arguments = ["-CurrentDeviceUDID", device.udid]
        }
        let app = try await NSWorkspace.shared.openApplication(at: viewer.url, configuration: configuration)
        app.activate()

        guard isTrusted else {
            // Simulator.app focuses the device on its own at launch; DeviceHub needs us to pick it.
            return viewer.kind == .simulator ? .shown : .needsAccessibility
        }

        // The viewer may still be starting, or still picking up a device that just booted.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<40 {
            let found = switch viewer.kind {
            case .simulator: raiseSimulatorWindow(axApp, device: device)
            case .deviceHub: selectDeviceHubRow(axApp, udid: device.udid)
            }
            if found { return .shown }
            try await Task.sleep(for: .milliseconds(250))
        }
        return .notFound
    }

    // MARK: - Accessibility

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func windows(_ app: AXUIElement) -> [AXUIElement] {
        attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func raiseSimulatorWindow(_ app: AXUIElement, device: SimDevice) -> Bool {
        let all = windows(app).map { ($0, attribute($0, kAXTitleAttribute) as? String ?? "") }
        let candidates = all.filter { $0.1.hasPrefix(device.name) }
        guard let window = (candidates.first { $0.1.contains(device.osDisplay) } ?? candidates.first)?.0
        else { return false }
        raise(window)
        return true
    }

    private static func selectDeviceHubRow(_ app: AXUIElement, udid: String) -> Bool {
        let identifier = "TableRow.Device.\(udid)"
        for window in windows(app) {
            if let row = findRow(in: window, identifier: identifier, depth: 0) {
                AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                raise(window)
                return true
            }
        }
        return false
    }

    /// Finds the sidebar row whose cell contains an element with the given identifier.
    private static func findRow(in element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute) as? String == kAXRowRole {
            let items = children(element).flatMap(children)
            return items.contains { attribute($0, kAXIdentifierAttribute) as? String == identifier } ? element : nil
        }
        guard depth < 8 else { return nil }
        for child in children(element) {
            if let row = findRow(in: child, identifier: identifier, depth: depth + 1) { return row }
        }
        return nil
    }
}
