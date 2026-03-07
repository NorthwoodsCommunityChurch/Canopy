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
            let installed = await installer.findInstalledNorthwoodsApps()

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

                    // Determine install state
                    let appName = guessAppName(from: catalog[index].info)
                    if let installedVersion = installed[appName] {
                        let latestVersion = appcastItem?.shortVersionString ?? release?.version ?? installedVersion
                        if latestVersion != installedVersion {
                            catalog[index].installState = .updateAvailable(installed: installedVersion, latest: latestVersion)
                        } else {
                            catalog[index].installState = .installed(version: installedVersion)
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
            let appName = guessAppName(from: app.info)
            try await installer.installApp(appURL: appURL, appName: appName)

            // Clean up temp files
            await installer.cleanup(tempURL: zipURL)

            // Check installed version
            let version = await installer.installedVersion(appName: appName) ?? release.version
            updateState(for: app.info.id, state: .installed(version: version))
        } catch {
            updateState(for: app.info.id, state: .error(error.localizedDescription))
        }
    }

    /// Open an installed app
    func openApp(_ app: CatalogApp) {
        let appName = guessAppName(from: app.info)
        let appPath = "/Applications/\(appName).app"
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
    }

    /// Uninstall an app
    func uninstallApp(_ app: CatalogApp) async {
        let appName = guessAppName(from: app.info)
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

    /// Guess the .app name from repo info
    /// e.g. "avl-computer-dashboard" -> "Computer Dashboard"
    /// This matches what the build script names the .app bundle
    private func guessAppName(from info: AppInfo) -> String {
        info.displayName
    }
}
