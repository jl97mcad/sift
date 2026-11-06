import Foundation

// TODO(W01-4504): confirm against reviewed plan
enum OllieEndpoint {
    // TODO(W01-4504): confirm against reviewed plan
    static let shops = "oo/shops"
    // TODO(W01-4504): confirm against reviewed plan
    static func conversations(shop: String) -> String { "oo/shops/\(shop)/companion/conversations" }
    // TODO(W01-4504): confirm against reviewed plan
    static func ollie(shop: String) -> String { "oo/shops/\(shop)/companion/ollie" }
    // TODO(W01-4504): confirm against reviewed plan
    static func messages(shop: String) -> String { "oo/shops/\(shop)/companion/ollie/messages" }
    // TODO(W01-4504): confirm against reviewed plan
    static func plans(shop: String) -> String { "oo/shops/\(shop)/companion/ollie/plans" }
    // TODO(W01-4504): confirm against reviewed plan
    static func planAction(shop: String, plan: String) -> String { "oo/shops/\(shop)/companion/ollie/plans/\(plan)/actions" }
}

// TODO(W01-4504): confirm against reviewed plan
enum OllieWire {
    struct ShopsResponse: Decodable { let shops: [Shop] }
    struct Shop: Decodable {
        let id: String
        let name: String
        let detail: String
    }

    struct ConversationsResponse: Decodable { let conversations: [Conversation] }
    struct Conversation: Decodable {
        let id: String
        let kind: String
        let name: String
        let preview: String
        let unread: Int
    }

    struct MessagesResponse: Decodable { let messages: [Message] }
    struct Message: Decodable {
        let id: String
        let role: String
        let text: String
        let ts: Int64
    }
    struct SendBody: Encodable { let message: String }

    struct PlansResponse: Decodable { let plans: [Plan] }
    struct Plan: Decodable {
        let id: String
        let title: String
        let detail: String
        let status: String
    }
    struct PlanActionBody: Encodable { let action: String }
}

final class OllieCompanionAPIClient: CompanionAPIClient {
    private let baseURL: URL
    private let bearerToken: String

    init(baseURL: URL, bearerToken: String) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
    }

    func assignedShops() async throws -> [CompanionShop] {
        throw CompanionAPIError.notConfigured(OllieEndpoint.shops)
    }

    func unreadChats(shopId: String) async throws -> [CompanionChat] {
        throw CompanionAPIError.notConfigured(OllieEndpoint.conversations(shop: shopId))
    }

    func messages(shopId: String) async throws -> [CompanionMessage] {
        throw CompanionAPIError.notConfigured(OllieEndpoint.messages(shop: shopId))
    }

    func send(shopId: String, text: String) -> AsyncThrowingStream<CompanionReplyEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CompanionAPIError.notConfigured(OllieEndpoint.messages(shop: shopId)))
        }
    }

    func plans(shopId: String) async throws -> [CompanionPlan] {
        throw CompanionAPIError.notConfigured(OllieEndpoint.plans(shop: shopId))
    }

    func updatePlan(shopId: String, planId: String, action: CompanionPlanAction) async throws -> CompanionPlan {
        throw CompanionAPIError.notConfigured(OllieEndpoint.planAction(shop: shopId, plan: planId))
    }
}
