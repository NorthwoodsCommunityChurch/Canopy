import SwiftUI

struct AppCardView: View {
    let app: CatalogApp
    let viewModel: CatalogViewModel

    var body: some View {
        HStack(spacing: 14) {
            appIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(app.info.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                Text(app.info.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)

                versionText
            }

            Spacer()

            actionButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Icon

    private var appIcon: some View {
        Group {
            if let nsImage = viewModel.appIcons[app.info.id] {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: appGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text(String(app.info.displayName.prefix(1)))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Version Text

    @ViewBuilder
    private var versionText: some View {
        switch app.installState {
        case .notInstalled:
            if let release = app.latestRelease {
                Text("v\(release.version)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
            } else {
                Text("No release")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.15))
            }

        case .installed(let version):
            Text("v\(version)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))

        case .updateAvailable(let installed, let latest):
            Text("v\(installed) → v\(latest)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))

        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .tint(ContentView.brandBlue)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

        case .installing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Installing…")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }

        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.8))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch app.installState {
        case .notInstalled:
            if app.latestRelease != nil {
                Button {
                    Task { await viewModel.installApp(app) }
                } label: {
                    Text("Install")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(ContentView.brandBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

        case .installed:
            Button {
                viewModel.openApp(app)
            } label: {
                Text("Open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.08, green: 0.72, blue: 0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Uninstall", role: .destructive) {
                    Task { await viewModel.uninstallApp(app) }
                }
            }

        case .updateAvailable:
            Button {
                Task { await viewModel.installApp(app) }
            } label: {
                Text("Update")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

        case .downloading, .installing:
            EmptyView()

        case .error:
            Button {
                Task { await viewModel.installApp(app) }
            } label: {
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Brand-Compliant Colors

    /// Consistent gradient colors per app — all blues, teals, and slates
    private var appGradient: [Color] {
        let gradients: [[Color]] = [
            [Color(red: 0.04, green: 0.42, blue: 0.71), Color(red: 0.008, green: 0.32, blue: 0.54)],   // Brand blue
            [Color(red: 0.22, green: 0.74, blue: 0.97), Color(red: 0.01, green: 0.52, blue: 0.78)],     // Sky blue
            [Color(red: 0.12, green: 0.23, blue: 0.37), Color(red: 0.06, green: 0.15, blue: 0.27)],     // Deep navy
            [Color(red: 0.08, green: 0.72, blue: 0.65), Color(red: 0.05, green: 0.49, blue: 0.44)],     // Teal
            [Color(red: 0.39, green: 0.45, blue: 0.55), Color(red: 0.28, green: 0.33, blue: 0.42)],     // Slate
            [Color(red: 0.44, green: 0.58, blue: 0.69), Color(red: 0.29, green: 0.48, blue: 0.61)],     // Steel blue
        ]
        let hash = abs(app.info.id.hashValue)
        return gradients[hash % gradients.count]
    }
}
