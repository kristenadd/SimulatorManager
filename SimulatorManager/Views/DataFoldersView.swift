import SwiftUI

struct DataFoldersView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<DataFolder.ID>()
    @State private var sortOrder = [KeyPathComparator(\DataFolder.version, order: .reverse),
                                    KeyPathComparator(\DataFolder.name)]
    @State private var search = ""
    @State private var pendingDelete: Set<DataFolder.ID>?
    @State private var confirmCleanup = false

    private var rows: [DataFolder] {
        model.folders
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.osDisplay.localizedCaseInsensitiveContains(search) || $0.udid.contains(search.uppercased()) }
            .sorted(using: sortOrder)
    }
    private var platforms: [String] { Array(Set(model.folders.map(\.platform).filter { !$0.isEmpty })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            VersionSelectBar(platforms: platforms, noun: "folders with OS") { platform, matches, extend in
                let ids = rows.filter { (platform == nil || $0.platform == platform) && matches($0.version) }.map(\.id)
                selection = extend ? selection.union(ids) : Set(ids)
            }
            Divider()
            if !model.orphanFolders.isEmpty {
                orphanBanner
                Divider()
            }
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Device", value: \.name) { f in
                    Label(f.name, systemImage: icon(for: f.platform, name: f.name))
                }
                .width(min: 160, ideal: 220)
                TableColumn("OS Version", value: \.version) { f in
                    Text(f.osDisplay).monospacedDigit()
                }
                .width(min: 110, ideal: 130)
                TableColumn("Status", value: \.status) { f in
                    StateBadge(state: f.isBooted ? "Booted" : f.status.rawValue)
                        .help(help(for: f.status))
                }
                .width(min: 80, ideal: 110)
                TableColumn("Size", value: \.sizeSort) { SizeText(bytes: $0.sizeBytes) }
                    .width(min: 70, ideal: 90)
                TableColumn("Folder", value: \.udid) { f in
                    Text(f.udid).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 280)
            }
            .contextMenu(forSelectionType: DataFolder.ID.self) { ids in
                if !ids.isEmpty {
                    Button("Show in Finder") { model.reveal(model.folders.filter { ids.contains($0.id) }.map(\.url)) }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = ids }
                }
            } primaryAction: { ids in
                model.reveal(model.folders.filter { ids.contains($0.id) }.map(\.url))
            }
            .overlay { EmptyOverlay(isEmpty: rows.isEmpty, title: "No Data Folders", systemImage: "folder") }
        }
        .searchable(text: $search, prompt: "Filter folders")
        .navigationTitle("Data Folders")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { model.reveal([FileOps.devicesRoot]) } label: {
                    Label("Open Devices Folder", systemImage: "folder")
                }
                Button { confirmCleanup = true } label: {
                    Label("Clean Up Orphans", systemImage: "sparkles")
                }
                .disabled(model.orphanFolders.isEmpty)
                .help("Delete every data folder whose runtime is no longer installed")
                Button(role: .destructive) { pendingDelete = selection } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.count ?? 0) data folder(s)?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = pendingDelete ?? []
                selection.subtract(ids)
                Task { await model.deleteFolders(ids) }
            }
        } message: {
            let size = model.folders.filter { (pendingDelete ?? []).contains($0.id) }
                .compactMap(\.sizeBytes).reduce(0, +)
            Text("This permanently removes the simulator and its data (\(size.byteString)). Booted simulators will be shut down first.")
        }
        .confirmationDialog("Clean up orphaned data?", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Delete \(model.orphanFolders.count) Folders", role: .destructive) {
                Task { await model.cleanUpOrphans() }
            }
        } message: {
            Text("\(model.orphanFolders.count) folders (\(orphanSize.byteString)) belong to simulators whose runtime isn't installed, or aren't registered with CoreSimulator. They'll be permanently removed.")
        }
    }

    private var orphanSize: Int64 { model.orphanFolders.compactMap(\.sizeBytes).reduce(0, +) }

    private var orphanBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(model.orphanFolders.count) orphaned folder(s) using \(orphanSize.byteString)")
            Spacer()
            Button("Select Orphans") { selection = Set(model.orphanFolders.map(\.id)) }
            Button("Clean Up") { confirmCleanup = true }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }

    private var subtitle: String {
        let total = model.folders.compactMap(\.sizeBytes).reduce(0, +)
        if selection.isEmpty { return "\(model.folders.count) folders · \(total.byteString)" }
        let selected = model.folders.filter { selection.contains($0.id) }.compactMap(\.sizeBytes).reduce(0, +)
        return "\(selection.count) selected · \(selected.byteString)"
    }

    private func help(for status: FolderStatus) -> String {
        switch status {
        case .active: "Simulator with an installed runtime"
        case .orphaned: "Registered simulator whose runtime is no longer installed"
        case .unregistered: "Folder not known to CoreSimulator"
        }
    }
}
