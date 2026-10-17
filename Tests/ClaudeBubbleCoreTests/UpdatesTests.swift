import XCTest
@testable import ClaudeBubbleCore

final class UpdatesTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertLessThan(AppVersion("0.1.9")!, AppVersion("0.1.10")!)
        XCTAssertLessThan(AppVersion("0.1.2")!, AppVersion("v0.2")!)
        XCTAssertEqual(AppVersion("v0.1.2"), AppVersion("0.1.2"))
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"), "missing parts are zero")
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion(""))
    }

    let json = #"""
    {"tag_name":"v0.1.3","draft":false,"prerelease":false,"html_url":"https://github.com/o/r/releases/tag/v0.1.3",
     "body":"## What's new\n\n- **Updates** inside the app.\n- Faster hook.\n\n## Install\n\nYou need macOS 14.\n\nSHA-256: `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`",
     "assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt"},
               {"name":"ClaudeBubble-0.1.3.zip","browser_download_url":"https://x/ClaudeBubble-0.1.3.zip"}]}
    """#

    func testParsesARelease() throws {
        let r = try XCTUnwrap(ReleaseInfo.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, AppVersion("0.1.3"))
        XCTAssertEqual(r.tag, "v0.1.3")
        XCTAssertEqual(r.zip.absoluteString, "https://x/ClaudeBubble-0.1.3.zip")
        XCTAssertEqual(r.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(r.whatsNew, "- **Updates** inside the app.\n- Faster hook.")
        XCTAssertEqual(r.page.absoluteString, "https://github.com/o/r/releases/tag/v0.1.3")
    }

    func testRejectsReleasesItCantInstall() {
        func parse(_ s: String) -> ReleaseInfo? { ReleaseInfo.parse(Data(s.utf8)) }
        XCTAssertNil(parse(json.replacingOccurrences(of: "ClaudeBubble-0.1.3.zip\"", with: "Other.zip\"")), "no app zip")
        XCTAssertNil(parse(json.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")))
        XCTAssertNil(parse(json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")))
        XCTAssertNil(parse(json.replacingOccurrences(of: "SHA-256: `", with: "Checksum: `")), "no checksum to verify against")
        XCTAssertNil(parse("{}"))
    }

    func testOffersOnlyNewerUnskippedVersions() {
        let v = { AppVersion($0)! }
        XCTAssertTrue(UpdatePolicy.offer(latest: v("0.1.3"), current: v("0.1.2"), skipped: nil))
        XCTAssertFalse(UpdatePolicy.offer(latest: v("0.1.2"), current: v("0.1.2"), skipped: nil))
        XCTAssertFalse(UpdatePolicy.offer(latest: v("0.1.1"), current: v("0.1.2"), skipped: nil), "never a downgrade")
        XCTAssertFalse(UpdatePolicy.offer(latest: v("0.1.3"), current: v("0.1.2"), skipped: v("0.1.3")), "skipped")
        XCTAssertTrue(UpdatePolicy.offer(latest: v("0.1.4"), current: v("0.1.2"), skipped: v("0.1.3")), "a newer one than the skipped")
    }

    func testChecksAboutDaily() {
        let now = Date()
        XCTAssertTrue(UpdatePolicy.due(lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.due(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdatePolicy.due(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
    }
}
