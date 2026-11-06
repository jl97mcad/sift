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

final class AttachmentQueueTests: XCTestCase {
    @MainActor
    func testConcurrentDropsAreAllAttemptedAndFailuresNamed() async throws {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.contains("/dist/test-home") == true else {
            throw XCTSkip("Use CFFIXED_USER_HOME=$PWD/dist/test-home swift test to isolate local state")
        }
        let store = Store()   // the isolated test home has no sign-in, so every upload fails
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.txt"), second = folder.appendingPathComponent("second.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        async let one: Void = store.sendAttachment(first, to: "chat")
        async let two: Void = store.sendAttachment(second, to: "chat")
        _ = await (one, two)
        let error = try XCTUnwrap(store.errorText)
        XCTAssertTrue(error.contains("first.txt") && error.contains("second.txt"), error)
        XCTAssertFalse(store.sending)
    }
}

final class DraftFileTests: XCTestCase {
    func testDraftsSaveAs0600AndMoveOutOfPreferencesOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drafts.json")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "sift-drafts-\(UUID().uuidString)"))
        defaults.set(["c1": "half a thought"], forKey: "drafts")
        defaults.set("ship it", forKey: "controlDraft")

        XCTAssertEqual(DraftFile.load(from: url, defaults: defaults), DraftFile(chats: ["c1": "half a thought"], control: "ship it"))
        XCTAssertNil(defaults.object(forKey: "drafts"))
        XCTAssertNil(defaults.object(forKey: "controlDraft"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        try DraftFile(chats: ["c1": "", "c2": "new"], control: "").save(to: url)
        XCTAssertEqual(DraftFile.load(from: url, defaults: defaults), DraftFile(chats: ["c2": "new"], control: ""))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["drafts.json"], "no staged file is left")
    }

    @MainActor
    func testDropFailuresAddToTheSameNamedList() {
        let store = Store.demo()
        store.reportUnsent(["a.png: unreadable"])
        store.reportUnsent(["b.pdf: unreadable"])
        XCTAssertEqual(store.errorText, "Not sent — a.png: unreadable; b.pdf: unreadable")
    }
}
