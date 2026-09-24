import Foundation
import GRDB
import XCTest
@testable import TranscriberCore

final class ReplacementEngineTests: XCTestCase {
    func testDeletesFillerAndCollapsesSpace() {
        let rules = [ReplacementRule(from: "um", to: "")]
        XCTAssertEqual(ReplacementEngine.apply(rules, to: "hello um world"), "hello world")
    }

    func testDoesNotMatchInsideWords() {
        let rules = [ReplacementRule(from: "um", to: "")]
        XCTAssertEqual(ReplacementEngine.apply(rules, to: "umbrella"), "umbrella")
    }

    func testStripsLeadingPunctuationLeftByADeletion() {
        let rules = [ReplacementRule(from: "um", to: "")]
        XCTAssertEqual(ReplacementEngine.apply(rules, to: "um, hello"), "hello")
    }

    func testCleansDoubledCommas() {
        let rules = [ReplacementRule(from: "um", to: "")]
        XCTAssertEqual(ReplacementEngine.apply(rules, to: "hello, um, world"), "hello, world")
    }

    func testDropsTextThatBecomesEmpty() {
        let rules = [ReplacementRule(from: "um", to: "")]
        XCTAssertEqual(ReplacementEngine.apply(rules, to: "um"), "")
        XCTAssertEqual(ReplacementEngine.apply(rules, to: "..."), "")
    }

    func testCaseInsensitivePhrase() {
        let rules = [ReplacementRule(from: "ready for death", to: "ready for dev")]
        XCTAssertEqual(
            ReplacementEngine.apply(rules, to: "It is Ready For Death today"),
            "It is ready for dev today"
        )
    }

    func testSanitizedDropsBlankRules() {
        let rules = [
            ReplacementRule(from: "  ", to: "x"),
            ReplacementRule(from: " Linz ", to: " LIMS "),
        ]
        XCTAssertEqual(
            ReplacementEngine.sanitized(rules),
            [ReplacementRule(from: "Linz", to: "LIMS")]
        )
    }
}
