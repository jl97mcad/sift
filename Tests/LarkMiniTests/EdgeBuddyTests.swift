import XCTest
@testable import LarkMini

final class EdgeBuddyTests: XCTestCase {
    func testArrivalsCoalesceAndNeverCoverAControlNeed() {
        let first = EdgeBubble.arrival(nil, chatId: "c1", name: "Sam Patel", text: "Lunch?")
        XCTAssertEqual(first.target, .chat("c1"))
        XCTAssertEqual(first.title, "Sam Patel")
        let again = EdgeBubble.arrival(first, chatId: "c1", name: "Sam Patel", text: "Or later")
        XCTAssertEqual(again.id, first.id, "a burst keeps one bubble, so it springs once")
        XCTAssertEqual(again.title, "Sam Patel · 2 new")
        XCTAssertEqual(again.target, .chat("c1"))
        let mixed = EdgeBubble.arrival(EdgeBubble.arrival(again, chatId: "c2", name: "Riley Chen", text: "Build is green"),
                                       chatId: "c3", name: "Design Room", text: "New icons")
        XCTAssertEqual(mixed.target, .inbox)
        XCTAssertEqual(mixed.title, "4 new · Sam Patel, Riley Chen +1")
        XCTAssertEqual(mixed.text, "New icons")
        let need = EdgeBubble(target: .control, title: "Control needs you", text: "Publish now?")
        XCTAssertEqual(EdgeBubble.arrival(need, chatId: "c1", name: "Sam Patel", text: "Hi"), need)
    }

    func testPermissionRequestsKeepTheirIdsForSeenTracking() throws {
        let reading = try XCTUnwrap(PaseoClient.reading(#"{"status":"running","needsInput":true,"entries":[],"permissions":[{"id":"perm-1","title":"Run tests"},{"id":"","title":"no id"}]}"#))
        XCTAssertEqual(reading.permissions, [PermissionRequest(id: "perm-1", title: "Run tests")])
        XCTAssertTrue(reading.needsInput)
    }

    func testGazeLooksTowardThePointerAndGlowsOnlyNearby() {
        let near = GazeTracker.look(dx: 22, dy: 0)
        XCTAssertEqual(near.proximity, 1)
        XCTAssertGreaterThan(near.offset.width, 0)
        XCTAssertEqual(GazeTracker.look(dx: 0, dy: 300).proximity, 0)
        XCTAssertLessThan(GazeTracker.look(dx: 0, dy: 300).offset.height, 0, "screen y points up; view y points down")
        XCTAssertEqual(GazeTracker.look(dx: 400, dy: 0).offset.width, 2.8, accuracy: 0.001)
    }
}
