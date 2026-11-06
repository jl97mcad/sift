import XCTest
@testable import LarkMini

final class DiscoveryAndFileTests: XCTestCase {
    func testActivityOrderNamesOnlyChatsWithNewActivity() {
        let before = ["a", "b", "c", "d", "e"]
        // First read: no history, so only the top is checked.
        XCTAssertEqual(ActivityOrder.changes(previous: [], current: before).refresh, ["a", "b"])
        XCTAssertEqual(ActivityOrder.changes(previous: [], current: before).moved, [])
        // Unchanged: the top two only (more activity at the top keeps the order).
        XCTAssertEqual(ActivityOrder.changes(previous: before, current: before).refresh, ["a", "b"])
        // d got a message and jumped to the top; the others only shifted down.
        let jumped = ActivityOrder.changes(previous: before, current: ["d", "a", "b", "c", "e"])
        XCTAssertEqual(jumped.moved, ["d"])
        XCTAssertEqual(jumped.refresh, ["d", "a"])
        // A chat from beyond the list arrived above the rest.
        let arrived = ActivityOrder.changes(previous: before, current: ["x", "a", "b", "c", "d"])
        XCTAssertEqual(arrived.moved, ["x"])
        // b left the list: c, d, e shift up and f enters at the bottom, but nobody overtook anyone.
        XCTAssertEqual(ActivityOrder.changes(previous: before, current: ["a", "c", "d", "e", "f"]).moved, [])
        // c and e both had activity, e more recently.
        XCTAssertEqual(ActivityOrder.changes(previous: before, current: ["e", "c", "a", "b", "d"]).moved, ["e", "c"])
    }

    func testResourceURLUsesMessageAuthenticationEndpointAndEscapesSegments() {
        let url = LarkAPI.messageResourceURL(messageId: "m/id", key: "file?#%", type: "file")
        XCTAssertEqual(url.host, "open.larksuite.com")
        XCTAssertEqual(url.absoluteString, "https://open.larksuite.com/open-apis/im/v1/messages/m%2Fid/resources/file%3F%23%25?type=file")
    }

    func testDownloadedFileReplacesOnlyAfterSuccessfulStaging() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let source = directory.appendingPathComponent("download")
        let target = directory.appendingPathComponent("saved.txt")
        try Data("old".utf8).write(to: target)
        XCTAssertThrowsError(try LarkAPI.saveDownload(source, to: target))
        XCTAssertEqual(try String(contentsOf: target), "old")
        try Data("new".utf8).write(to: source)
        try LarkAPI.saveDownload(source, to: target)
        XCTAssertEqual(try String(contentsOf: target), "new")
        XCTAssertEqual(try files.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: directory.path).sorted(), ["download", "saved.txt"])
    }
}
