import SwiftUI

/// "Select [platform] [lower than / up to] [version]" bar used to bulk-select rows by OS version.
struct VersionSelectBar: View {
    enum Comparison: String, CaseIterable, Identifiable {
        case lower = "lower than"
        case lowerOrEqual = "lower than or equal to"
        case higher = "higher than"
        case equal = "equal to"
        var id: String { rawValue }

        func matches(_ v: OSVersion, _ target: OSVersion) -> Bool {
            switch self {
            case .lower: v < target
            case .lowerOrEqual: v <= target
            case .higher: v > target
            case .equal: v == target
            }
        }
    }

    let platforms: [String]
    let noun: String
    /// Called with (platform or nil for all, predicate) and whether to add to the existing selection.
    let onSelect: (_ platform: String?, _ predicate: @escaping (OSVersion) -> Bool, _ extend: Bool) -> Void

    @State private var platform = "All"
    @State private var comparison: Comparison = .lower
    @State private var versionText = ""

    private var target: OSVersion? {
        let v = OSVersion(versionText)
        return v.components.isEmpty ? nil : v
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Select")
            Picker("Platform", selection: $platform) {
                Text("all platforms").tag("All")
                ForEach(platforms, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Text(noun)
            Picker("Comparison", selection: $comparison) {
                ForEach(Comparison.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("e.g. 18.0", text: $versionText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onSubmit { apply(extend: false) }
            Button("Select") { apply(extend: false) }
                .disabled(target == nil)
            Button("Add to Selection") { apply(extend: true) }
                .disabled(target == nil)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func apply(extend: Bool) {
        guard let target else { return }
        let comparison = comparison
        onSelect(platform == "All" ? nil : platform, { comparison.matches($0, target) }, extend)
    }
}

struct StateBadge: View {
    let state: String

    var color: Color {
        switch state {
        case "Booted", "Ready", "Active": .green
        case "Booting", "Shutting Down", "Deleting", "Downloading": .orange
        case "Orphaned", "Unregistered", "Unavailable", "Unusable": .red
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state)
        }
    }
}

struct SizeText: View {
    let bytes: Int64?
    var body: some View {
        if let bytes {
            Text(bytes.byteString).monospacedDigit()
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.small)
                Text(model.activities.values.sorted().joined(separator: " · "))
                    .lineLimit(1)
            } else if model.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Refreshing…")
            } else if let message = model.lastMessage {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(message).lineLimit(1)
            }
            Spacer()
            let runtimeTotal = model.runtimes.compactMap(\.sizeBytes).reduce(0, +)
            let dataTotal = model.folders.compactMap(\.sizeBytes).reduce(0, +)
            Text("Runtimes: \(runtimeTotal.byteString) · Data: \(dataTotal.byteString)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// An empty-state overlay for tables.
struct EmptyOverlay: View {
    let isEmpty: Bool
    let title: String
    let systemImage: String
    var body: some View {
        if isEmpty {
            ContentUnavailableView(title, systemImage: systemImage)
        }
    }
}
