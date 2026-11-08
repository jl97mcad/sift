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

    private func message(_ type: String, _ content: String, extra: [String: Any] = [:]) throws -> ChatMessage {
        var raw: [String: Any] = ["message_id": "om_abcdef123", "msg_type": type, "create_time": "1000",
                                  "body": ["content": content], "sender": ["id": "ou_x", "sender_type": "user"]]
        raw.merge(extra) { _, new in new }
        return try XCTUnwrap(LarkAPI.parseMessage(raw, chatId: "c", meId: "me"))
    }

    func testRepliesThreadsEditsAndBotsKeepTheirMetadata() throws {
        let reply = try message("text", #"{"text":"yes"}"#, extra: ["parent_id": "om_parent", "root_id": "om_parent",
            "thread_id": "omt_1", "updated": true, "sender": ["id": "cli_bot", "sender_type": "app"]])
        XCTAssertEqual(reply.parentId, "om_parent")
        XCTAssertEqual(reply.threadId, "omt_1")
        XCTAssertTrue(reply.edited)
        XCTAssertTrue(reply.fromApp)
        let plain = try message("text", #"{"text":"hi"}"#, extra: ["parent_id": ""])
        XCTAssertNil(plain.parentId)
        XCTAssertFalse(plain.edited || plain.fromApp)
    }

    func testVoiceVideoAndStickersKeepWhatLarkGives() throws {
        let voice = try message("audio", #"{"file_key":"file_a","duration":12500}"#)
        XCTAssertEqual(voice.media, .audio(seconds: 12))
        XCTAssertEqual(voice.fileKey, "file_a")
        XCTAssertEqual(voice.fileName, "Voice message def123.opus")
        let video = try message("media", #"{"file_key":"file_v","image_key":"img_c","file_name":"demo.mp4","duration":62000}"#)
        XCTAssertEqual(video.media, .video(cover: "img_c", seconds: 62))
        XCTAssertEqual(video.fileName, "demo.mp4")
        XCTAssertEqual(LarkMedia.duration(62), "1:02")
        XCTAssertEqual(try message("sticker", #"{"file_key":"s"}"#).media, .sticker)
    }

    func testSharesForwardsSystemAndUnknownTypesAreNamed() throws {
        XCTAssertEqual(try message("share_chat", #"{"chat_id":"oc_1"}"#).media, .sharedChat(id: "oc_1"))
        XCTAssertEqual(try message("share_user", #"{"user_id":"ou_2"}"#).media, .contact(id: "ou_2"))
        XCTAssertEqual(try message("merge_forward", #"{"content":"Merged and Forwarded Message"}"#).media, .forward)
        XCTAssertEqual(try message("system", #"{"template":"{from_user} invited {to_chatters} to this chat.","from_user":["Ana"],"to_chatters":["Ben","Kai"]}"#).text,
                       "Ana invited Ben, Kai to this chat.")
        XCTAssertEqual(try message("system", #"{"template":"{from_user} changed the name"}"#).text, "someone changed the name")
        let event = try message("share_calendar_event", #"{"summary":"Launch review","start_time":"0"}"#)
        XCTAssertEqual(event.media, .other(type: "share_calendar_event"))
        XCTAssertEqual(event.text, "Calendar event · Launch review")
        XCTAssertEqual(try message("new_kind", "{}").text, "New Kind")
    }

    func testPostsAndCardsKeepEmbeddedImagesAndButtonTargets() throws {
        let post = try message("post", #"{"title":"","content":[[{"tag":"text","text":"Look"},{"tag":"img","image_key":"img_1"}],[{"tag":"img","image_key":"img_2"}]]}"#)
        XCTAssertEqual(post.imageKeys, ["img_1", "img_2"])
        let card: [String: Any] = ["elements": [[["tag": "button", "text": "Open PR", "url": "https://example.com/pr/1"]]]]
        XCTAssertEqual(LarkAPI.flattenRich(card, rows: "elements"), "[Open PR] (https://example.com/pr/1) \nButtons on this card work in Lark.")
    }

    func testRefreshReplacesEditedRowsAndPublishesNothingWhenUnchanged() throws {
        let first = try message("text", #"{"text":"draft"}"#)
        let edited = try message("text", #"{"text":"final"}"#, extra: ["updated": true])
        let later = try message("text", #"{"text":"next"}"#, extra: ["message_id": "om_2", "create_time": "2000"])
        XCTAssertNil(Store.merge([first], [first]))
        XCTAssertEqual(Store.merge([first], [edited, later])?.map(\.text), ["final", "next"])
        let recalled = try message("text", #"{"text":"This message was recalled"}"#, extra: ["deleted": true])
        XCTAssertEqual(Store.merge([first], [recalled])?.first?.deleted, true)
    }

    func testDeeplyNestedRichContentIsWalkedWithinBounds() {
        var nested: Any = ["tag": "img", "image_key": "deep"]
        for _ in 0..<2_000 { nested = [nested] }
        XCTAssertEqual(LarkAPI.embeddedImages(nested), [], "beyond the depth limit nothing is followed")
        let wide: [Any] = (0..<20_000).map { ["tag": "img", "image_key": "k\($0)"] }
        XCTAssertLessThan(LarkAPI.embeddedImages(wide).count, 5_000, "the node limit stops a huge card")
        var note: [String: Any] = ["tag": "text", "text": "x"]
        for _ in 0..<50 { note = ["tag": "note", "elements": [note]] }
        XCTAssertEqual(LarkAPI.flattenRich(["elements": [[note]]], rows: "elements"), "")
    }

    func testHostileNumbersCannotTrapConversions() throws {
        let voice = try message("audio", #"{"file_key":"f","duration":1e300}"#)
        XCTAssertEqual(voice.media, .audio(seconds: 86_400))
        XCTAssertEqual(try message("audio", #"{"file_key":"f","duration":-5}"#).media, .audio(seconds: 0))
        let raw: [String: Any] = ["message_id": "om_1", "msg_type": "text", "create_time": 1e300,
                                  "body": ["content": #"{"text":"x"}"#], "sender": [:]]
        XCTAssertEqual(LarkAPI.parseMessage(raw, chatId: "c", meId: "me")?.ts, 4_102_444_800_000)
        XCTAssertEqual(LarkAPI.number(Double.nan, in: 0...10), 0)
        XCTAssertEqual(LarkAPI.number("12", in: 0...10), 0, "only JSON numbers count")
    }

    func testAHugeCardQueuesNoMoreThanItsNodeBudget() {
        let wide: [Any] = Array(repeating: ["tag": "img", "image_key": "k"], count: 1_000_000)
        XCTAssertEqual(LarkAPI.embeddedImages(wide, maxNodes: 100).count, 99, "the list itself is one of the 100 nodes")
    }

    func testRichAndPlainTextStayWithinTheirLimits() throws {
        let long = String(repeating: "a", count: 100_000)
        let plain = try message("text", "{\"text\":\"\(long)\"}")
        XCTAssertLessThanOrEqual(plain.text.count, LarkAPI.textLimit + 30)
        XCTAssertTrue(plain.text.hasSuffix("the rest is in Lark)"))
        let element: [String: Any] = ["tag": "a", "text": String(repeating: "b", count: 10_000), "href": "https://example.com"]
        let rows: [[Any]] = Array(repeating: Array(repeating: element, count: 1_000), count: 1_000)
        let started = Date()
        let card = LarkAPI.flattenRich(["title": long, "elements": rows], rows: "elements")
        XCTAssertLessThanOrEqual(card.count, LarkAPI.textLimit + 30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "only a bounded slice is walked")
    }

    func testMentionsSystemTextAndSummariesAreClippedAfterSubstitution() throws {
        let body = String(repeating: "@_user_1 ", count: 5_000)
        let raw: [String: Any] = ["message_id": "om_1", "msg_type": "text", "create_time": "1",
            "body": ["content": "{\"text\":\"\(body)\"}"], "sender": [:],
            "mentions": [["key": "@_user_1", "name": String(repeating: "N", count: 10_000)]]]
        let mentioned = try XCTUnwrap(LarkAPI.parseMessage(raw, chatId: "c", meId: "me"))
        XCTAssertLessThanOrEqual(mentioned.text.count, LarkAPI.textLimit + 30)
        XCTAssertTrue(mentioned.text.hasPrefix("@" + String(repeating: "N", count: 200) + " "), "names are bounded")
        let names = (0..<1_000).map { _ in String(repeating: "x", count: 1_000) }
        let template = String(repeating: "{from_user} ", count: 2_000)
        let system: [String: Any] = ["message_id": "om_2", "msg_type": "system", "create_time": "1", "sender": [:],
            "body": ["content": String(data: try JSONSerialization.data(withJSONObject: ["template": template, "from_user": names]), encoding: .utf8)!]]
        XCTAssertLessThanOrEqual(try XCTUnwrap(LarkAPI.parseMessage(system, chatId: "c", meId: "me")).text.count, LarkAPI.textLimit + 30)
        let other = try message("vote", "{\"topic\":\"\(String(repeating: "t", count: 100_000))\"}")
        XCTAssertLessThanOrEqual(other.text.count, LarkAPI.textLimit + 30)
    }

    func testAWideObjectIsNotCopiedWholeBeforeTheNodeBudget() {
        var wide: [String: Any] = [:]
        for index in 0..<100_000 { wide["k\(index)"] = ["tag": "img", "image_key": "i\(index)"] }
        let started = Date()
        XCTAssertLessThan(LarkAPI.embeddedImages(wide, maxNodes: 100).count, 100)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(LarkAPI.embeddedImages(["b": ["tag": "img", "image_key": "2"], "a": ["tag": "img", "image_key": "1"]]),
                       ["1", "2"], "objects within the budget keep a stable key order")
    }

    func testSignInAsksForExactlyTheDocumentedScopes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scope = #"`([a-z0-9_]+:[a-z0-9_.:]+|offline_access)`"#
        func documented(_ file: String, from start: String, to end: String) throws -> Set<String> {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let section = try XCTUnwrap(text.range(of: start).flatMap { begin in
                text.range(of: end, range: begin.upperBound..<text.endIndex).map { text[begin.upperBound..<$0.lowerBound] } })
            let regex = try NSRegularExpression(pattern: scope)
            let found = String(section)
            return Set(regex.matches(in: found, range: NSRange(found.startIndex..., in: found)).compactMap {
                Range($0.range(at: 1), in: found).map { String(found[$0]) } })
        }
        let requested = Set(LarkAPI.scopes)
        XCTAssertEqual(requested.count, LarkAPI.scopes.count, "no duplicates")
        XCTAssertEqual(try documented("AGENTS.md", from: "scopes enabled and approved:", to: "2. Approving"), requested)
        XCTAssertEqual(try documented("README.md", from: "| Scope", to: "\n\n"), requested)
    }
}
