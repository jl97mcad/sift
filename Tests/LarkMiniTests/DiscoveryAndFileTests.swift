import XCTest
@testable import LarkMini

final class DiscoveryAndFileTests: XCTestCase {
    func testDiscoveryIsBoundedAndReachesHiddenChatsDespiteReordering() {
        var discovery = PreviewDiscovery()
        let ids = (1...11).map { "chat-\($0)" }
        var found = Set<String>()
        for tick in 0..<4 {
            let batch = discovery.next(tick.isMultiple(of: 2) ? ids : ids.reversed(), limit: 3)
            XCTAssertEqual(batch.count, 3)
            found.formUnion(batch)
        }
        XCTAssertEqual(found, Set(ids))
        XCTAssertEqual(discovery.next([], limit: 3), [])
        XCTAssertEqual(discovery.next(["a", "a"], limit: 3), ["a"])
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
