import Foundation

/// Fetches Northwoods app repos and releases from GitHub API
actor GitHubService {
    private let org = "NorthwoodsCommunityChurch"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetch all repos with avl-tools topic
    /// Uses the org repos endpoint (paginated) instead of the search API,
    /// because the search index can miss repos.
    func fetchAppRepos() async throws -> [AppInfo] {
        var allRepos: [GitHubRepo] = []
        var page = 1

        while true {
            let url = URL(string: "https://api.github.com/orgs/\(org)/repos?per_page=100&page=\(page)")!
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw CanopyError.githubAPIError("Failed to fetch repos")
            }

            let repos = try JSONDecoder().decode([GitHubRepo].self, from: data)
            if repos.isEmpty { break }
            allRepos.append(contentsOf: repos)
            if repos.count < 100 { break }
            page += 1
        }

        // Filter to repos that have the avl-tools topic
        let avlRepos = allRepos.filter { repo in
            repo.topics?.contains("avl-tools") == true
        }

        let excludedRepos: Set<String> = ["Canopy", "avl-media-indexer", "Production-Positions"]
        var apps = avlRepos.filter { !excludedRepos.contains($0.name) }.map { repo in
            let appcastName = appcastFileName(for: repo.name)
            let appcastURL = URL(string: "https://northwoodscommunitychurch.github.io/app-updates/\(appcastName)")

            return AppInfo(
                id: repo.name,
                name: repo.name,
                description: repo.description ?? "A Northwoods app",
                repoURL: repo.htmlURL,
                appcastURL: appcastURL
            )
        }

        // Add Vocalist Positions — lives in Production-Positions repo alongside Camera Positions
        if let prodRepo = avlRepos.first(where: { $0.name == "Production-Positions" }) {
            apps.append(AppInfo(
                id: "vocalist-positions",
                name: "Vocalist Positions",
                description: "Vocalist position assignment display for live production teams",
                repoURL: prodRepo.htmlURL,
                appcastURL: nil
            ))
        }

        return apps
    }

    /// Maps virtual app IDs to their actual repo name and asset prefix
    private static let multiAppRepos: [String: (repo: String, assetPrefix: String)] = [
        "vocalist-positions": (repo: "Production-Positions", assetPrefix: "VocalistPositions"),
    ]

    /// Resolve the actual GitHub repo name for an app ID
    private func resolveRepo(_ repoName: String) -> String {
        Self.multiAppRepos[repoName]?.repo ?? repoName
    }

    /// Resolve the asset prefix filter for an app ID (nil means no filter)
    private func assetPrefix(_ repoName: String) -> String? {
        Self.multiAppRepos[repoName]?.assetPrefix
    }

    /// Fetch the latest release for a repo
    func fetchLatestRelease(repoName: String) async throws -> AppRelease? {
        let actualRepo = resolveRepo(repoName)
        let prefix = assetPrefix(repoName)
        let url = URL(string: "https://api.github.com/repos/\(org)/\(actualRepo)/releases/latest")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        if httpResponse.statusCode == 200 {
            let release = try JSONDecoder.githubDecoder.decode(GitHubRelease.self, from: data)
            if let mapped = mapRelease(release, assetPrefix: prefix) {
                return mapped
            }
        }

        // /releases/latest returned 404 (pre-release only) or release had no zip asset
        // Fall back to fetching all releases and pick the first usable one
        let allReleases = try await fetchReleases(repoName: repoName)
        return allReleases.first
    }

    /// Fetch all releases for a repo
    func fetchReleases(repoName: String) async throws -> [AppRelease] {
        let actualRepo = resolveRepo(repoName)
        let prefix = assetPrefix(repoName)
        let url = URL(string: "https://api.github.com/repos/\(org)/\(actualRepo)/releases?per_page=10")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let releases = try JSONDecoder.githubDecoder.decode([GitHubRelease].self, from: data)
        return releases.compactMap { mapRelease($0, assetPrefix: prefix) }
    }

    private func mapRelease(_ release: GitHubRelease, assetPrefix: String? = nil) -> AppRelease? {
        // Find the zip asset (prefer aarch64), optionally filtered by prefix
        let candidates = release.assets.filter { asset in
            guard asset.name.hasSuffix(".zip") else { return false }
            if let prefix = assetPrefix {
                return asset.name.hasPrefix(prefix)
            }
            return true
        }
        let zipAsset = candidates.first { $0.name.hasSuffix("-aarch64.zip") }
            ?? candidates.first

        guard let asset = zipAsset else { return nil }

        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName

        return AppRelease(
            id: release.tagName,
            version: version,
            buildNumber: nil,
            downloadURL: asset.browserDownloadURL,
            fileSize: asset.size,
            publishedAt: release.publishedAt,
            releaseNotes: release.body,
            isPrerelease: release.prerelease
        )
    }

    private func appcastFileName(for repoName: String) -> String {
        // Map repo names to appcast file names
        // e.g. "avl-computer-dashboard" -> "appcast-dashboard.xml"
        // This follows the convention in SPARKLE-GUIDE.md
        let appName = repoName
            .replacingOccurrences(of: "avl-", with: "")
            .replacingOccurrences(of: "-", with: "")
        return "appcast-\(appName).xml"
    }
}

// MARK: - GitHub API Models

private struct GitHubRepo: Decodable {
    let name: String
    let description: String?
    let htmlURL: URL
    let topics: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case htmlURL = "html_url"
        case topics
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

extension JSONDecoder {
    static let githubDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = formatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        return decoder
    }()
}
