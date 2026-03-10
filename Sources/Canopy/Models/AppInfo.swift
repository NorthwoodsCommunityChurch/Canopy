import Foundation

/// Represents a Northwoods app available in Canopy
struct AppInfo: Identifiable, Hashable, Codable {
    let id: String              // GitHub repo name (e.g. "avl-computer-dashboard")
    let name: String            // Display name (e.g. "Computer Dashboard")
    let description: String     // Repo description from GitHub
    let repoURL: URL            // GitHub repo URL
    let appcastURL: URL?        // Sparkle appcast URL if known

    var displayName: String {
        // Convert repo name to display name: "avl-computer-dashboard" -> "Computer Dashboard"
        // All-uppercase segments (like "MIDI") are preserved as-is
        name.replacingOccurrences(of: "avl-", with: "")
            .split(separator: "-")
            .map { segment in
                let s = String(segment)
                return s == s.uppercased() && s.count > 1 ? s : s.capitalized
            }
            .joined(separator: " ")
    }
}

/// Represents a specific release/version of an app
struct AppRelease: Identifiable, Codable {
    let id: String              // Tag name (e.g. "v1.0.5")
    let version: String         // Marketing version
    let buildNumber: String?    // Build number from appcast
    let downloadURL: URL        // Zip download URL
    let fileSize: Int64?
    let publishedAt: Date?
    let releaseNotes: String?
    let isPrerelease: Bool
}

/// The installation state of an app on this machine
enum InstallState: Equatable {
    case notInstalled
    case installed(version: String)
    case updateAvailable(installed: String, latest: String)
    case downloading(progress: Double)
    case installing
    case error(String)

    var isInstalled: Bool {
        switch self {
        case .installed, .updateAvailable:
            return true
        default:
            return false
        }
    }
}

/// Combined model for display: app info + its current state
struct CatalogApp: Identifiable {
    let info: AppInfo
    var latestRelease: AppRelease?
    var installState: InstallState
    var installedAppName: String?  // Actual .app folder name (e.g. "Dashboard", "WhisperVerses")

    var id: String { info.id }
}
