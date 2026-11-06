import XCTest
@testable import LarkMini

final class ControlFidelityTests: XCTestCase {
    private let source = #"""
    {"status":"running","entries":[
     {"id":"u1","type":"user_message","text":"Check the build","ts":1000},
     {"id":"e:1","type":"reasoning","ts":1001,"item":{"type":"reasoning","text":"Look at CI first"}},
     {"id":"e:2","type":"tool_call","ts":1002,"item":{"type":"tool_call","callId":"c1","name":"Bash","status":"completed","error":null,
       "detail":{"type":"shell","command":"make test","output":"2 failed","exitCode":1}}},
     {"id":"e:3","type":"tool_call","ts":1003,"item":{"type":"tool_call","callId":"c2","name":"Edit","status":"completed","error":null,
       "detail":{"type":"edit","filePath":"Sources/App.swift","unifiedDiff":"-a\n+b"}}},
     {"id":"e:4","type":"todo","ts":1004,"item":{"type":"todo","items":[{"text":"Fix CI","completed":true},{"text":"Ship","completed":false,"status":"in_progress"}]}},
     {"id":"e:5","type":"error","ts":1005,"item":{"type":"error","message":"Provider rate limit"}},
     {"id":"a1","type":"assistant_message","text":"Fixed.","ts":1006},
     {"id":"e:6","type":"plugin","ts":1007,"item":{"type":"plugin","id":"p","pluginId":"control-plugins","kind":"card","version":1,"data":{"x":1}}},
     {"id":"e:7","type":"tool_call","ts":1008,"item":{"type":"tool_call","callId":"c3","name":"send","status":"failed","error":"refused",
       "detail":{"type":"unknown","input":null,"output":null},"agentMessage":{"type":"send_agent_message","agentId":"x","text":"Please review"}}},
     {"id":"e:8","type":"notification","ts":1009,"item":{"type":"notification","level":"warning","message":"Context is 90% full"}}
    ],"permissions":[
     {"id":"q1","kind":"question","name":"AskUserQuestion","title":"","description":"",
      "input":{"questions":[{"question":"Which branch?","options":[{"label":"main"},{"label":"dev"}]}]},"actions":["Submit"]},
     {"id":"t1","kind":"tool","name":"Bash","title":"Run a command","detail":{"type":"shell","command":"rm -rf build"},"actions":["Allow","Deny"]}],
     "serverId":"srv_example"}
    """#

    func testEveryEntryTypeKeepsItsPlaceWithoutBecomingAReply() throws {
        let reading = try XCTUnwrap(PaseoClient.reading(source))
        XCTAssertEqual(reading.messages.map(\.id), ["u1", "a1"], "only real messages drive reply attention")
        let shape = reading.timeline.map { entry -> String in
            switch entry {
            case .message(let message): return "message:\(message.id)"
            case .work(_, let steps): return "work:" + steps.map(\.kind).joined(separator: ",")
            case .notice(_, let level, _, _): return "notice:\(level)"
            }
        }
        XCTAssertEqual(shape, ["message:u1", "work:reasoning,shell,edit,todo", "notice:error", "message:a1",
                               "work:plugin,unknown", "notice:warning"])
        guard case .work(_, let steps) = reading.timeline[1] else { return XCTFail() }
        XCTAssertEqual(steps[1].target, "make test")
        XCTAssertTrue(steps[1].failed, "a non-zero exit is a failure")
        XCTAssertEqual(steps[1].detail, "2 failed\nExit code 1")
        XCTAssertEqual(steps[2].detail, "-a\n+b")
        XCTAssertEqual(steps[3].target, "1 of 2 done")
        XCTAssertEqual(steps[3].todos.map(\.status), ["completed", "in_progress"])
        XCTAssertEqual(AgentStep.summary(steps), "4 steps · 1 command, 1 edit, 1 thought, 1 checklist · 1 failed")
        guard case .work(_, let later) = reading.timeline[4] else { return XCTFail() }
        XCTAssertTrue(later[0].unrendered, "plugin content is named, not hidden")
        XCTAssertEqual(later[1].title, "Messaged an agent")
        XCTAssertEqual(later[1].detail, "Please review\nError: refused")
        XCTAssertEqual(reading.serverId, "srv_example")
    }

    func testRequestsKeepTheirKindContentAndChoices() throws {
        let reading = try XCTUnwrap(PaseoClient.reading(source))
        XCTAssertEqual(reading.permissions.map(\.id), ["q1", "t1"])
        XCTAssertEqual(reading.permissions[0].heading, "Question for you")
        XCTAssertEqual(reading.permissions[0].detail, "Which branch?\n• main\n• dev")
        XCTAssertEqual(reading.permissions[1].heading, "Wants to use Bash")
        XCTAssertEqual(reading.permissions[1].detail, "rm -rf build")
        XCTAssertEqual(reading.permissions[1].actions, ["Allow", "Deny"])
        XCTAssertEqual(reading.permissions[1].summary, "Wants to use Bash: Run a command")
    }
}
