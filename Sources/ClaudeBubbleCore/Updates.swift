import Foundation

/// A release version like "0.1.10" (a leading "v" is fine), compared part by part as numbers.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    private func part(_ i: Int) -> Int { i < parts.count ? parts[i] : 0 }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) where a.part(i) != b.part(i) { return a.part(i) < b.part(i) }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The latest GitHub release, as much as an update needs: its version, the app's zip, the checksum published in its
/// notes (the download must match it), and the notes' "What's new".
public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let version: AppVersion
    public let zip: URL
    public let sha256: String
    public let whatsNew: String
    public let page: URL

    /// From `GET /repos/{owner}/{repo}/releases/latest`. Nil for drafts, pre-releases, or anything without the app's
    /// zip and a checksum to check it against.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["draft"] as? Bool != true, root["prerelease"] as? Bool != true,
              let tag = root["tag_name"] as? String, let version = AppVersion(tag),
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = root["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: {
            let name = $0["name"] as? String ?? ""
            return name.hasPrefix("ClaudeBubble-") && name.hasSuffix(".zip")
        }).flatMap({ ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }) else { return nil }
        let body = root["body"] as? String ?? ""
        let re = try! NSRegularExpression(pattern: #"SHA-256:\s*`?([0-9a-fA-F]{64})`?"#)
        guard let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let r = Range(m.range(at: 1), in: body) else { return nil }
        return ReleaseInfo(tag: tag, version: version, zip: zip, sha256: body[r].lowercased(),
                           whatsNew: whatsNew(in: body), page: page)
    }

    /// The "## What's new" section of the notes (up to the next heading), or "" if there isn't one.
    static func whatsNew(in body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix("## what") }) else { return "" }
        let rest = lines[(start + 1)...]
        let section = rest.prefix { !$0.hasPrefix("## ") }
        return section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum UpdatePolicy {
    public static let checkEvery: TimeInterval = 24 * 3600

    /// Offer `latest` if it's newer than what's running and not the version the user chose to skip.
    public static func offer(latest: AppVersion, current: AppVersion, skipped: AppVersion?) -> Bool {
        latest > current && skipped != latest
    }

    public static func due(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkEvery
    }
}
