import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updater.shared // starts Sparkle's scheduled update checks
    }
}

@main
struct SimulatorManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @ObservedObject private var updater = Updater.shared

    var body: some Scene {
        Window("Simulator Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Simulator Manager") { AboutPanel.show() }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.autoCleanAfterRuntimeDelete) private var autoCleanAfterRuntimeDelete = true
    @AppStorage(SettingsKey.autoCleanOnLaunch) private var autoCleanOnLaunch = false
    @State private var axTrusted = SimulatorViewer.isTrusted
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section("Orphaned Data Cleanup") {
                Toggle("Automatically clean up after deleting runtimes", isOn: $autoCleanAfterRuntimeDelete)
                Text("Removes simulators and data folders left without a runtime.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Automatically clean up orphaned folders on launch", isOn: $autoCleanOnLaunch)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            Section("Showing Devices") {
                HStack {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Text(axTrusted ? "Accessibility access granted" : "Accessibility access needed to show a specific device in \(SimulatorViewer.displayName)")
                    Spacer()
                    if !axTrusted {
                        Button("Grant…") { SimulatorViewer.requestTrust() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
        .onAppear { axTrusted = SimulatorViewer.isTrusted }
    }
}
