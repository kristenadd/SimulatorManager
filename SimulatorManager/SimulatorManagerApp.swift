import SwiftUI

@main
struct SimulatorManagerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Simulator Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 520)
        }
        .commands {
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
    @State private var axTrusted = WindowRaiser.isTrusted

    var body: some View {
        Form {
            Section("Orphaned Data Cleanup") {
                Toggle("Automatically clean up after deleting runtimes", isOn: $autoCleanAfterRuntimeDelete)
                Text("Removes simulators and data folders left without a runtime.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Automatically clean up orphaned folders on launch", isOn: $autoCleanOnLaunch)
            }
            Section("Bring to Front") {
                HStack {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Text(axTrusted ? "Accessibility access granted" : "Accessibility access needed to raise a specific device window")
                    Spacer()
                    if !axTrusted {
                        Button("Grant…") { WindowRaiser.requestTrust() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
        .onAppear { axTrusted = WindowRaiser.isTrusted }
    }
}
