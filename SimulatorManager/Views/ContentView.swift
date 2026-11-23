import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case devices, running, runtimes, data
    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: "Devices"
        case .running: "Running"
        case .runtimes: "Runtimes"
        case .data: "Data Folders"
        }
    }

    var systemImage: String {
        switch self {
        case .devices: "iphone.gen3"
        case .running: "play.circle"
        case .runtimes: "shippingbox"
        case .data: "externaldrive"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Remembered between launches. Pass `-selectedTab runtimes` on the command line to override.
    @AppStorage("selectedTab") private var selectedTab: SidebarItem = .devices

    private var selection: Binding<SidebarItem?> {
        Binding(get: { selectedTab }, set: { if let item = $0 { selectedTab = item } })
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch selectedTab {
                case .devices: DevicesView()
                case .running: RunningView()
                case .runtimes: RuntimesView()
                case .data: DataFoldersView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { Task { await model.refreshAll() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)
                    .help("Refresh (⌘R)")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    StatusBar()
                }
            }
        }
        .task { await model.initialLoad() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .running: model.runningDevices.count
        case .data: model.orphanFolders.count
        default: 0
        }
    }
}
