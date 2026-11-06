import XCTest
@testable import LarkMini

final class LarkFidelityTests: XCTestCase {
    func testPostKeepsLinksMentionsAndLocaleWrappedContent() {
        let post: [String: Any] = ["zh_cn": ["title": "Launch", "content": [
            [["tag": "text", "text": "See "], ["tag": "a", "text": "the brief", "href": "https://example.com/brief"]],
            [["tag": "at", "user_id": "@_user_1", "user_name": ""], ["tag": "text", "text": " and "], ["tag": "at", "user_id": "ou_2", "user_name": "Riley"]],
            [["tag": "a", "text": "https://example.com/raw", "href": "https://example.com/raw"], ["tag": "emotion", "emoji_type": "OK"]],
            [["tag": "code_block", "language": "sh", "text": "make app"]]]]]
        XCTAssertEqual(LarkAPI.flattenRich(post, rows: "content"),
                       "Launch\nSee the brief (https://example.com/brief)\n@_user_1 and @Riley\nhttps://example.com/raw:OK:\nmake app")
    }

    func testReducedCardKeepsTitleTextAndNamesItsControls() {
        let card: [String: Any] = ["title": "Deploy approval", "elements": [
            [["tag": "text", "text": "Release 42 is ready"]],
            [["tag": "note", "elements": [["tag": "img", "image_key": "k"], ["tag": "text", "text": "from CI"]]]],
            [["tag": "hr"]],
            [["tag": "button", "text": "Approve", "type": "primary"], ["tag": "button", "text": "Hold"]]]]
        XCTAssertEqual(LarkAPI.flattenRich(card, rows: "elements"),
                       "Deploy approval\nRelease 42 is ready\n[image] from CI\n———\n[Approve] [Hold] \nButtons on this card work in Lark.")
    }

    func testMentionKeysNeverCollideAndEmptyCardsSayWhereToOpenThem() throws {
        let raw: [String: Any] = ["message_id": "om_1", "msg_type": "text", "create_time": "1000",
            "body": ["content": #"{"text":"@_user_1 and @_user_10, cc @_all"}"#],
            "sender": ["id": "ou_x"], "mentions": [["key": "@_user_1", "name": "Ann"], ["key": "@_user_10", "name": "Ben"]]]
        XCTAssertEqual(try XCTUnwrap(LarkAPI.parseMessage(raw, chatId: "c", meId: "me")).text, "@Ann and @Ben, cc @all")
        let card: [String: Any] = ["message_id": "om_2", "msg_type": "interactive", "body": ["content": "{}"], "sender": [:]]
        XCTAssertEqual(LarkAPI.parseMessage(card, chatId: "c", meId: "me")?.text, "Card · open it in Lark")
    }

    func testPreviewsKeepFactsAndPlainTextStaysPlain() {
        XCTAssertEqual(UpdateText.short("## Done\n\n**Merged** `abc1234` to /srv/app, see [PR 12](https://github.com/o/r/pull/12).\n\n- id 123e4567-e89b-12d3-a456-426614174000"),
                       "Done Merged abc1234 to /srv/app, see PR 12. • id 123e4567-e89b-12d3-a456-426614174000")
        let linked = LinkedText.attributed("**not bold** https://example.com/x")
        XCTAssertEqual(String(linked.characters), "**not bold** https://example.com/x")
        XCTAssertEqual(linked.runs.compactMap(\.link), [URL(string: "https://example.com/x")!])
    }
}
