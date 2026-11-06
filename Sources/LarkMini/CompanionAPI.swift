import Foundation

struct CompanionShop: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let detail: String
}

struct CompanionChat: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case lark
        case shopAgent
    }

    let id: String
    let kind: Kind
    let name: String
    let preview: String
    let unread: Int
}

struct CompanionMessage: Identifiable, Equatable {
    enum Author: String, Equatable {
        case you
        case ollie
    }

    let id: String
    let author: Author
    let text: String
    let ts: Int64

    var isMine: Bool { author == .you }
}

struct CompanionPlan: Identifiable, Equatable {
    enum Status: String, Equatable {
        case proposed
        case approved
        case dismissed

        var label: String {
            switch self {
            case .proposed: return "Proposed"
            case .approved: return "Approved"
            case .dismissed: return "Dismissed"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let status: Status

    var isOpen: Bool { status == .proposed }
}

enum CompanionPlanAction: String {
    case approve
}

enum CompanionReplyEvent: Equatable {
    case userMessage(CompanionMessage)
    case delta(String)
    case completed(CompanionMessage)
}

enum CompanionAPIError: LocalizedError, Equatable {
    case notConfigured(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let endpoint):
            return "Companion is not connected yet. Pending contract for \(endpoint)."
        case .message(let text):
            return text
        }
    }
}

protocol CompanionAPIClient: AnyObject {
    func assignedShops() async throws -> [CompanionShop]
    func unreadChats(shopId: String) async throws -> [CompanionChat]
    func messages(shopId: String) async throws -> [CompanionMessage]
    func send(shopId: String, text: String) -> AsyncThrowingStream<CompanionReplyEvent, Error>
    func plans(shopId: String) async throws -> [CompanionPlan]
    func updatePlan(shopId: String, planId: String, action: CompanionPlanAction) async throws -> CompanionPlan
}

@MainActor
final class CompanionStore: ObservableObject {
    private let client: CompanionAPIClient
    private var loaded = false

    @Published private(set) var shops: [CompanionShop] = []
    @Published private(set) var selectedShopId: String?
    @Published private(set) var unreadChats: [CompanionChat] = []
    @Published private(set) var messages: [CompanionMessage] = []
    @Published private(set) var plans: [CompanionPlan] = []
    @Published private(set) var streamingText: String?
    @Published private(set) var loading = false
    @Published private(set) var sending = false
    @Published private(set) var approvingPlanId: String?
    @Published var draft = ""
    @Published var errorText: String?

    init(client: CompanionAPIClient) {
        self.client = client
    }

    var selectedShop: CompanionShop? {
        shops.first { $0.id == selectedShopId }
    }

    var openPlans: [CompanionPlan] {
        plans.filter(\.isOpen)
    }

    func load() async {
        guard !loaded, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            shops = try await client.assignedShops()
            if selectedShopId == nil || !shops.contains(where: { $0.id == selectedShopId }) {
                selectedShopId = shops.first?.id
            }
            loaded = true
            await loadSelectedShop()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func refresh() async {
        loaded = false
        errorText = nil
        await load()
    }

    func selectShop(_ id: String) async {
        guard id != selectedShopId, shops.contains(where: { $0.id == id }) else { return }
        selectedShopId = id
        errorText = nil
        streamingText = nil
        await loadSelectedShop()
    }

    private func loadSelectedShop() async {
        guard let shopId = selectedShopId else {
            unreadChats = []
            messages = []
            plans = []
            return
        }
        do {
            let chats = try await client.unreadChats(shopId: shopId)
            let thread = try await client.messages(shopId: shopId)
            let list = try await client.plans(shopId: shopId)
            guard selectedShopId == shopId else { return }
            unreadChats = chats
            messages = thread
            plans = list
        } catch {
            errorText = error.localizedDescription
        }
    }

    func send() async {
        guard let shopId = selectedShopId, !sending else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        draft = ""
        errorText = nil
        var streamed = ""
        do {
            for try await event in client.send(shopId: shopId, text: text) {
                switch event {
                case .userMessage(let message):
                    if !messages.contains(where: { $0.id == message.id }) {
                        messages.append(message)
                    }
                case .delta(let piece):
                    streamed += piece
                    streamingText = streamed
                case .completed(let message):
                    streamingText = nil
                    if !messages.contains(where: { $0.id == message.id }) {
                        messages.append(message)
                    }
                }
            }
        } catch {
            errorText = error.localizedDescription
            if draft.isEmpty { draft = text }
        }
        streamingText = nil
        sending = false
    }

    func approve(_ plan: CompanionPlan) async {
        guard let shopId = selectedShopId, plan.isOpen, approvingPlanId == nil else { return }
        approvingPlanId = plan.id
        errorText = nil
        do {
            let updated = try await client.updatePlan(shopId: shopId, planId: plan.id, action: .approve)
            if let index = plans.firstIndex(where: { $0.id == plan.id }) {
                plans[index] = updated
            }
        } catch {
            errorText = error.localizedDescription
        }
        approvingPlanId = nil
    }
}
