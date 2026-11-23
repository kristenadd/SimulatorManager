import SwiftUI

struct RuntimesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.autoCleanAfterRuntimeDelete) private var autoClean = true
    @State private var selection = Set<SimRuntime.ID>()
    @State private var sortOrder = [KeyPathComparator(\SimRuntime.version, order: .reverse),
                                    KeyPathComparator(\SimRuntime.platform)]
    @State private var pendingDelete: Set<SimRuntime.ID>?

    private var rows: [SimRuntime] { model.runtimes.sorted(using: sortOrder) }
    private var platforms: [String] { Array(Set(model.runtimes.map(\.platform))).sorted() }
    private var deletableSelection: [SimRuntime] {
        model.runtimes.filter { selection.contains($0.id) && $0.deletable }
    }

    var body: some View {
        VStack(spacing: 0) {
            VersionSelectBar(platforms: platforms, noun: "runtimes") { platform, matches, extend in
                let ids = rows.filter { (platform == nil || $0.platform == platform) && matches($0.version) }.map(\.id)
                selection = extend ? selection.union(ids) : Set(ids)
            }
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Platform", value: \.platform) { r in
                    Label(r.platform, systemImage: icon(for: r.platform))
                }
                .width(min: 80, ideal: 100)
                TableColumn("Version", value: \.version) { Text($0.version.description).monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("Build", value: \.build) { Text($0.build).monospaced() }
                    .width(min: 70, ideal: 90)
                TableColumn("Size", value: \.sizeSort) { SizeText(bytes: $0.sizeBytes) }
                    .width(min: 70, ideal: 90)
                TableColumn("State", value: \.state) { StateBadge(state: $0.state) }
                    .width(min: 70, ideal: 90)
                TableColumn("Devices") { r in Text("\(model.deviceCount(for: r))").monospacedDigit() }
                    .width(min: 50, ideal: 60)
                TableColumn("Last Used", value: \.lastUsedSort) { r in
                    Text(r.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                }
                .width(min: 80, ideal: 100)
                TableColumn("Kind", value: \.kindSort) { r in
                    HStack(spacing: 4) {
                        Text(r.kind.rawValue)
                        if !r.deletable {
                            Image(systemName: "lock.fill").help("This runtime ships inside Xcode and can't be deleted here")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: SimRuntime.ID.self) { ids in
                if !ids.isEmpty {
                    if let paths = Optional(model.runtimes.filter { ids.contains($0.id) }.compactMap(\.path)), !paths.isEmpty {
                        Button("Show in Finder") { model.reveal(paths.map { URL(fileURLWithPath: $0) }) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = ids }
                }
            }
            .overlay { EmptyOverlay(isEmpty: rows.isEmpty, title: "No Runtimes", systemImage: "shippingbox") }
        }
        .navigationTitle("Runtimes")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button(role: .destructive) { pendingDelete = selection } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .disabled(deletableSelection.isEmpty)
                .help("Delete the selected runtimes")
            }
        }
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = pendingDelete ?? []
                selection.subtract(ids)
                Task { await model.deleteRuntimes(ids) }
            }
        } message: {
            Text(dialogMessage)
        }
    }

    private var subtitle: String {
        let total = model.runtimes.compactMap(\.sizeBytes).reduce(0, +)
        if selection.isEmpty { return "\(model.runtimes.count) runtimes · \(total.byteString)" }
        let selected = model.runtimes.filter { selection.contains($0.id) }.compactMap(\.sizeBytes).reduce(0, +)
        return "\(selection.count) selected · \(selected.byteString)"
    }

    private var pendingRuntimes: [SimRuntime] {
        model.runtimes.filter { (pendingDelete ?? []).contains($0.id) && $0.deletable }
    }

    private var dialogTitle: String {
        let n = pendingRuntimes.count
        return "Delete \(n) runtime\(n == 1 ? "" : "s")?"
    }

    private var dialogMessage: String {
        let list = pendingRuntimes.sorted { $0.version < $1.version }.map(\.displayName).joined(separator: ", ")
        let size = pendingRuntimes.compactMap(\.sizeBytes).reduce(0, +).byteString
        var message = "\(list)\n\nThis frees about \(size) and can't be undone; you'd have to download the runtimes again."
        let skipped = (pendingDelete?.count ?? 0) - pendingRuntimes.count
        if skipped > 0 { message += " \(skipped) locked runtime(s) will be skipped." }
        if autoClean { message += "\n\nSimulators and data folders left without a runtime will also be removed (change this in Settings)." }
        return message
    }
}
