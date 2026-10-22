import XCTest
@testable import ClaudeBubbleCore

final class DictationFixesTests: XCTestCase {
    func testDefaultsFixWhatDictationMishears() {
        let heard = "Okay, so push the clod bubble branch, then review PR 7465 in the Ezra Rebo. If the work tree is dirty, ask Clawed."
        XCTAssertEqual(DictationFixes.apply(DictationFixes.defaults, to: heard),
                       "Okay, so push the Claude Bubble branch, then review PR 7465 in the Ezra repo. If the worktree is dirty, ask Claude.")
    }

    func testCloudOnItsOwnStaysCloud() {
        XCTAssertEqual(DictationFixes.apply(DictationFixes.defaults, to: "Deploy it to the cloud."), "Deploy it to the cloud.")
    }

    func testWholeWordsOnlyAnyCase() {
        let fixes = [DictationFix(heard: "rebo", meant: "repo")]
        XCTAssertEqual(DictationFixes.apply(fixes, to: "REBO rebounds"), "repo rebounds")
    }

    func testLongestPhraseFirst() {
        let fixes = [DictationFix(heard: "clod", meant: "Claude"), DictationFix(heard: "clod bubble", meant: "Claude Bubble")]
        XCTAssertEqual(DictationFixes.apply(fixes, to: "the clod bubble"), "the Claude Bubble")
    }

    func testPunctuationAndTemplateCharactersAreLiteral() {
        let fixes = [DictationFix(heard: "c plus plus", meant: "C++"), DictationFix(heard: "dollar one", meant: "$1"),
                     DictationFix(heard: "  ", meant: "never")]
        XCTAssertEqual(DictationFixes.apply(fixes, to: "c plus plus costs dollar one"), "C++ costs $1")
    }
}
