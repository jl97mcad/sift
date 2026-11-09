import XCTest
@testable import LarkMini

final class VoiceTests: XCTestCase {
    func testMarkdownReadsAsPlainSpeech() {
        let markdown = """
        ## Status
        1. **Shop GMV** is [merged](https://github.com/x/y/pull/1).
        - Run `sift doctor` first.
        ```bash
        rm -rf /
        ```
        | Plan | State |
        |---|---|
        See https://example.com for more.
        """
        let spoken = Spoken.plain(markdown)
        XCTAssertFalse(spoken.contains("rm -rf"))
        XCTAssertFalse(spoken.contains("**"))
        XCTAssertFalse(spoken.contains("https://"))
        XCTAssertTrue(spoken.contains("Shop GMV is merged."))
        XCTAssertTrue(spoken.contains("Run sift doctor first."))
        XCTAssertTrue(spoken.contains("a link"))
    }

    func testOnlyFinishedSentencesSpeakWhileWriting() {
        let text = "The plan is merged. The deploy is still runn"
        let settled = Spoken.settledLength(text)
        XCTAssertEqual(String(text.prefix(settled)), "The plan is merged. ")
        XCTAssertEqual(Spoken.settledLength("No sentence yet"), 0)
    }

    func testFirstPieceGoesAloneThenSentencesShareARequest() {
        let pieces = Spoken.pieces("One. Two. Three. Four.")
        XCTAssertEqual(pieces, ["One.", "Two. Three. Four."])
        let long = Spoken.pieces(String(repeating: "This sentence is about forty characters. ", count: 20), limit: 100)
        XCTAssertTrue(long.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(long.joined(separator: " ").count, String(repeating: "This sentence is about forty characters. ", count: 20).trimmingCharacters(in: .whitespaces).count)
    }
}
