import Foundation

enum CanopyError: LocalizedError {
    case githubAPIError(String)
    case extractionFailed(String)
    case installFailed(String)
    case noDownloadAvailable
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .githubAPIError(let msg): return "GitHub API error: \(msg)"
        case .extractionFailed(let msg): return "Extraction failed: \(msg)"
        case .installFailed(let msg): return "Install failed: \(msg)"
        case .noDownloadAvailable: return "No download available for this app"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        }
    }
}
