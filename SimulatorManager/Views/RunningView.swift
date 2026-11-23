import SwiftUI

struct RunningView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<SimDevice.ID>()
    @State private var sortOrder = [KeyPathComparator(\SimDevice.name)]

    private var rows: [SimDevice] { model.runningDevices.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { d in Label(d.name, systemImage: icon(for: d.platform, name: d.name)) }
                .width(min: 160, ideal: 240)
            TableColumn("Platform", value: \.platform).width(min: 60, ideal: 80)
            TableColumn("OS Version", value: \.version) { Text($0.version.description).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("State", value: \.state) { StateBadge(state: $0.state) }
            TableColumn("UDID", value: \.udid) { Text($0.udid).font(.caption.monospaced()).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 280)
        }
        .contextMenu(forSelectionType: SimDevice.ID.self) { ids in
            if let first = ids.first, let d = rows.first(where: { $0.id == first }) {
                Button("Bring to Front") { Task { await model.bringToFront(d) } }
            }
            if !ids.isEmpty {
                Button("Shut Down", role: .destructive) { Task { await model.shutdown(ids) } }
            }
        } primaryAction: { ids in
            if let first = ids.first, let d = rows.first(where: { $0.id == first }) {
                Task { await model.bringToFront(d) }
            }
        }
        .overlay { EmptyOverlay(isEmpty: rows.isEmpty, title: "No Running Simulators", systemImage: "moon.zzz") }
        .navigationTitle("Running")
        .navigationSubtitle("\(rows.count) running")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if let d = rows.first(where: { selection.contains($0.id) }) {
                        Task { await model.bringToFront(d) }
                    }
                } label: {
                    Label("Bring to Front", systemImage: "macwindow.on.rectangle")
                }
                .disabled(selection.isEmpty)
                Button(role: .destructive) { Task { await model.shutdown(selection) } } label: {
                    Label("Shut Down", systemImage: "stop.fill")
                }
                .disabled(selection.isEmpty)
                Menu {
                    Button("Shut Down All Simulators") { Task { await model.shutdownAll() } }
                    Button("Quit \(SimulatorViewer.displayName)") { model.quitSimulatorApp() }
                } label: {
                    Label("More", systemImage: "power")
                }
                .disabled(rows.isEmpty && SimulatorViewer.runningApp == nil)
            }
        }
        // Poll while this tab is visible so external boots/shutdowns show up.
        .task {
            while !Task.isCancelled {
                await model.refreshDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
