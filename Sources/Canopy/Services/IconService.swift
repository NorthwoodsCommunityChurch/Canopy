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

    /// Get icon for an app — checks cache, then installed app, then GitHub
    func icon(for app: AppInfo) async -> NSImage? {
        // Check memory/disk cache first
        if let cached = loadFromCache(appID: app.id) {
            return cached
        }

        // Deduplicate in-flight requests
        if let existing = inFlightTasks[app.id] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> {
            // Try installed app icon first
            if let installed = iconFromInstalledApp(appName: app.displayName) {
                saveToCache(image: installed, appID: app.id)
                return installed
            }

            // Try fetching from GitHub
            if let remote = await fetchIconFromGitHub(repoName: app.id) {
                saveToCache(image: remote, appID: app.id)
                return remote
            }

            return nil
        }

        inFlightTasks[app.id] = task
        let result = await task.value
        inFlightTasks[app.id] = nil
        return result
    }

    /// Try to get the icon from an installed app in /Applications
    private func iconFromInstalledApp(appName: String) -> NSImage? {
        let appPath = "/Applications/\(appName).app"
        guard FileManager.default.fileExists(atPath: appPath) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        // NSWorkspace returns a generic icon if the app doesn't have one — check size
        // The generic icon is 32x32, real icons are typically larger
        guard icon.representations.contains(where: { $0.pixelsWide > 32 }) else {
            return icon // Still return it, better than nothing
        }
        return icon
    }

    /// Fetch icon PNG from GitHub raw content, trying multiple known paths
    private func fetchIconFromGitHub(repoName: String) async -> NSImage? {
        // Derive possible app-name subfolder names from the repo name
        let baseName = repoName
            .replacingOccurrences(of: "avl-", with: "")

        // CamelCase version: "computer-dashboard" -> "ComputerDashboard"
        let camelCase = baseName
            .split(separator: "-")
            .map { $0.capitalized }
            .joined()

        // Try multiple common icon paths in order of likelihood
        let iconPaths = [
            // XcodeGen / standard layout
            "Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png",
            "Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png",
            "Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png",
            // App-name subfolder (Xcode default)
            "\(camelCase)/Assets.xcassets/AppIcon.appiconset/icon_128x128.png",
            "\(camelCase)/Assets.xcassets/AppIcon.appiconset/icon_256x256.png",
            // Nested Resources
            "\(camelCase)/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png",
            "\(camelCase)/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png",
            // Root-level asset catalog
            "Assets.xcassets/AppIcon.appiconset/icon_128x128.png",
            "Assets.xcassets/AppIcon.appiconset/icon_256x256.png",
            // .icns file (compiled icon)
            "Resources/AppIcon.icns",
        ]

        for path in iconPaths {
            for branch in ["main", "master"] {
                let urlString = "https://raw.githubusercontent.com/\(org)/\(repoName)/\(branch)/\(path)"
                guard let url = URL(string: urlString) else { continue }

                do {
                    let (data, response) = try await session.data(from: url)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continue
                    }

                    if let image = NSImage(data: data), image.isValid {
                        return image
                    }
                } catch {
                    continue
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
