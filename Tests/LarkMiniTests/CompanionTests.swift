import XCTest
@testable import LarkMini

final class CompanionTests: XCTestCase {
    func testMockProvidesAssignedShopsAndBothUnreadKinds() async throws {
        let client = MockCompanionAPIClient(deltaDelayNanoseconds: 0)
        let shops = try await client.assignedShops()
        XCTAssertFalse(shops.isEmpty)
        let chats = try await client.unreadChats(shopId: shops[0].id)
        XCTAssertTrue(chats.contains { $0.kind == .lark })
        XCTAssertTrue(chats.contains { $0.kind == .shopAgent })
        let plans = try await client.plans(shopId: shops[0].id)
        XCTAssertTrue(plans.contains(where: \.isOpen))
    }

    @MainActor
    func testStoreLoadsFirstShopAndSwitches() async {
        let store = CompanionStore(client: MockCompanionAPIClient(deltaDelayNanoseconds: 0))
        await store.load()
        XCTAssertEqual(store.selectedShopId, "north-studio")
        XCTAssertFalse(store.unreadChats.isEmpty)
        XCTAssertFalse(store.messages.isEmpty)
        XCTAssertFalse(store.plans.isEmpty)

        await store.selectShop("harbor-co")
        XCTAssertEqual(store.selectedShopId, "harbor-co")
        XCTAssertEqual(store.unreadChats.map(\.id), ["harbor-agent", "harbor-ops"])
        XCTAssertEqual(store.plans.map(\.id), ["harbor-pause"])
    }

    @MainActor
    func testSendStreamsOllieReplyIntoTheTranscript() async {
        let store = CompanionStore(client: MockCompanionAPIClient(deltaDelayNanoseconds: 0))
        await store.load()
        let before = store.messages.count
        store.draft = "What needs me before handover?"

        await store.send()

        XCTAssertFalse(store.sending)
        XCTAssertNil(store.streamingText)
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertEqual(store.messages.count, before + 2)
        XCTAssertEqual(store.messages.suffix(2).map(\.author), [.you, .ollie])
        XCTAssertTrue(store.messages.last?.text.contains("What needs me before handover?") == true)
    }

    @MainActor
    func testApproveMovesAPlanOutOfTheOpenList() async {
        let store = CompanionStore(client: MockCompanionAPIClient(deltaDelayNanoseconds: 0))
        await store.load()
        guard let plan = store.openPlans.first else { return XCTFail("expected an open plan") }

        await store.approve(plan)

        XCTAssertNil(store.approvingPlanId)
        XCTAssertEqual(store.plans.first { $0.id == plan.id }?.status, .approved)
        XCTAssertFalse(store.openPlans.contains { $0.id == plan.id })
    }

    func testOllieAdapterRefusesUntilTheContractIsReviewed() async {
        let client = OllieCompanionAPIClient(
            baseURL: URL(string: "https://example.invalid")!, bearerToken: "test-token")
        do {
            _ = try await client.assignedShops()
            XCTFail("the real adapter must not answer before the contract is reviewed")
        } catch let error as CompanionAPIError {
            guard case .notConfigured = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
