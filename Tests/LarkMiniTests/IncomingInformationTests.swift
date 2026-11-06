import XCTest
@testable import LarkMini

final class IncomingInformationTests: XCTestCase {
    func testOnlyRealRepliesAndPromptsBecomeMessages() {
        let source = #"{"status":"idle","title":"Control","hasOlder":true,"entries":[{"id":"thought-1","type":"reasoning","text":"PRIVATE_THOUGHT\n\nMORE_PRIVATE"},{"id":"user-1","type":"user_message","text":"Please check it","ts":60001},{"id":"reply-1","type":"assistant_message","text":"**Ready.**\n\n- Checked it","ts":60002},{"id":"tool-1","type":"tool_call","text":"PRIVATE_TOOL_OUTPUT"}]}"#
        let messages = PaseoClient.parse(source)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.map(\.id), ["user-1", "reply-1"])
        XCTAssertFalse(messages.contains { $0.text.contains("PRIVATE") })
        XCTAssertEqual(messages.last?.text, "**Ready.**\n\n- Checked it")
        XCTAssertEqual(messages.last?.ts, 60002)
    }

    func testReadingCarriesPermissionNeedHistoryAndHandoffSuccessor() throws {
        let live = try XCTUnwrap(PaseoClient.reading(#"{"status":"running","needsInput":true,"title":"Control","hasOlder":true,"entries":[],"action":{"type":"tool_call","status":"running","kind":"shell"}}"#))
        XCTAssertTrue(live.needsInput)
        XCTAssertTrue(live.hasOlder)
        XCTAssertEqual(live.activity, "Running a command")
        XCTAssertNil(live.successor)
        let archived = try XCTUnwrap(PaseoClient.reading(#"{"status":"archived","needsInput":false,"hasOlder":false,"entries":[],"action":null,"successor":{"id":"next-seat","title":"Control (takeover)"}}"#))
        XCTAssertEqual(archived.successor, ControlOption(id: "next-seat", name: "Control (takeover)"))
        XCTAssertNil(archived.activity)
        XCTAssertNil(PaseoClient.reading("DaemonConnectionError: Timeout"))
    }

    func testActivityComesFromTheCurrentStepOfARunningTurn() {
        let step = { (type: String, status: String?, kind: String?) -> [String: Any] in
            var action: [String: Any] = ["type": type]
            action["status"] = status
            action["kind"] = kind
            return action
        }
        XCTAssertEqual(PaseoClient.activity(status: "running", action: step("tool_call", "running", "read")), "Reading files")
        XCTAssertEqual(PaseoClient.activity(status: "running", action: step("tool_call", "running", "edit")), "Editing files")
        XCTAssertEqual(PaseoClient.activity(status: "running", action: step("tool_call", "completed", "shell")), "Working")
        XCTAssertEqual(PaseoClient.activity(status: "running", action: step("reasoning", nil, nil)), "Thinking")
        XCTAssertNil(PaseoClient.activity(status: "idle", action: step("tool_call", "running", "shell")))
    }

    func testSpeakersComeFromPaseoProvenance() {
        let app = AgentMessage(id: "msg_1700000000000_example01", role: "user", text: "Make sure it is tracked")
        XCTAssertEqual(app.speaker, "You")
        XCTAssertFalse(app.isContext)
        let envelope = #"<paseo-system version="1" kind="agent-message" source-agent-id="agent-2" source-agent-title="[Handoff] Build &amp; Review">"#
            + "\n# Plan\n\nThe owner&apos;s request: **ship it**\n</paseo-system>"
        let agent = AgentMessage(id: "6f1c0a52-1111-4222-8333-944444444444", role: "user", text: envelope)
        XCTAssertEqual(agent.origin, .agent("[Handoff] Build & Review"))
        XCTAssertEqual(agent.displayText, "# Plan\n\nThe owner's request: **ship it**")
        XCTAssertTrue(agent.isContext)
        XCTAssertEqual(AgentMessage(id: "control-wait:0000:2:receipt", role: "user", text: "Receipt").speaker, "Control wait")
        let script = AgentMessage(id: "6f1c0a52-1111-4222-8333-944444444444", role: "user", text: "Lark monitor digest")
        XCTAssertEqual(script.speaker, "Automated message")
        var mine = script
        mine.sentHere = true
        XCTAssertEqual(mine.speaker, "You")
        XCTAssertEqual(AgentMessage(id: "msg_x", role: "assistant", text: "Done").speaker, "Control")
    }

    func testOnlySameSpeakerSameMinuteControlMessagesGroup() {
        let reply = { (id: String, ts: Int64) in AgentMessage(id: id, role: "assistant", text: "x", ts: ts) }
        XCTAssertTrue(reply("b", 60_001).groups(with: reply("a", 119_999)))
        XCTAssertFalse(reply("b", 120_000).groups(with: reply("a", 119_999)))
        XCTAssertFalse(reply("b", 60_002).groups(with: AgentMessage(id: "msg_1", role: "user", text: "x", ts: 60_001)))
        XCTAssertFalse(reply("b", 60_002).groups(with: AgentMessage(id: "a", role: "assistant", text: "x")))
    }

    func testHandoffMovesOnlyTheUnchangedSeatToTheNamedSuccessor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = StateFile(url: folder.appendingPathComponent("state.json"))
        let old = ControlSeat(agentId: "old", title: "Control", host: "tcp://box:6767")
        state.update { $0.control = old }
        let provider = FakeProvider(readings: [
            "old": AgentReading(messages: [], status: "archived", activity: nil, hasOlder: false,
                                successor: ControlOption(id: "new", name: "Control — takeover")),
            "new": AgentReading(messages: [AgentMessage(id: "r1", role: "assistant", text: "Here")],
                                status: "idle", activity: nil, hasOlder: false)])
        let (seat, reading) = try await provider.readFollowing(old, tail: 80, state: state)
        XCTAssertEqual(seat, ControlSeat(agentId: "new", title: "Control — takeover", host: "tcp://box:6767", id: "old"),
                       "the seat keeps its own id over a handoff, so seen needs and the draft follow the agent")
        XCTAssertEqual(reading.messages.map(\.id), ["r1"])
        XCTAssertEqual(StateFile(url: folder.appendingPathComponent("state.json")).current.control, seat)

        let chosen = ControlSeat(agentId: "chosen", title: "Other")
        state.update { $0.control = chosen }
        let (kept, _) = try await provider.readFollowing(old, tail: 80, state: state)
        XCTAssertEqual(kept, old)
        XCTAssertEqual(state.current.control, chosen)
    }
}

private struct FakeProvider: AgentProvider {
    let readings: [String: AgentReading]
    let name = "fake"
    func inspect(id: String, host: String?) async -> (title: String, status: String)? { nil }
    func read(id: String, host: String?, tail: Int) async throws -> AgentReading {
        guard let reading = readings[id] else { throw PaseoClient.PaseoError.failed("missing") }
        return reading
    }
    func send(id: String, host: String?, text: String) async throws {}
    func options(host: String?) async -> [ControlOption] { [] }
}

final class NeedsYouTests: XCTestCase {
    func testOpenAsksComeFromTheControlDaemonReply() throws {
        let reply: [String: Any] = ["status": "available", "reason": "", "asks": [
            ["id": "a1", "plan": "ALT-1", "title": "Pick", "question": "Which one?", "recommendation": "The first",
             "link": "https://board.example/ALT-1#comment-1"],
            ["id": "a2", "plan": "ALT-2", "title": "", "question": "Unsafe link?", "recommendation": "", "link": "javascript:alert(1)"],
            ["id": "", "question": "No id"], ["id": "a3", "question": ""]]]
        let asks = AskInbox.parse(reply).asks
        XCTAssertEqual(asks.map(\.id), ["a1", "a2"])
        XCTAssertEqual(asks.first?.link, URL(string: "https://board.example/ALT-1#comment-1"))
        XCTAssertNil(asks.last?.link)
        let reading = try XCTUnwrap(PaseoClient.reading(#"{"status":"idle","entries":[],"asks":{"status":"available","reason":"","asks":[{"id":"a1","plan":"ALT-1","title":"Pick","question":"Which?","recommendation":"","link":""}]}}"#))
        XCTAssertEqual(reading.asks.asks.map(\.id), ["a1"])
    }

    func testNoSuiteIsOffAndAnyFailureIsUnknownNotEmpty() {
        XCTAssertEqual(AskInbox.parse(["status": "off"]), .off)
        XCTAssertEqual(AskInbox.parse(["status": "unavailable", "reason": "runner journal unreadable"]), .unavailable("runner journal unreadable"))
        XCTAssertEqual(AskInbox.parse(["status": "unavailable"]), .unavailable("Control's asks are unavailable"))
        XCTAssertEqual(AskInbox.parse(nil), .unavailable("Control's asks reply is unreadable"))
        XCTAssertEqual(AskInbox.parse(["status": "available"]), .unavailable("Control's asks reply is unreadable"))
        XCTAssertEqual(AskInbox.parse(["status": "available", "asks": []]), .available([]))
    }

    func testRepliesUseNativeIdsAndPermissionAlertsOnce() {
        var policy = ControlAttention()
        let reply = AgentMessage(id: "r1", role: "assistant", text: "Same words")
        XCTAssertNil(policy.observe(status: "idle", messages: [reply]).reply)
        XCTAssertNil(policy.observe(status: "running", messages: [reply]).reply)
        let again = AgentMessage(id: "r2", role: "assistant", text: "Same words")
        let finished = policy.observe(status: "idle", messages: [reply, again])
        XCTAssertEqual(finished.reply, "r2")
        XCTAssertEqual(finished.alert, "Turn finished")
        XCTAssertNil(policy.observe(status: "idle", messages: [reply, again]).alert)
        XCTAssertEqual(policy.observe(status: "running", needsInput: true, messages: [again]).alert, "Needs your permission")
        XCTAssertNil(policy.observe(status: "running", needsInput: true, messages: [again]).alert)
        XCTAssertEqual(policy.observe(status: "error", messages: [again]).alert, "Stopped with an error")
    }
}

final class ChatLinkTests: XCTestCase {
    private func chat(_ id: String, _ name: String, direct: Bool = true) -> Chat {
        Chat(id: id, name: name, avatar: nil, isP2P: direct, isTopic: false, detail: "", link: nil)
    }

    func testOnlyUnambiguousMultiWordChatNamesLinkOutsideCode() throws {
        let links = ChatLinks(chats: [
            chat("dm-ana", "Ana Ruiz"), chat("dm-ana-r", "Ana Rossi"),
            chat("dm-kai", "Kai Moreno (Travelling)"), chat("room", "Ops - Launch Room [TEAM]", direct: false),
            chat("hq", "HQ", direct: false), chat("sam-1", "Sam Lee"), chat("sam-2", "Sam Lee")])
        var text = try AttributedString(markdown: "Ask Ana Ruiz's team, Kai Moreno and Ops - Launch Room [TEAM]; HQ, Sam Lee, Ana Ruizter and `Ana Ruiz` stay plain. [Ana Rossi](https://example.com)")
        links.link(&text)
        let linked = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0.absoluteString) } }
        XCTAssertEqual(linked.map(\.0), ["Ana Ruiz", "Kai Moreno", "Ops - Launch Room [TEAM]", "Ana Rossi"])
        XCTAssertEqual(linked.map(\.1), ["sift://chat/dm-ana", "sift://chat/dm-kai", "sift://chat/room", "https://example.com"])
        XCTAssertEqual(ChatLinks.chatId(from: URL(string: "sift://chat/dm-ana")!), "dm-ana")
        XCTAssertNil(ChatLinks.chatId(from: URL(string: "https://example.com/chat/x")!))
    }
}

final class SeatListTests: XCTestCase {
    func testOldSingleControlFileBecomesTheFirstSeatAndControlAddressesIt() throws {
        let legacy = Data(#"{"pinned":[],"control":{"agentId":"a1","title":"Control","host":"tcp://box:6767"}}"#.utf8)
        var state = try JSONDecoder().decode(AppState.self, from: legacy)
        XCTAssertEqual(state.seats.map(\.id), ["a1"])
        XCTAssertEqual(state.control?.agentId, "a1")

        state.seats[0].name = "Old"
        state.seats.append(ControlSeat(agentId: "f1", title: "Finance", name: "Finance", color: "pink"))
        state.seats.append(ControlSeat(agentId: "c2", title: "Control (takeover)", name: "Control"))
        XCTAssertEqual(state.control?.id, "c2", "the seat named Control wins over the first seat")
        state.control = nil
        XCTAssertEqual(state.seats.map(\.id), ["a1", "f1"])
        state.control = ControlSeat(agentId: "c3", title: "Control")
        XCTAssertEqual(state.seats.map(\.id), ["c3", "a1", "f1"], "a new Control goes first and keeps the other seats")

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertNil(encoded?["control"], "only the seat list is written")
        let seats = try XCTUnwrap(encoded?["seats"] as? [[String: Any]])
        XCTAssertEqual(seats.map { $0["id"] as? String }, ["c3", "a1", "f1"])
        XCTAssertEqual(seats[2]["color"] as? String, "pink")
    }

    func testFaceColourIsStableForANameAndNeverTheSiftGreen() {
        XCTAssertEqual(FacePalette.pick(for: "Finance"), FacePalette.pick(for: "Finance"))
        for name in ["God", "Taro Twin", "Finance", "Unstick", "Control"] {
            XCTAssertNotEqual(FacePalette.pick(for: name), "green")
            XCTAssertTrue(FacePalette.names.contains(FacePalette.pick(for: name)))
        }
        XCTAssertEqual(FacePalette.named("green"), .sift)
        XCTAssertEqual(FacePalette.named("nonsense"), .sift)
        XCTAssertNotEqual(FacePalette.named("pink"), .sift)
    }
}

final class ControlSetTests: XCTestCase {
    func testControlSetNamesTheSeatSoItStaysAddressableAmongOthers() {
        var state = AppState()
        state.seats = [ControlSeat(agentId: "f1", title: "Finance"), ControlSeat(agentId: "g1", title: "God")]
        state.control = ControlSeat.control(agentId: "x1", title: "Session 42", name: nil, host: nil)
        XCTAssertEqual(state.control?.id, "x1")
        XCTAssertEqual(state.control?.label, "Control")
        XCTAssertEqual(ControlSeat.control(agentId: "y", title: "Jon's Control (AWS)", name: nil, host: nil).label, "Jon's Control (AWS)")
        XCTAssertEqual(ControlSeat.control(agentId: "z", title: "Session", name: "Ops", host: nil).label, "Ops")
    }
}

final class SeenListMigrationTests: XCTestCase {
    @MainActor
    func testOldGlobalSeenListsMoveToTheControlSeatOnceAndNeverToOtherSeats() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "sift-seen-\(UUID().uuidString)"))
        defaults.set(["ask-1"], forKey: "seenAsks")
        defaults.set(["perm-1"], forKey: "seenPermissions")
        let control = ControlSeat(agentId: "c1", title: "Control")
        SeatSession.migrateSeenLists(to: control, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "seenAsks.c1"), ["ask-1"])
        XCTAssertEqual(defaults.stringArray(forKey: "seenPermissions.c1"), ["perm-1"])
        XCTAssertNil(defaults.stringArray(forKey: "seenAsks"))
        XCTAssertNil(defaults.stringArray(forKey: "seenPermissions"))
        XCTAssertNil(defaults.stringArray(forKey: "seenAsks.f1"), "a later seat starts with nothing seen")
        // Running again changes nothing, and a seat's own list is never overwritten.
        defaults.set(["ask-9"], forKey: "seenAsks")
        SeatSession.migrateSeenLists(to: control, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "seenAsks.c1"), ["ask-1"])
        XCTAssertNil(defaults.stringArray(forKey: "seenAsks"))
    }
}
