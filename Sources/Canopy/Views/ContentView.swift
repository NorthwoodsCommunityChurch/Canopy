import SwiftUI

struct ContentView: View {
    @State private var viewModel = CatalogViewModel()
    @State private var selectedFilter: AppFilter = .all

    enum AppFilter: String, CaseIterable {
        case all = "All Apps"
        case installed = "Installed"
        case updates = "Updates"
    }

    var displayedApps: [CatalogApp] {
        switch selectedFilter {
        case .all:
            return viewModel.filteredApps
        case .installed:
            return viewModel.filteredApps.filter { $0.installState.isInstalled }
        case .updates:
            return viewModel.filteredApps.filter {
                if case .updateAvailable = $0.installState { return true }
                return false
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainContent
        }
        .searchable(text: $viewModel.searchText, prompt: "Search apps...")
        .task {
            await viewModel.loadCatalog()
            await viewModel.loadIcons()
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private var sidebar: some View {
        List(selection: $selectedFilter) {
            Section("Library") {
                Label("All Apps", systemImage: "square.grid.2x2")
                    .tag(AppFilter.all)

                Label {
                    HStack {
                        Text("Installed")
                        Spacer()
                        if viewModel.installedCount > 0 {
                            Text("\(viewModel.installedCount)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .tag(AppFilter.installed)

                Label {
                    HStack {
                        Text("Updates")
                        Spacer()
                        if viewModel.updatesAvailableCount > 0 {
                            Text("\(viewModel.updatesAvailableCount)")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .tag(AppFilter.updates)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isLoading {
            ProgressView("Loading apps...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            ContentUnavailableView {
                Label("Unable to Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task { await viewModel.loadCatalog() }
                }
            }
        } else if displayedApps.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptyIcon)
            } description: {
                Text(emptyDescription)
            }
        } else {
            ScrollView {
                headerBar
                appGrid
                    .padding()
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Text(selectedFilter.rawValue)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button {
                Task { await viewModel.loadCatalog() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh catalog")
        }
        .padding(.horizontal)
        .padding(.top)
    }

    private var appGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)], spacing: 16) {
            ForEach(displayedApps) { app in
                AppCardView(app: app, viewModel: viewModel)
            }
        }
    }

    private var emptyTitle: String {
        switch selectedFilter {
        case .all: return "No Apps Found"
        case .installed: return "No Apps Installed"
        case .updates: return "All Up to Date"
        }
    }

    private var emptyIcon: String {
        switch selectedFilter {
        case .all: return "square.grid.2x2"
        case .installed: return "app.dashed"
        case .updates: return "checkmark.circle"
        }
    }

    private var emptyDescription: String {
        switch selectedFilter {
        case .all: return "No Northwoods apps were found on GitHub."
        case .installed: return "Install apps from the All Apps tab."
        case .updates: return "All your installed apps are up to date."
        }
    }
}
