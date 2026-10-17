import ClaudeBubbleCore
import Foundation

/// Fetches chip hover cards with the GitHub CLI (`gh`), only when a chip is hovered. A fetched card shows instantly
/// from then on; after `LinkPreview.freshFor` it's refreshed behind the scenes, and once merged or closed never again.
final class LinkPreviewFetcher: ObservableObject {
    static let shared = LinkPreviewFetcher()

    private struct Entry { let preview: LinkPreview; let fetchedAt: Date }
    @Published private var entries: [URL: Entry] = [:]
    private var loading = Set<URL>()
    private let queue = DispatchQueue(label: "ClaudeBubble.link-preview", qos: .userInitiated)

    /// Whether there's a `gh` to ask (no card at all without one).
    static var available: Bool { PRStatusFetcher.gh != nil }

    func preview(for url: URL) -> LinkPreview? { entries[url]?.preview }

    /// Main thread. Fetches unless what's cached is still fresh.
    func load(_ link: SessionLink) {
        guard let gh = PRStatusFetcher.gh, !loading.contains(link.url) else { return }
        let e = entries[link.url]
        guard LinkPreview.needsRefresh(final: e?.preview.final ?? false, age: e.map { Date().timeIntervalSince($0.fetchedAt) }) else { return }
        loading.insert(link.url)
        let url = link.url, issue = link.kind == .issue
        queue.async { [weak self] in
            let preview = Self.fetch(url, issue: issue, gh: gh)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(url)
                if let preview { self.entries[url] = Entry(preview: preview, fetchedAt: Date()) }
            }
        }
    }

    private static func fetch(_ url: URL, issue: Bool, gh: String) -> LinkPreview? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = issue
            ? ["issue", "view", url.absoluteString, "--json", "title,state,author,labels,assignees,comments"]
            : ["pr", "view", url.absoluteString, "--json",
               "title,state,author,additions,deletions,changedFiles,statusCheckRollup,reviewDecision,latestReviews"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return issue ? LinkPreview.parseIssue(data) : LinkPreview.parsePullRequest(data)
    }
}
