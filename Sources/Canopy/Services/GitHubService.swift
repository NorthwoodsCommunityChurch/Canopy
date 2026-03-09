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

    /// Fetch all repos with avl-tools or lighting-tools topic
    func fetchAppRepos() async throws -> [AppInfo] {
        let url = URL(string: "https://api.github.com/search/repositories?q=org:\(org)+topic:avl-tools&per_page=100")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CanopyError.githubAPIError("Failed to fetch repos")
        }

        let searchResult = try JSONDecoder().decode(GitHubSearchResult.self, from: data)

        let excludedRepos: Set<String> = ["Canopy", "avl-media-indexer"]
        return searchResult.items.filter { !excludedRepos.contains($0.name) }.map { repo in
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
    }

    /// Fetch the latest release for a repo
    func fetchLatestRelease(repoName: String) async throws -> AppRelease? {
        let url = URL(string: "https://api.github.com/repos/\(org)/\(repoName)/releases/latest")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        if httpResponse.statusCode == 404 {
            return nil // No releases yet
        }

        guard httpResponse.statusCode == 200 else {
            throw CanopyError.githubAPIError("Failed to fetch release for \(repoName)")
        }

        let release = try JSONDecoder.githubDecoder.decode(GitHubRelease.self, from: data)
        return mapRelease(release)
    }

    /// Fetch all releases for a repo
    func fetchReleases(repoName: String) async throws -> [AppRelease] {
        let url = URL(string: "https://api.github.com/repos/\(org)/\(repoName)/releases?per_page=10")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let releases = try JSONDecoder.githubDecoder.decode([GitHubRelease].self, from: data)
        return releases.compactMap { mapRelease($0) }
    }

    private func mapRelease(_ release: GitHubRelease) -> AppRelease? {
        // Find the zip asset (prefer aarch64)
        let zipAsset = release.assets.first { $0.name.hasSuffix("-aarch64.zip") }
            ?? release.assets.first { $0.name.hasSuffix(".zip") }

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

private struct GitHubSearchResult: Decodable {
    let totalCount: Int
    let items: [GitHubRepo]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

private struct GitHubRepo: Decodable {
    let name: String
    let description: String?
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case htmlURL = "html_url"
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
