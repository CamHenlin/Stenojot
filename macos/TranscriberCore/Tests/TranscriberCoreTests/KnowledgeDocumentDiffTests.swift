import XCTest
@testable import TranscriberCore

final class KnowledgeDocumentDiffTests: XCTestCase {
    func testLineDiffMarksInsertionsRemovalsAndReplacements() {
        XCTAssertEqual(
            TextDiff.lines(before: "alpha\nbeta\ngamma", after: "alpha\ndelta\ngamma", contextLines: nil),
            [
                TextDiffLine(kind: .same, text: "alpha"),
                TextDiffLine(kind: .removed, text: "beta"),
                TextDiffLine(kind: .added, text: "delta"),
                TextDiffLine(kind: .same, text: "gamma"),
            ]
        )
        XCTAssertEqual(
            TextDiff.lines(before: "alpha\nbeta", after: "alpha\nbeta\ngamma", contextLines: nil).map(\.kind),
            [.same, .same, .added]
        )
        XCTAssertEqual(
            TextDiff.lines(before: "alpha\nbeta\ngamma", after: "alpha\ngamma", contextLines: nil).map(\.kind),
            [.same, .removed, .same]
        )
    }

    func testEmptyDocumentDiffShowsOnlyAdditions() {
        XCTAssertEqual(
            TextDiff.lines(before: "", after: "Ship the build.", contextLines: nil),
            [TextDiffLine(kind: .added, text: "Ship the build.")]
        )
    }

    func testLongUnchangedRunsCollapseAroundTheEdit() {
        let before = (1...10).map { "line \($0)" }.joined(separator: "\n")
        var afterLines = (1...10).map { "line \($0)" }
        afterLines[5] = "changed"
        let after = afterLines.joined(separator: "\n")
        let diff = TextDiff.lines(before: before, after: after, contextLines: 1)
        XCTAssertEqual(diff.first?.kind, .skipped(4))
        XCTAssertTrue(diff.contains(TextDiffLine(kind: .removed, text: "line 6")))
        XCTAssertTrue(diff.contains(TextDiffLine(kind: .added, text: "changed")))
        XCTAssertEqual(diff.last?.kind, .skipped(3))
    }

    func testDocumentDiffLeavesUnchangedSectionsOut() {
        let older = KnowledgeRevision(title: "Runbook", description: "Deploy steps", text: "Ship the build.")
        let newer = KnowledgeRevision(title: "Runbook", description: "Deploy steps", text: "Ship the signed build.")
        let changes = KnowledgeDocumentDiff.changes(from: older, to: newer)
        XCTAssertEqual(changes.map(\.section), [.body])
        XCTAssertEqual(
            changes[0].lines,
            [
                TextDiffLine(kind: .removed, text: "Ship the build."),
                TextDiffLine(kind: .added, text: "Ship the signed build."),
            ]
        )
    }
}
