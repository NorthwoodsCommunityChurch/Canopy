import Foundation
import SwiftUI
import AppKit

// MARK: - Catalog Cache

private struct CachedCatalog: Codable {
    let fetchedAt: Date
    let apps: [AppInfo]
    let releases: [String: AppRelease]  // keyed by app id
}

private let cacheURL: URL = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Canopy/catalog-cache.json")
}()

private let cacheTTL: TimeInterval = 30 * 60  // 30 minutes

private func loadCache() -> CachedCatalog? {
    guard let data = try? Data(contentsOf: cacheURL),
          let cache = try? JSONDecoder().decode(CachedCatalog.self, from: data),
          Date().timeIntervalSince(cache.fetchedAt) < cacheTTL else { return nil }
    return cache
}

private func saveCache(_ cache: CachedCatalog) {
    guard let data = try? JSONEncoder().encode(cache) else { return }
    try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheURL)
}

// MARK: - CatalogViewModel

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
    /// Pass forceRefresh: true to bypass the cache (e.g. from the refresh button)
    func loadCatalog(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil

        do {
            // Resolve repo infos + releases (from cache or GitHub)
            let (repoInfos, cachedReleases) = try await fetchCatalogData(forceRefresh: forceRefresh)

            // Initialize catalog with repos
            var catalog: [CatalogApp] = repoInfos.map { info in
                CatalogApp(info: info, latestRelease: cachedReleases[info.id], installState: .notInstalled)
            }

            // Check installed versions
            let installedApps = await installer.findInstalledNorthwoodsApps()

            // Match installed apps to catalog entries and check updates
            for (index, app) in catalog.enumerated() {
                if let match = findInstalledMatch(for: app.info, in: installedApps) {
                    catalog[index].installedAppName = match.folderName
                    let installedVersion = match.version
                    if let release = catalog[index].latestRelease, release.version != installedVersion {
                        catalog[index].installState = .updateAvailable(installed: installedVersion, latest: release.version)
                    } else {
                        catalog[index].installState = .installed(version: installedVersion)
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

    /// Fetch repo list and releases, using cache when available
    private func fetchCatalogData(forceRefresh: Bool) async throws -> ([AppInfo], [String: AppRelease]) {
        if !forceRefresh, let cache = loadCache() {
            return (cache.apps, cache.releases)
        }

        let repoInfos = try await github.fetchAppRepos()
        var releases: [String: AppRelease] = [:]

        // Fetch releases and appcast updates in parallel
        await withTaskGroup(of: (String, AppRelease?, AppcastItem?)?.self) { group in
            for app in repoInfos {
                group.addTask { [github, appcast] in
                    let release = try? await github.fetchLatestRelease(repoName: app.id)
                    var appcastItem: AppcastItem?
                    if let appcastURL = app.appcastURL {
                        appcastItem = try? await appcast.checkForUpdate(appcastURL: appcastURL)
                    }
                    // Prefer appcast version for the display version if available
                    if let item = appcastItem, let release = release {
                        let updatedRelease = AppRelease(
                            id: release.id,
                            version: item.shortVersionString ?? release.version,
                            buildNumber: item.version,
                            downloadURL: release.downloadURL,
                            fileSize: release.fileSize,
                            publishedAt: release.publishedAt,
                            releaseNotes: release.releaseNotes,
                            isPrerelease: release.isPrerelease
                        )
                        return (app.id, updatedRelease, appcastItem)
                    }
                    return (app.id, release, appcastItem)
                }
            }

            for await result in group {
                guard let (id, release, _) = result else { continue }
                releases[id] = release
            }
        }

        saveCache(CachedCatalog(fetchedAt: Date(), apps: repoInfos, releases: releases))
        return (repoInfos, releases)
    }

    /// Load icons for all apps in the catalog
    func loadIcons() async {
        await withTaskGroup(of: (String, NSImage?).self) { group in
            for app in apps {
                group.addTask { [iconService] in
                    let image = await iconService.icon(for: app.info, installedAppName: app.installedAppName)
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

    /// Find the actual path of an installed app (checks Northwoods folder first, then legacy /Applications)
    private func installedAppPath(appName: String) -> String? {
        let northwoodsPath = "/Applications/Canopy/\(appName).app"
        if FileManager.default.fileExists(atPath: northwoodsPath) {
            return northwoodsPath
        }
        let legacyPath = "/Applications/\(appName).app"
        if FileManager.default.fileExists(atPath: legacyPath) {
            return legacyPath
        }
        return nil
    }

    /// Open an installed app
    func openApp(_ app: CatalogApp) {
        guard let appName = app.installedAppName,
              let appPath = installedAppPath(appName: appName) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
    }

    /// Uninstall an app
    func uninstallApp(_ app: CatalogApp) async {
        guard let appName = app.installedAppName,
              let appPath = installedAppPath(appName: appName) else { return }

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
