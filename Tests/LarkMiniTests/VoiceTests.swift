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

    func testNothingInsideAnOpenCodeBlockIsSpokenEarly() {
        let text = "Run this.\n```bash\nrm -rf /tmp/x\nmore\n"
        XCTAssertEqual(String(text.prefix(Spoken.settledLength(text))), "Run this.\n")
        let closed = text + "```\nDone.\n"
        XCTAssertEqual(Spoken.settledLength(closed), closed.count)
        XCTAssertFalse(Spoken.plain(closed).contains("rm -rf"))
    }

    func testEmphasisSplitAcrossPiecesIsNotReadOut() {
        XCTAssertEqual(Spoken.plain("**Shop GMV is up."), "Shop GMV is up.")
    }

    func testRoundTripComparesWordsNotPunctuation() {
        XCTAssertTrue(Spoken.sameWords("Sift voice is working.", " sift voice is working"))
        XCTAssertFalse(Spoken.sameWords("Sift voice is working.", "Something else entirely"))
    }

    func testWhisperInventionsForSilenceAreNotSent() {
        XCTAssertTrue(VoiceMode.isPhantom(" you"))
        XCTAssertTrue(VoiceMode.isPhantom("Thank you."))
        XCTAssertTrue(VoiceMode.isPhantom(" ... "))
        XCTAssertFalse(VoiceMode.isPhantom("Thank you, now queue the plan."))
    }

    func testLevelFollowsLoudness() {
        XCTAssertEqual(VoiceMode.level(-160), 0)
        XCTAssertEqual(VoiceMode.level(0), 1)
        XCTAssertGreaterThan(VoiceMode.level(-20), VoiceMode.level(-40))
    }

    func testNamesFitAndInitialsNeverWrap() {
        XCTAssertEqual(ControlSeat.shortTitle("Jon's Control (AWS) — auto handoff"), "Control")
        XCTAssertEqual(ControlSeat.shortTitle("Finance"), "Finance")
        XCTAssertEqual(ChatTitle.split("Devs - Agents Room [INTERNAL]").name, "Devs - Agents Room")
        XCTAssertEqual(ChatTitle.split("Devs - Agents Room [INTERNAL]").tags, ["INTERNAL"])
        XCTAssertEqual(ChatTitle.split("Int | Full Crumbs x Outlandish").name, "Full Crumbs x Outlandish")
        XCTAssertEqual(ChatTitle.split("Int | Full Crumbs x Outlandish").tags, ["INT"])
        XCTAssertEqual(ChatTitle.split("Design | Review").name, "Design | Review")
        XCTAssertEqual(ChatTitle.split("Int | Team [INT]").tags, ["INT"])
        XCTAssertEqual(ChatTitle.initials("Devs - Agents Room"), "DA")
        XCTAssertEqual(ChatTitle.initials("Mattel / LCG"), "ML")
        XCTAssertEqual(ChatTitle.initials("D-"), "D")
        XCTAssertEqual(ChatTitle.initials("Jon's Control"), "JC")
    }
}
