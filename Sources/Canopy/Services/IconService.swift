import Foundation
import AppKit

/// Fetches and caches app icons from GitHub repos or installed apps
actor IconService {
    private let session = URLSession.shared
    private let org = "NorthwoodsCommunityChurch"
    private let cacheDir: URL
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("Canopy/IconCache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Get icon for an app — checks cache, then GitHub, then installed app
    func icon(for app: AppInfo, installedAppName: String? = nil) async -> NSImage? {
        if let cached = loadFromCache(appID: app.id) {
            return cached
        }

        if let existing = inFlightTasks[app.id] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> {
            // Try GitHub first — icons are now full-bleed squares
            if let remote = await fetchIconFromGitHub(repoName: app.id) {
                saveToCache(image: remote, appID: app.id)
                return remote
            }

            // Fall back to installed app icon
            if let installed = iconFromInstalledApp(app: app, installedAppName: installedAppName) {
                saveToCache(image: installed, appID: app.id)
                return installed
            }

            return nil
        }

        inFlightTasks[app.id] = task
        let result = await task.value
        inFlightTasks[app.id] = nil
        return result
    }

    // MARK: - Installed App Icons

    private func iconFromInstalledApp(app: AppInfo, installedAppName: String?) -> NSImage? {
        var namesToTry: [String] = []

        if let name = installedAppName {
            namesToTry.append(name)
        }
        namesToTry.append(app.displayName)
        let camelCase = app.displayName.replacingOccurrences(of: " ", with: "")
        namesToTry.append(camelCase)

        // Scan /Applications for exact case-insensitive matches
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") {
            let displayLower = app.displayName.lowercased()
            let camelLower = camelCase.lowercased()
            for item in contents where item.hasSuffix(".app") {
                let appName = String(item.dropLast(4))
                let lower = appName.lowercased()
                if lower == displayLower || lower == camelLower {
                    namesToTry.append(appName)
                }
            }
        }

        for name in namesToTry {
            let appPath = "/Applications/\(name).app"
            guard FileManager.default.fileExists(atPath: appPath) else { continue }

            if let bundleIcon = iconFromAppBundle(appPath: appPath) {
                return bundleIcon
            }

            let icon = NSWorkspace.shared.icon(forFile: appPath)
            if icon.representations.contains(where: { $0.pixelsWide > 32 }) {
                return icon
            }
        }

        return nil
    }

    private func iconFromAppBundle(appPath: String) -> NSImage? {
        let bundle = Bundle(path: appPath)
        let iconFileName = bundle?.infoDictionary?["CFBundleIconFile"] as? String ?? "AppIcon"
        let iconName = iconFileName.hasSuffix(".icns") ? String(iconFileName.dropLast(5)) : iconFileName
        let icnsPath = "\(appPath)/Contents/Resources/\(iconName).icns"

        if FileManager.default.fileExists(atPath: icnsPath),
           let image = NSImage(contentsOfFile: icnsPath) {
            return image
        }
        return nil
    }

    // MARK: - GitHub Icon Fetching

    /// Maps virtual app IDs to their actual repo and path prefix for icons
    private static let multiAppRepos: [String: (repo: String, pathPrefix: String)] = [
        "vocalist-positions": (repo: "Production-Positions", pathPrefix: "vocalist-positions/"),
    ]

    private func fetchIconFromGitHub(repoName: String) async -> NSImage? {
        // Use API to find actual icon files in the repo tree
        if let image = await fetchIconViaAPI(repoName: repoName) {
            return image
        }
        return await fetchIconByGuessing(repoName: repoName)
    }

    /// Search the repo tree via GitHub API to find icon PNGs
    private func fetchIconViaAPI(repoName: String) async -> NSImage? {
        let actualRepo = Self.multiAppRepos[repoName]?.repo ?? repoName
        let pathPrefix = Self.multiAppRepos[repoName]?.pathPrefix
        for branch in ["main", "master"] {
            let urlString = "https://api.github.com/repos/\(org)/\(actualRepo)/git/trees/\(branch)?recursive=1"
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { continue }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tree = json["tree"] as? [[String: Any]] else { continue }

                // Find icon PNGs, preferring larger sizes, excluding build artifacts
                let iconPaths = tree.compactMap { item -> (String, Int)? in
                    guard let path = item["path"] as? String,
                          path.contains("AppIcon.appiconset/icon_"),
                          path.hasSuffix(".png"),
                          !path.contains(".build/"),
                          !path.contains("/build/"),
                          !path.contains("checkouts/"),
                          !path.contains("DerivedData/") else { return nil }

                    // If this is a multi-app repo, only match icons under the right subfolder
                    if let prefix = pathPrefix, !path.hasPrefix(prefix) { return nil }

                    let size: Int
                    if path.contains("512x512") { size = 512 }
                    else if path.contains("256x256") { size = 256 }
                    else if path.contains("128x128") { size = 128 }
                    else { size = 0 }

                    return (path, size)
                }
                .sorted { $0.1 > $1.1 }

                for (path, _) in iconPaths.prefix(3) {
                    let rawURL = "https://raw.githubusercontent.com/\(org)/\(actualRepo)/\(branch)/\(path)"
                    guard let iconURL = URL(string: rawURL) else { continue }

                    if let (iconData, iconResp) = try? await session.data(from: iconURL),
                       let iconHTTP = iconResp as? HTTPURLResponse,
                       iconHTTP.statusCode == 200,
                       let image = NSImage(data: iconData), image.isValid {
                        return image
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Fallback: guess common icon paths
    private func fetchIconByGuessing(repoName: String) async -> NSImage? {
        let baseName = repoName.replacingOccurrences(of: "avl-", with: "")
        let camelCase = baseName.split(separator: "-").map { $0.capitalized }.joined()

        let prefixes = [
            "", "\(camelCase)/", "\(camelCase)/Resources/", "Resources/",
            "Sources/\(camelCase)/Resources/", "Icons/",
        ]
        let iconFiles = [
            "icon_256x256.png", "icon_128x128.png",
            "icon_256x256@2x.png", "icon_128x128@2x.png",
        ]

        for prefix in prefixes {
            for file in iconFiles {
                let path = "\(prefix)Assets.xcassets/AppIcon.appiconset/\(file)"
                for branch in ["main", "master"] {
                    let urlString = "https://raw.githubusercontent.com/\(org)/\(repoName)/\(branch)/\(path)"
                    guard let url = URL(string: urlString) else { continue }

                    do {
                        let (data, response) = try await session.data(from: url)
                        guard let httpResponse = response as? HTTPURLResponse,
                              httpResponse.statusCode == 200 else { continue }

                        if let image = NSImage(data: data), image.isValid {
                            return image
                        }
                    } catch {
                        continue
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Disk Cache

    private func cacheURL(for appID: String) -> URL {
        cacheDir.appendingPathComponent("\(appID).png")
    }

    private func loadFromCache(appID: String) -> NSImage? {
        let url = cacheURL(for: appID)
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    private func saveToCache(image: NSImage, appID: String) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? pngData.write(to: cacheURL(for: appID))
    }

    /// Clear the icon cache
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
