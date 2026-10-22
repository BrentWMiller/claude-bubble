import XCTest
@testable import ClaudeBubbleCore

final class DictationVocabularyTests: XCTestCase {
    func testYoursThenSessionsOnceEachTrimmed() {
        XCTAssertEqual(DictationVocabulary.words(yours: [" Majid ", "", "claude"], sessions: ["Claude", "Ezra"]),
                       ["Majid", "claude", "Ezra"])
    }

    func testSlugsAreAlsoGivenAsSpokenWords() {
        XCTAssertEqual(DictationVocabulary.words(yours: [], sessions: ["claude-bubble", "lawn_drupal_store"]),
                       ["claude-bubble", "claude bubble", "lawn_drupal_store", "lawn drupal store"])
    }

    func testCappedAtTheLimit() {
        let many = (0..<300).map { "word\($0)" }
        XCTAssertEqual(DictationVocabulary.words(yours: many, sessions: ["late"]).count, DictationVocabulary.limit)
    }
}
