import SwiftUI

struct AppCardView: View {
    let app: CatalogApp
    let viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // App header
            HStack(spacing: 12) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.info.displayName)
                        .font(.headline)
                    Text(app.info.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            Divider()

            // Version info and actions
            HStack {
                versionInfo
                Spacer()
                actionButton
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 0.5)
        )
    }

    private var appIcon: some View {
        Group {
            if let nsImage = viewModel.appIcons[app.info.id] {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Placeholder with first letter while icon loads
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(appColor)

                    Text(String(app.info.displayName.prefix(1)))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var versionInfo: some View {
        switch app.installState {
        case .notInstalled:
            if let release = app.latestRelease {
                Text("v\(release.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No release")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .installed(let version):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .updateAvailable(let installed, let latest):
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Update available")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("v\(installed) -> v\(latest)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch app.installState {
        case .notInstalled:
            if app.latestRelease != nil {
                Button("Install") {
                    Task { await viewModel.installApp(app) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .installed:
            Menu {
                Button("Open") { viewModel.openApp(app) }
                Divider()
                Button("Uninstall", role: .destructive) {
                    Task { await viewModel.uninstallApp(app) }
                }
            } label: {
                Text("Open")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)

        case .updateAvailable:
            Button("Update") {
                Task { await viewModel.installApp(app) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)

        case .downloading, .installing:
            EmptyView()

        case .error:
            Button("Retry") {
                Task { await viewModel.installApp(app) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// Generate a consistent color for each app based on its name
    private var appColor: Color {
        let colors: [Color] = [
            Color(red: 0.01, green: 0.32, blue: 0.54), // Brand blue #02528A
            .indigo, .purple, .teal, .cyan, .mint, .brown
        ]
        let hash = abs(app.info.id.hashValue)
        return colors[hash % colors.count]
    }
}
