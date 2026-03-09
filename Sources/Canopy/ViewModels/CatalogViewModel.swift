import Foundation
import SwiftUI
import AppKit

@Observable
final class CatalogViewModel {
    var apps: [CatalogApp] = []
    var isLoading = false
    var errorMessage: String?
    var searchText = ""
    var appIcons: [String: NSImage] = [:]

    private let github = GitHubService()
    private let appcast = AppcastService()
    private let installer = InstallService()
    private let iconService = IconService()

    var filteredApps: [CatalogApp] {
        if searchText.isEmpty {
            return apps.sorted { $0.info.displayName < $1.info.displayName }
        }
        return apps.filter {
            $0.info.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.info.description.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.info.displayName < $1.info.displayName }
    }

    var installedCount: Int {
        apps.filter { $0.installState.isInstalled }.count
    }

    var updatesAvailableCount: Int {
        apps.filter {
            if case .updateAvailable = $0.installState { return true }
            return false
        }.count
    }

    /// Load the full catalog: fetch repos, check installed versions, check for updates
    func loadCatalog() async {
        isLoading = true
        errorMessage = nil

        do {
            let repoInfos = try await github.fetchAppRepos()

            // Initialize catalog with repos
            var catalog: [CatalogApp] = repoInfos.map { info in
                CatalogApp(info: info, latestRelease: nil, installState: .notInstalled)
            }

            // Check installed versions
            let installedApps = await installer.findInstalledNorthwoodsApps()

            // Match installed apps to catalog entries
            for (index, app) in catalog.enumerated() {
                if let match = findInstalledMatch(for: app.info, in: installedApps) {
                    catalog[index].installState = .installed(version: match.version)
                    catalog[index].installedAppName = match.folderName
                }
            }

            // Fetch releases and check updates in parallel
            await withTaskGroup(of: (Int, AppRelease?, AppcastItem?)?.self) { group in
                for (index, app) in catalog.enumerated() {
                    group.addTask { [github, appcast] in
                        let release = try? await github.fetchLatestRelease(repoName: app.info.id)
                        var appcastItem: AppcastItem?
                        if let appcastURL = app.info.appcastURL {
                            appcastItem = try? await appcast.checkForUpdate(appcastURL: appcastURL)
                        }
                        return (index, release, appcastItem)
                    }
                }

                for await result in group {
                    guard let (index, release, appcastItem) = result else { continue }
                    catalog[index].latestRelease = release

                    // Check if update is available for installed apps
                    if case .installed(let installedVersion) = catalog[index].installState {
                        let latestVersion = appcastItem?.shortVersionString ?? release?.version ?? installedVersion
                        if latestVersion != installedVersion {
                            catalog[index].installState = .updateAvailable(installed: installedVersion, latest: latestVersion)
                        }
                    }
                }
            }

            await MainActor.run {
                self.apps = catalog
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// Load icons for all apps in the catalog
    func loadIcons() async {
        await withTaskGroup(of: (String, NSImage?).self) { group in
            for app in apps {
                group.addTask { [iconService] in
                    let image = await iconService.icon(for: app.info)
                    return (app.info.id, image)
                }
            }

            for await (id, image) in group {
                if let image {
                    await MainActor.run {
                        self.appIcons[id] = image
                    }
                }
            }
        }
    }

    /// Install or update an app
    func installApp(_ app: CatalogApp) async {
        guard let release = app.latestRelease else { return }

        // Update state to downloading
        updateState(for: app.info.id, state: .downloading(progress: 0))

        do {
            let zipURL = try await installer.downloadApp(from: release.downloadURL) { [weak self] progress in
                Task { @MainActor in
                    self?.updateState(for: app.info.id, state: .downloading(progress: progress))
                }
            }

            updateState(for: app.info.id, state: .installing)

            let appURL = try await installer.extractApp(zipURL: zipURL)
            // Use the actual .app name from the extracted bundle
            let extractedAppName = appURL.deletingPathExtension().lastPathComponent
            try await installer.installApp(appURL: appURL, appName: extractedAppName)

            // Clean up temp files
            await installer.cleanup(tempURL: zipURL)

            // Store the real app name and check installed version
            if let index = apps.firstIndex(where: { $0.info.id == app.info.id }) {
                apps[index].installedAppName = extractedAppName
            }
            let version = await installer.installedVersion(appName: extractedAppName) ?? release.version
            updateState(for: app.info.id, state: .installed(version: version))
        } catch {
            updateState(for: app.info.id, state: .error(error.localizedDescription))
        }
    }

    /// Open an installed app
    func openApp(_ app: CatalogApp) {
        guard let appName = app.installedAppName else { return }
        let appPath = "/Applications/\(appName).app"
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
    }

    /// Uninstall an app
    func uninstallApp(_ app: CatalogApp) async {
        guard let appName = app.installedAppName else { return }
        let appPath = "/Applications/\(appName).app"

        // Quit if running
        let runningApps = NSWorkspace.shared.runningApplications
        for runningApp in runningApps {
            if runningApp.localizedName == appName {
                runningApp.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        do {
            try FileManager.default.removeItem(atPath: appPath)
            updateState(for: app.info.id, state: .notInstalled)
        } catch {
            updateState(for: app.info.id, state: .error("Failed to uninstall: \(error.localizedDescription)"))
        }
    }

    private func updateState(for id: String, state: InstallState) {
        if let index = apps.firstIndex(where: { $0.info.id == id }) {
            apps[index].installState = state
        }
    }

    /// Match a repo to an installed app using normalized name comparison
    /// Repo names like "avl-computer-dashboard" need to match app folders like "Dashboard"
    private func findInstalledMatch(for info: AppInfo, in installed: [InstallService.InstalledApp]) -> InstallService.InstalledApp? {
        let repoNormalized = normalize(info.id)

        for app in installed {
            let folderNormalized = normalize(app.folderName)
            let bundleNormalized = normalize(app.bundleID)

            // Exact normalized match
            if repoNormalized == folderNormalized { return app }

            // Repo name contains the app folder name or vice versa
            if repoNormalized.contains(folderNormalized) || folderNormalized.contains(repoNormalized) { return app }

            // Bundle ID contains the repo name (minus "avl-" prefix)
            let repoBase = info.id.replacingOccurrences(of: "avl-", with: "")
            let baseNormalized = normalize(repoBase)
            if bundleNormalized.contains(baseNormalized) || baseNormalized.contains(folderNormalized) { return app }
        }

        return nil
    }

    /// Normalize a string for fuzzy matching: lowercase, remove separators
    private func normalize(_ string: String) -> String {
        string.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}
