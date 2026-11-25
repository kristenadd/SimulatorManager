import SwiftUI

/// One file or folder in a usage breakdown, with its total allocated size.
struct UsageNode: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL?
    let size: Int64
    let isDirectory: Bool
    /// A plain-words name for a well-known simulator folder.
    let title: String?
    /// What a well-known simulator folder holds.
    let note: String?
    /// Largest first; nil for files and empty folders.
    let children: [UsageNode]?
}

enum UsageScanner {
    /// Items smaller than this are folded into one "smaller items" row per folder.
    private static let minimumSize: Int64 = 1_000_000
    private static let maxDepth = 12

    private static let known: [String: (title: String, note: String)] = [
        "data/private/var/MobileAsset": ("Downloaded system assets", "Siri, voice and language models downloaded in the background after the first boot."),
        "data/Library/Application Support/PRBPosterExtensionDataStore": ("Wallpapers", "Lock Screen and Home Screen wallpapers the simulator renders."),
        "data/Library/Caches": ("System caches", "Caches kept by system services. They're rebuilt when needed."),
        "data/Containers/Bundle/Application": ("Installed apps", "The apps you installed."),
        "data/Containers/Data/Application": ("App data", "Your apps' documents and data."),
        "data/Containers/Data/PluginKitPlugin": ("Extension data", "Data kept by app extensions."),
        "data/Containers/Shared/AppGroup": ("Shared app data", "Data shared between apps and their extensions."),
        "data/Media": ("Photos and media", "Photos, videos and other media."),
        "data/Library/Logs": ("Logs", "Logs written inside the simulator."),
        "data/Library/Biome": ("Activity history", "On-device activity history used by system features."),
        "data/Library/IntelligencePlatform": ("Intelligence data", "On-device data used by Siri and intelligence features."),
        "data/var/db": ("System databases", "System databases, such as the app registry."),
    ]

    static func scan(_ root: URL) async -> UsageNode {
        (try? await FileOps.background { node(at: root, relative: "", depth: 0) })
            ?? UsageNode(id: root.path, name: root.lastPathComponent, url: root, size: 0,
                         isDirectory: true, title: nil, note: nil, children: nil)
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    private static func node(at url: URL, relative: String, depth: Int) -> UsageNode {
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
        guard isDirectory else {
            return UsageNode(id: url.path, name: url.lastPathComponent, url: url,
                             size: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0),
                             isDirectory: false, title: nil, note: nil, children: nil)
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [])) ?? []
        var kids = entries.map { child in
            let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
            return depth < maxDepth
                ? node(at: child, relative: path, depth: depth + 1)
                : flat(child, relative: path)
        }
        let total = kids.reduce(0) { $0 + $1.size }
        kids.sort { $0.size > $1.size }

        let small = kids.filter { $0.size < minimumSize }
        var shown = kids.filter { $0.size >= minimumSize }
        if !small.isEmpty {
            let smallSize = small.reduce(0) { $0 + $1.size }
            if shown.isEmpty && smallSize < minimumSize && depth > 0 {
                shown = []  // Nothing worth expanding.
            } else {
                shown.append(UsageNode(
                    id: url.path + "/\u{0}small", name: "\(small.count) smaller item\(small.count == 1 ? "" : "s")",
                    url: nil, size: smallSize, isDirectory: false, title: nil, note: nil, children: nil))
            }
        }
        return UsageNode(id: url.path, name: url.lastPathComponent, url: url, size: total,
                         isDirectory: true, title: known[relative]?.title, note: known[relative]?.note,
                         children: shown.isEmpty ? nil : shown)
    }

    /// A folder past the depth limit: its size, without children.
    private static func flat(_ url: URL, relative: String) -> UsageNode {
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
        var size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        if isDirectory, let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            size = 0
            for case let file as URL in enumerator {
                let v = try? file.resourceValues(forKeys: keys)
                if v?.isDirectory != true { size += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0) }
            }
        }
        return UsageNode(id: url.path, name: url.lastPathComponent, url: url, size: size,
                         isDirectory: isDirectory, title: known[relative]?.title, note: known[relative]?.note,
                         children: nil)
    }
}

extension UsageNode {
    /// Every well-known folder in the tree, largest first.
    var knownFolders: [UsageNode] {
        let own = title == nil ? [] : [self]
        return (own + (children ?? []).flatMap(\.knownFolders)).sorted { $0.size > $1.size }
    }
}

/// A sheet listing what takes up space in one simulator's data folder, largest first.
struct UsageBreakdownView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: DataFolder
    @State private var root: UsageNode?
    @State private var selection: UsageNode.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage of \(folder.name)").font(.headline)
                Text("\(folder.osDisplay) · \(root?.size.byteString ?? "Measuring…")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            Group {
                if let root, let children = root.children {
                    let known = root.knownFolders
                    let other = root.size - known.reduce(0) { $0 + $1.size }
                    List(selection: $selection) {
                        if !known.isEmpty {
                            Section("Where the Space Goes") {
                                ForEach(known) { node in
                                    UsageRow(node: node, total: root.size, summary: true)
                                        .tag(Self.summaryPrefix + node.id)
                                }
                                UsageRow(node: UsageNode(
                                    id: "\u{0}other", name: "Everything else", url: nil, size: max(other, 0),
                                    isDirectory: false, title: nil, note: nil, children: nil),
                                    total: root.size)
                                    .selectionDisabled()
                            }
                        }
                        Section("All Files") {
                            OutlineGroup(children.count == 1 ? children[0].children ?? children : children,
                                         children: \.children) { node in
                                UsageRow(node: node, total: root.size)
                            }
                        }
                    }
                    .contextMenu(forSelectionType: UsageNode.ID.self) { ids in
                        let urls = urls(for: ids)
                        Button("Show in Finder") { model.reveal(urls) }.disabled(urls.isEmpty)
                    } primaryAction: { ids in
                        model.reveal(urls(for: ids))
                    }
                } else if root != nil {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                } else {
                    ProgressView("Measuring…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Double-click an item to show it in Finder.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Folder in Finder") { model.reveal([folder.url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
        .task { root = await UsageScanner.scan(folder.url) }
    }

    private func urls(for ids: Set<UsageNode.ID>) -> [URL] {
        ids.compactMap { id in
            let path = id.hasPrefix(Self.summaryPrefix) ? String(id.dropFirst(Self.summaryPrefix.count)) : id
            return path.contains("\u{0}") ? nil : URL(fileURLWithPath: path)
        }
    }

    private static let summaryPrefix = "summary:"
}

private struct UsageRow: View {
    let node: UsageNode
    let total: Int64
    /// Summary rows show the folder's plain-words title instead of its name.
    var summary = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.url == nil ? "ellipsis.circle" : node.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary ? node.title ?? node.name : node.name).lineLimit(1).truncationMode(.middle)
                if let note = node.note, summary || node.title != nil {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            ProgressView(value: total > 0 ? Double(node.size) / Double(total) : 0)
                .frame(width: 80)
            Text(node.size.byteString)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .help(node.note ?? node.url?.path ?? "")
    }
}
