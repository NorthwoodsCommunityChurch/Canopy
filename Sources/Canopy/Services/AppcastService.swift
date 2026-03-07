import Foundation

/// Parses Sparkle appcast XML feeds to check for available updates
actor AppcastService {
    private let session = URLSession.shared

    /// Check the appcast for the latest version info
    func checkForUpdate(appcastURL: URL) async throws -> AppcastItem? {
        let (data, response) = try await session.data(from: appcastURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        let parser = AppcastParser(data: data)
        let items = parser.parse()
        return items.first // Newest item is first in appcast
    }
}

/// Represents a single item from a Sparkle appcast
struct AppcastItem {
    let title: String?
    let version: String          // sparkle:version (build number)
    let shortVersionString: String? // sparkle:shortVersionString (marketing version)
    let downloadURL: URL?
    let edSignature: String?
    let length: Int64?
    let minimumSystemVersion: String?
    let releaseNotesHTML: String?
}

/// XML parser for Sparkle appcast feeds
private class AppcastParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var items: [AppcastItem] = []

    // Parsing state
    private var inItem = false
    private var inDescription = false
    private var currentElement = ""
    private var currentTitle = ""
    private var currentVersion = ""
    private var currentShortVersion = ""
    private var currentDownloadURL: URL?
    private var currentEdSignature = ""
    private var currentLength: Int64 = 0
    private var currentMinSystemVersion = ""
    private var currentDescription = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> [AppcastItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "item" {
            inItem = true
            resetCurrentItem()
        } else if elementName == "enclosure" && inItem {
            if let urlString = attributeDict["url"], let url = URL(string: urlString) {
                currentDownloadURL = url
            }
            if let sig = attributeDict["sparkle:edSignature"] {
                currentEdSignature = sig
            }
            if let len = attributeDict["length"], let length = Int64(len) {
                currentLength = length
            }
        } else if elementName == "description" && inItem {
            inDescription = true
            currentDescription = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }

        if inDescription {
            currentDescription += string
        } else {
            switch currentElement {
            case "title":
                currentTitle += string
            case "sparkle:version":
                currentVersion += string
            case "sparkle:shortVersionString":
                currentShortVersion += string
            case "sparkle:minimumSystemVersion":
                currentMinSystemVersion += string
            default:
                break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inDescription, let text = String(data: CDATABlock, encoding: .utf8) {
            currentDescription += text
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "description" {
            inDescription = false
        }

        if elementName == "item" && inItem {
            let item = AppcastItem(
                title: currentTitle.isEmpty ? nil : currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                version: currentVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                shortVersionString: currentShortVersion.isEmpty ? nil : currentShortVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                downloadURL: currentDownloadURL,
                edSignature: currentEdSignature.isEmpty ? nil : currentEdSignature,
                length: currentLength > 0 ? currentLength : nil,
                minimumSystemVersion: currentMinSystemVersion.isEmpty ? nil : currentMinSystemVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                releaseNotesHTML: currentDescription.isEmpty ? nil : currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            items.append(item)
            inItem = false
        }
    }

    private func resetCurrentItem() {
        currentTitle = ""
        currentVersion = ""
        currentShortVersion = ""
        currentDownloadURL = nil
        currentEdSignature = ""
        currentLength = 0
        currentMinSystemVersion = ""
        currentDescription = ""
    }
}
