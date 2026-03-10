import Foundation
import AppKit

/// Handles downloading, extracting, and installing apps to /Applications/Northwoods
actor InstallService {
    private let fileManager = FileManager.default
    private let applicationsPath = "/Applications/Canopy"
    private let legacyApplicationsPath = "/Applications"

    /// Download a zip from a URL with progress reporting
    func downloadApp(from url: URL, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("Canopy-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destURL = tempDir.appendingPathComponent(url.lastPathComponent)

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        let totalBytes = response.expectedContentLength
        var receivedBytes: Int64 = 0
        var data = Data()
        if totalBytes > 0 {
            data.reserveCapacity(Int(totalBytes))
        }

        for try await byte in asyncBytes {
            data.append(byte)
            receivedBytes += 1
            if totalBytes > 0, receivedBytes % 65536 == 0 {
                let progress = Double(receivedBytes) / Double(totalBytes)
                progressHandler(progress)
            }
        }

        progressHandler(1.0)
        try data.write(to: destURL)
        return destURL
    }

    /// Extract a zip file and find the .app bundle inside
    func extractApp(zipURL: URL) async throws -> URL {
        let extractDir = zipURL.deletingLastPathComponent().appendingPathComponent("extracted")
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, extractDir.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CanopyError.extractionFailed("ditto exited with status \(process.terminationStatus)")
        }

        // Find the .app bundle
        let contents = try fileManager.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            // Check one level deeper (some zips nest the app)
            for dir in contents where dir.hasDirectoryPath {
                let subContents = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                if let app = subContents.first(where: { $0.pathExtension == "app" }) {
                    return app
                }
            }
            throw CanopyError.extractionFailed("No .app bundle found in zip")
        }

        return appBundle
    }

    /// Install an app to /Applications/Northwoods, replacing existing version if present
    func installApp(appURL: URL, appName: String) async throws {
        // Create /Applications/Northwoods if it doesn't exist
        if !fileManager.fileExists(atPath: applicationsPath) {
            try fileManager.createDirectory(atPath: applicationsPath, withIntermediateDirectories: true)
        }

        let destURL = URL(fileURLWithPath: applicationsPath).appendingPathComponent("\(appName).app")

        // Quit the app if it's running
        await quitApp(named: appName)

        // Remove existing version (check both Northwoods and legacy /Applications)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        let legacyURL = URL(fileURLWithPath: legacyApplicationsPath).appendingPathComponent("\(appName).app")
        if fileManager.fileExists(atPath: legacyURL.path) {
            try fileManager.removeItem(at: legacyURL)
        }

        // Clear quarantine attributes from the extracted app
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-cr", appURL.path]
        try xattrProcess.run()
        xattrProcess.waitUntilExit()

        // Move to /Applications/Northwoods
        try fileManager.moveItem(at: appURL, to: destURL)
    }

    /// Find the actual path where an app is installed (Northwoods folder or legacy /Applications)
    private func installedAppPath(appName: String) -> URL? {
        let northwoodsPath = URL(fileURLWithPath: applicationsPath).appendingPathComponent("\(appName).app")
        if fileManager.fileExists(atPath: northwoodsPath.path) {
            return northwoodsPath
        }
        let legacyPath = URL(fileURLWithPath: legacyApplicationsPath).appendingPathComponent("\(appName).app")
        if fileManager.fileExists(atPath: legacyPath.path) {
            return legacyPath
        }
        return nil
    }

    /// Check what version of an app is installed
    func installedVersion(appName: String) -> String? {
        guard let appPath = installedAppPath(appName: appName) else { return nil }
        let plistPath = appPath.appendingPathComponent("Contents/Info.plist")

        guard let plistData = fileManager.contents(atPath: plistPath.path),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        return plist["CFBundleShortVersionString"] as? String
    }

    /// Get the build number of an installed app
    func installedBuildNumber(appName: String) -> String? {
        guard let appPath = installedAppPath(appName: appName) else { return nil }
        let plistPath = appPath.appendingPathComponent("Contents/Info.plist")

        guard let plistData = fileManager.contents(atPath: plistPath.path),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        return plist["CFBundleVersion"] as? String
    }

    /// Represents an installed app found in /Applications
    struct InstalledApp {
        let folderName: String    // e.g. "WhisperVerses", "Limbus Live", "Dashboard"
        let bundleID: String
        let version: String
    }

    /// Find all Northwoods apps currently installed (checks both /Applications/Northwoods and /Applications)
    /// Matches by bundle ID prefixes known to be used by Northwoods apps
    func findInstalledNorthwoodsApps() -> [InstalledApp] {
        let knownPrefixes = [
            "org.northwoodschurch.",
            "org.northwoodscc.",
            "com.northwoodschurch.",
            "com.northwoods.",
            "com.computerdash.",
        ]

        var installed: [InstalledApp] = []
        var seenBundleIDs: Set<String> = []

        // Scan both Northwoods folder and legacy /Applications
        for searchPath in [applicationsPath, legacyApplicationsPath] {
            guard let apps = try? fileManager.contentsOfDirectory(atPath: searchPath) else {
                continue
            }

            for appFolder in apps where appFolder.hasSuffix(".app") {
                let plistPath = "\(searchPath)/\(appFolder)/Contents/Info.plist"
                guard let plistData = fileManager.contents(atPath: plistPath),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      knownPrefixes.contains(where: { bundleID.hasPrefix($0) }),
                      !seenBundleIDs.contains(bundleID) else {
                    continue
                }

                seenBundleIDs.insert(bundleID)
                let version = plist["CFBundleShortVersionString"] as? String ?? "unknown"
                let folderName = appFolder.replacingOccurrences(of: ".app", with: "")
                installed.append(InstalledApp(folderName: folderName, bundleID: bundleID, version: version))
            }
        }

        return installed
    }

    /// Quit a running app by name
    private func quitApp(named appName: String) async {
        await MainActor.run {
            let runningApps = NSWorkspace.shared.runningApplications
            for app in runningApps {
                if app.localizedName == appName {
                    app.terminate()
                }
            }
        }
        // Brief pause to let the app quit
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Clean up temp files
    func cleanup(tempURL: URL) {
        // Remove the parent temp directory
        let parentDir = tempURL.deletingLastPathComponent()
        try? fileManager.removeItem(at: parentDir)
    }
}
