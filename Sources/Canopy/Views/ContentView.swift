import SwiftUI

struct ContentView: View {
    @State private var viewModel = CatalogViewModel()
    @State private var selectedFilter: AppFilter = .all

    enum AppFilter: String, CaseIterable {
        case all = "All Apps"
        case installed = "Installed"
        case updates = "Updates"
    }

    /// All apps with releases, sorted by most recent release date (for the carousel)
    var heroApps: [CatalogApp] {
        Array(viewModel.filteredApps
            .filter { $0.latestRelease != nil }
            .sorted { a, b in
                let dateA = a.latestRelease?.publishedAt ?? .distantPast
                let dateB = b.latestRelease?.publishedAt ?? .distantPast
                return dateA > dateB
            }
            .prefix(5))
    }

    @State private var heroIndex: Int = 0
    @State private var heroTimer: Timer?

    /// Apps to show in the grid
    var gridApps: [CatalogApp] {
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

    // MARK: - Brand Colors
    static let bgDark = Color(red: 0.04, green: 0.086, blue: 0.157)       // #0A1628
    static let brandBlue = Color(red: 0.008, green: 0.322, blue: 0.541)    // #02528A
    static let brandBlueLight = Color(red: 0.04, green: 0.416, blue: 0.71) // #0A6AB5
    static let skyBlue = Color(red: 0.22, green: 0.74, blue: 0.973)        // #38BDF8
    static let cardBg = Color.white.opacity(0.03)
    static let cardBorder = Color.white.opacity(0.05)

    var body: some View {
        ZStack {
            // Dark background
            Self.bgDark.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView("Loading apps...")
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                VStack(spacing: 0) {
                    navBar

                    if displayedApps.isEmpty {
                        emptyStateView
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                if selectedFilter == .all, !heroApps.isEmpty {
                                    heroCarousel
                                }
                                gridSection
                            }
                        }
                    }
                }
            }
        }
        .task {
            await viewModel.loadCatalog()
            await viewModel.loadIcons()
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: - Navigation Bar

    private var navBar: some View {
        HStack(spacing: 6) {
            ForEach(AppFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = filter
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(filter.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                        if filter == .installed && viewModel.installedCount > 0 {
                            filterBadge("\(viewModel.installedCount)", isActive: selectedFilter == filter)
                        } else if filter == .updates && viewModel.updatesAvailableCount > 0 {
                            filterBadge("\(viewModel.updatesAvailableCount)", isActive: selectedFilter == filter)
                        } else if filter == .all {
                            filterBadge("\(viewModel.filteredApps.count)", isActive: selectedFilter == filter)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(selectedFilter == filter ? Self.brandBlue : Color.clear)
                    .foregroundStyle(selectedFilter == filter ? .white : .white.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Search apps…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: 200)

            // Refresh button
            Button {
                Task { await viewModel.loadCatalog(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(7)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Refresh catalog")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.01))
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.white.opacity(0.05))
        }
    }

    private func filterBadge(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(isActive ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
            .foregroundStyle(isActive ? .white : .white.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Hero Carousel

    private var heroCarousel: some View {
        let apps = heroApps
        let safeIndex = min(heroIndex, max(apps.count - 1, 0))

        return VStack(spacing: 0) {
            ZStack {
                if safeIndex < apps.count {
                    heroSection(apps[safeIndex])
                        .id(apps[safeIndex].id)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: safeIndex)

            // Dot indicators + arrows
            if apps.count > 1 {
                HStack(spacing: 16) {
                    // Left arrow
                    Button {
                        goToPreviousHero(count: apps.count)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    // Dots
                    HStack(spacing: 6) {
                        ForEach(0..<apps.count, id: \.self) { index in
                            Circle()
                                .fill(index == safeIndex ? Color.white : Color.white.opacity(0.2))
                                .frame(width: index == safeIndex ? 8 : 6, height: index == safeIndex ? 8 : 6)
                                .animation(.easeInOut(duration: 0.2), value: safeIndex)
                                .onTapGesture {
                                    withAnimation { heroIndex = index }
                                    restartHeroTimer(count: apps.count)
                                }
                        }
                    }

                    // Right arrow
                    Button {
                        goToNextHero(count: apps.count)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 10)
                .background(Self.bgDark)
            }
        }
        .onAppear {
            startHeroTimer(count: apps.count)
        }
        .onDisappear {
            heroTimer?.invalidate()
            heroTimer = nil
        }
    }

    private func startHeroTimer(count: Int) {
        guard count > 1 else { return }
        heroTimer?.invalidate()
        heroTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                withAnimation {
                    heroIndex = (heroIndex + 1) % count
                }
            }
        }
    }

    private func restartHeroTimer(count: Int) {
        heroTimer?.invalidate()
        startHeroTimer(count: count)
    }

    private func goToNextHero(count: Int) {
        withAnimation {
            heroIndex = (heroIndex + 1) % count
        }
        restartHeroTimer(count: count)
    }

    private func goToPreviousHero(count: Int) {
        withAnimation {
            heroIndex = (heroIndex - 1 + count) % count
        }
        restartHeroTimer(count: count)
    }

    // MARK: - Hero Section

    private func heroSection(_ app: CatalogApp) -> some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [Self.brandBlue, Self.brandBlueLight, Color(red: 0.016, green: 0.518, blue: 0.784)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Subtle grid overlay
            Canvas { context, size in
                let spacing: CGFloat = 40
                for x in stride(from: 0, through: size.width, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.white.opacity(0.015)), lineWidth: 1)
                }
                for y in stride(from: 0, through: size.height, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.015)), lineWidth: 1)
                }
            }

            // Glow effects
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.07), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: 200, y: -100)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Self.skyBlue.opacity(0.1), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: -100, y: 80)

            // Content
            HStack(spacing: 28) {
                // App icon
                heroIcon(app)
                    .frame(width: 100, height: 100)

                // Info
                VStack(alignment: .leading, spacing: 6) {
                    heroTag(app)

                    Text(app.info.displayName)
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(.white)
                        .tracking(-0.8)

                    Text(app.info.description)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .frame(maxWidth: 400, alignment: .leading)
                }

                Spacer()

                // Action buttons
                VStack(spacing: 8) {
                    heroActionButton(app)
                    if app.latestRelease != nil {
                        Button {
                            if let url = URL(string: app.info.repoURL.absoluteString) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("Learn More")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 12)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }

    private func heroIcon(_ app: CatalogApp) -> some View {
        Group {
            if let nsImage = viewModel.appIcons[app.info.id] {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white.opacity(0.12))

                    Text(String(app.info.displayName.prefix(1)))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
    }

    private func heroTagText(_ app: CatalogApp) -> String {
        switch app.installState {
        case .updateAvailable: return "UPDATE AVAILABLE"
        case .notInstalled: return "NEW RELEASE"
        case .installed: return "INSTALLED"
        default: return "FEATURED"
        }
    }

    private func heroTagColor(_ app: CatalogApp) -> Color {
        switch app.installState {
        case .updateAvailable: return .orange
        case .notInstalled: return Self.skyBlue
        case .installed: return Color(red: 0.08, green: 0.72, blue: 0.65)
        default: return Self.skyBlue
        }
    }

    private func heroTag(_ app: CatalogApp) -> some View {
        let text = heroTagText(app)
        let color = heroTagColor(app)
        return Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func heroActionButton(_ app: CatalogApp) -> some View {
        switch app.installState {
        case .notInstalled:
            if app.latestRelease != nil {
                Button {
                    Task { await viewModel.installApp(app) }
                } label: {
                    Text("Install")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Self.brandBlue)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
            }

        case .installed:
            Button {
                viewModel.openApp(app)
            } label: {
                Text("Open")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Self.brandBlue)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
            .buttonStyle(.plain)

        case .updateAvailable:
            Button {
                Task { await viewModel.installApp(app) }
            } label: {
                Text("Update")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Self.brandBlue)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
            .buttonStyle(.plain)

        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 100)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Installing…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

        case .error(let message):
            VStack(spacing: 4) {
                Button {
                    Task { await viewModel.installApp(app) }
                } label: {
                    Text("Retry")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Grid Section

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selectedFilter == .all ? "All Apps" : selectedFilter.rawValue)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ], spacing: 14) {
                ForEach(gridApps) { app in
                    AppCardView(app: app, viewModel: viewModel)
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    // MARK: - Error / Empty States

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.3))
            Text("Unable to Load")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await viewModel.loadCatalog() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.brandBlue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyIcon)
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.3))
            Text(emptyTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
            Text(emptyDescription)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
