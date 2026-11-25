import SwiftUI

struct DataFoldersView: View {
    @Environment(AppModel.self) private var model
    /// Holds folder IDs (UDIDs) and app IDs ("UDID/bundle ID").
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\DataRow.version, order: .reverse),
                                    KeyPathComparator(\DataRow.name)]
    @State private var search = ""
    @State private var pendingDelete: Set<String>?
    @State private var confirmCleanup = false
    @State private var breakdownFolder: DataFolder?

    private var rows: [DataRow] {
        model.folders
            .filter { f in
                search.isEmpty || f.name.localizedCaseInsensitiveContains(search)
                    || f.osDisplay.localizedCaseInsensitiveContains(search) || f.udid.contains(search.uppercased())
                    || f.apps.contains { $0.name.localizedCaseInsensitiveContains(search)
                        || $0.bundleID.localizedCaseInsensitiveContains(search) }
            }
            .map(DataRow.folder)
            .sorted(using: sortOrder)
    }
    private var platforms: [String] { Array(Set(model.folders.map(\.platform).filter { !$0.isEmpty })).sorted() }

    private func folders(_ ids: Set<String>) -> [DataFolder] { model.folders.filter { ids.contains($0.id) } }
    private func apps(_ ids: Set<String>) -> [SimApp] { model.allApps.filter { ids.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            VersionSelectBar(platforms: platforms, noun: "folders with OS") { platform, matches, extend in
                let ids = model.folders.filter { (platform == nil || $0.platform == platform) && matches($0.version) }
                    .map(\.id)
                selection = extend ? selection.union(ids) : Set(ids)
            }
            Divider()
            if !model.orphanFolders.isEmpty {
                orphanBanner
                Divider()
            }
            Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Device", value: \.name) { row in
                    switch row {
                    case .folder(let f):
                        Label(f.name, systemImage: icon(for: f.platform, name: f.name))
                    case .app(let a):
                        Label { Text(a.name) } icon: { AppIconView(app: a) }
                    }
                }
                .width(min: 160, ideal: 240)
                TableColumn("OS Version", value: \.version) { row in
                    switch row {
                    case .folder(let f): Text(f.osDisplay).monospacedDigit()
                    case .app(let a): Text(a.version).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 130)
                TableColumn("Status", value: \.status) { row in
                    if case .folder(let f) = row {
                        StateBadge(state: f.isBooted ? "Booted" : f.status.rawValue)
                            .help(help(for: f.status))
                    }
                }
                .width(min: 80, ideal: 110)
                TableColumn("Size", value: \.sizeSort) { row in
                    switch row {
                    case .folder(let f): SizeText(bytes: f.sizeBytes)
                    case .app(let a): SizeText(bytes: a.sizeBytes)
                    }
                }
                .width(min: 70, ideal: 90)
                TableColumn("Folder / Bundle ID", value: \.detail) { row in
                    Text(row.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 280)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let selectedApps = apps(ids)
                let selectedFolders = folders(ids)
                if !selectedApps.isEmpty {
                    Button("Show App in Finder") { model.reveal(selectedApps.map(\.appURL)) }
                    Button("Show Documents in Finder") { model.reveal(selectedApps.compactMap(\.documentsURL)) }
                        .disabled(selectedApps.allSatisfy { $0.documentsURL == nil })
                }
                if !selectedFolders.isEmpty {
                    Button("Show Folder in Finder") { model.reveal(selectedFolders.map(\.url)) }
                    if selectedFolders.count == 1 {
                        Button("Show Usage Breakdown…") { breakdownFolder = selectedFolders[0] }
                    }
                }
                if !ids.isEmpty {
                    Divider()
                    Button(deleteTitle(ids), role: .destructive) { pendingDelete = ids }
                }
            } primaryAction: { ids in
                let selectedApps = apps(ids)
                model.reveal(folders(ids).map(\.url) + selectedApps.map { $0.documentsURL ?? $0.appURL })
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
                Button { breakdownFolder = folders(selection).first } label: {
                    Label("Usage Breakdown", systemImage: "chart.bar.doc.horizontal")
                }
                .disabled(folders(selection).count != 1)
                .help("See what takes up space in the selected simulator's data folder")
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
            deleteQuestion,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = pendingDelete ?? []
                selection.subtract(ids)
                let folderIDs = Set(folders(ids).map(\.id))
                // Apps inside a folder that's being deleted go with it.
                let appIDs = Set(apps(ids).filter { !folderIDs.contains($0.udid) }.map(\.id))
                Task {
                    await model.deleteApps(appIDs)
                    await model.deleteFolders(folderIDs)
                }
            }
        } message: {
            Text(deleteMessage)
        }
        .sheet(item: $breakdownFolder) { folder in
            UsageBreakdownView(folder: folder)
        }
        .confirmationDialog("Clean up orphaned data?", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Delete \(model.orphanFolders.count) Folders", role: .destructive) {
                Task { await model.cleanUpOrphans() }
            }
        } message: {
            Text("\(model.orphanFolders.count) folders (\(orphanSize.byteString)) belong to simulators whose runtime isn't installed, or aren't registered with CoreSimulator. They'll be permanently removed.")
        }
    }

    private func deleteTitle(_ ids: Set<String>) -> String {
        folders(ids).isEmpty ? (apps(ids).count == 1 ? "Delete App…" : "Delete Apps…") : "Delete…"
    }

    private var deleteQuestion: String {
        let ids = pendingDelete ?? []
        let selectedFolders = folders(ids), selectedApps = apps(ids)
        if selectedFolders.isEmpty, selectedApps.count == 1 { return "Delete \(selectedApps[0].name)?" }
        let parts = [count(selectedFolders.count, "data folder"), count(selectedApps.count, "app")].compactMap(\.self)
        return "Delete \(parts.joined(separator: " and "))?"
    }

    private var deleteMessage: String {
        let ids = pendingDelete ?? []
        let selectedFolders = folders(ids)
        let folderIDs = Set(selectedFolders.map(\.id))
        let selectedApps = apps(ids).filter { !folderIDs.contains($0.udid) }
        var lines: [String] = []
        if !selectedFolders.isEmpty {
            let size = selectedFolders.compactMap(\.sizeBytes).reduce(0, +)
            lines.append("The simulators and all their data (\(size.byteString)) will be permanently removed. Booted simulators will be shut down first.")
        }
        if !selectedApps.isEmpty {
            let size = selectedApps.compactMap(\.sizeBytes).reduce(0, +)
            let names = selectedApps.map(\.name).sorted().joined(separator: ", ")
            lines.append("\(names) will be uninstalled, and \(selectedApps.count == 1 ? "its" : "their") documents and data (\(size.byteString)) permanently removed.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func count(_ n: Int, _ noun: String) -> String? {
        n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
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
        let selected = (folders(selection).compactMap(\.sizeBytes) + apps(selection).compactMap(\.sizeBytes))
            .reduce(0, +)
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

/// An app's own icon, read from its bundle the way Finder shows it.
private struct AppIconView: View {
    let app: SimApp

    var body: some View {
        Image(nsImage: AppIconCache.icon(for: app.appURL))
            .resizable()
            .frame(width: 18, height: 18)
    }
}

@MainActor
private enum AppIconCache {
    private static var cache: [URL: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let image = cache[url] { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[url] = image
        return image
    }
}
