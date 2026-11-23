import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<SimDevice.ID>()
    @State private var sortOrder = [KeyPathComparator(\SimDevice.version, order: .reverse),
                                    KeyPathComparator(\SimDevice.name)]
    @State private var search = ""
    @State private var showUnavailable = true
    @State private var pendingDelete: Set<SimDevice.ID>?

    private var rows: [SimDevice] {
        model.devices
            .filter { showUnavailable || $0.isAvailable }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.osDisplay.localizedCaseInsensitiveContains(search) || $0.udid.contains(search.uppercased()) }
            .sorted(using: sortOrder)
    }

    private var platforms: [String] { Array(Set(model.devices.map(\.platform))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            VersionSelectBar(platforms: platforms, noun: "devices with OS") { platform, matches, extend in
                let ids = rows.filter { (platform == nil || $0.platform == platform) && matches($0.version) }.map(\.id)
                selection = extend ? selection.union(ids) : Set(ids)
            }
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { d in
                    Label(d.name, systemImage: icon(for: d.platform, name: d.name))
                        .foregroundStyle(d.isAvailable ? .primary : .secondary)
                }
                .width(min: 160, ideal: 220)
                TableColumn("Platform", value: \.platform).width(min: 60, ideal: 80)
                TableColumn("OS Version", value: \.version) { Text($0.version.description).monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("State", value: \.state) { StateBadge(state: $0.state) }
                    .width(min: 80, ideal: 100)
                TableColumn("Runtime", value: \.availabilitySort) { d in
                    Text(d.isAvailable ? "Installed" : "Missing")
                        .foregroundStyle(d.isAvailable ? Color.secondary : Color.red)
                        .help(d.availabilityError ?? "")
                }
                .width(min: 60, ideal: 80)
                TableColumn("Data Size", value: \.dataSizeSort) { d in
                    Text(d.dataPathSize.map(\.byteString) ?? "—").monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("UDID", value: \.udid) { Text($0.udid).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 280)
            }
            .contextMenu(forSelectionType: SimDevice.ID.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                Task { await model.launch(ids) }
            }
            .overlay { EmptyOverlay(isEmpty: rows.isEmpty, title: "No Simulators", systemImage: "iphone.slash") }
        }
        .searchable(text: $search, prompt: "Filter devices")
        .navigationTitle("Devices")
        .navigationSubtitle("\(model.devices.count) simulators")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showUnavailable) { Label("Show Unavailable", systemImage: "eye") }
                    .help("Show simulators whose runtime is not installed")
                Button { Task { await model.launch(selection) } } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .disabled(selection.isEmpty)
                .help("Boot and open the selected simulators")
                Button { Task { await model.shutdown(selection) } } label: {
                    Label("Shut Down", systemImage: "stop.fill")
                }
                .disabled(!model.devices.contains { selection.contains($0.id) && $0.isActive })
                Button(role: .destructive) { pendingDelete = selection } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.count ?? 0) simulator(s)?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = pendingDelete ?? []
                selection.subtract(ids)
                Task { await model.deleteDevices(ids) }
            }
        } message: {
            Text("The simulators and all their data will be permanently removed.")
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<SimDevice.ID>) -> some View {
        if !ids.isEmpty {
            Button("Launch") { Task { await model.launch(ids) } }
            Button("Shut Down") { Task { await model.shutdown(ids) } }
            Button("Show Data in Finder") {
                model.reveal(model.devices.filter { ids.contains($0.id) }.map(\.folderURL))
            }
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ids.sorted().joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = ids }
        }
    }
}

func icon(for platform: String, name: String = "") -> String {
    if name.hasPrefix("iPad") { return "ipad" }
    return switch platform {
    case "watchOS": "applewatch"
    case "tvOS": "appletv"
    case "visionOS": "visionpro"
    default: "iphone"
    }
}
