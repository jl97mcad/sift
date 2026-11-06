import XCTest
@testable import LarkMini

final class InboxTests: XCTestCase {
    // Run with CFFIXED_USER_HOME pointing to a disposable directory.
    override func setUpWithError() throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("/dist/test-home") else {
            throw XCTSkip("Use CFFIXED_USER_HOME=$PWD/dist/test-home swift test to isolate local state")
        }
    }

    func testInboxIncludesPinnedUnreadAndSeparatesHistory() async {
        await MainActor.run {
            let store = Store.demo()
            XCTAssertEqual(store.visibleChats.map(\.id), ["c1", "c3", "c5"])
            XCTAssertEqual(store.unreadCount, store.visibleChats.count)
            XCTAssertEqual(store.messages.count, store.chats.count)
            XCTAssertEqual(store.messages["c3"]?.last?.id, store.previews["c3"]?.messageId)
            store.showAllChats = true
            XCTAssertEqual(store.visibleChats.count, 8)
            XCTAssertTrue(store.visibleChats.contains { $0.id == "c2" })
            XCTAssertTrue(store.visibleChats.contains { $0.id == "c7" })
        }
    }

    func testReadAndMuteRemoveOnlyAttentionAndClampSelection() async {
        await MainActor.run {
            let store = Store.demo()
            store.listSelection = 2
            store.markSelectedRead()
            XCTAssertEqual(store.visibleChats.map(\.id), ["c1", "c3"])
            XCTAssertEqual(store.listSelection, 1)
            store.mute(store.chats[2])
            XCTAssertEqual(store.visibleChats.map(\.id), ["c1"])
            store.showAllChats = true
            XCTAssertEqual(store.visibleChats.count, 8)
            XCTAssertEqual(Store.demo().visibleChats.map(\.id), ["c1", "c3", "c5"])
        }
    }

    func testRailNavigationLeavesNoPaneCoveringConversation() async {
        await MainActor.run {
            let store = Store.demo()
            store.controlOpen = true
            store.showingSettings = true
            store.searchOpen = true
            store.open(store.chats[0])
            XCTAssertFalse(store.controlOpen)
            XCTAssertFalse(store.showingSettings)
            XCTAssertFalse(store.searchOpen)
            XCTAssertEqual(store.openChat?.id, "c1")
            store.showInbox()
            XCTAssertNil(store.openChat)
            XCTAssertFalse(store.showAllChats)
            store.showingSettings = true
            store.openControl()
            XCTAssertTrue(store.controlOpen)
            XCTAssertFalse(store.showingSettings)
            XCTAssertNil(store.openChat)
        }
    }
}
