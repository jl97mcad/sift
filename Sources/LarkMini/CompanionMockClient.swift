import Foundation

final class MockCompanionAPIClient: CompanionAPIClient {
    private struct Fixture {
        let chats: [CompanionChat]
        let messages: [CompanionMessage]
        let plans: [CompanionPlan]
    }

    private let shops: [CompanionShop] = [
        CompanionShop(id: "north-studio", name: "North Studio", detail: "Oxford · 3 open jobs"),
        CompanionShop(id: "harbor-co", name: "Harbor & Co", detail: "Bristol · 1 open job"),
        CompanionShop(id: "field-notes", name: "Field Notes", detail: "Remote · 5 open jobs")
    ]
    private let fixtures: [String: Fixture]
    private let deltaDelayNanoseconds: UInt64

    init(deltaDelayNanoseconds: UInt64 = 55_000_000) {
        self.deltaDelayNanoseconds = deltaDelayNanoseconds
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let minute: Int64 = 60_000
        fixtures = [
            "north-studio": Fixture(
                chats: [
                    CompanionChat(id: "north-design", kind: .lark, name: "Design Room",
                                  preview: "Sam: Friday delivery is confirmed.", unread: 3),
                    CompanionChat(id: "north-agent", kind: .shopAgent, name: "North shop agent",
                                  preview: "Two orders still need a delivery date.", unread: 2),
                    CompanionChat(id: "north-printer", kind: .lark, name: "Printer",
                                  preview: "Quote attached for the reprint.", unread: 1)
                ],
                messages: [
                    CompanionMessage(id: "north-ollie-1", author: .ollie,
                                     text: "Morning. North Studio is steady. The reprint quote came in and the Friday courier is booked.",
                                     ts: now - 42 * minute),
                    CompanionMessage(id: "north-you-1", author: .you,
                                     text: "Anything that needs me before the handover?",
                                     ts: now - 40 * minute),
                    CompanionMessage(id: "north-ollie-2", author: .ollie,
                                     text: "Two things: approve the stock reorder, and the shop agent needs a delivery date for orders 118 and 121.",
                                     ts: now - 39 * minute)
                ],
                plans: [
                    CompanionPlan(id: "north-reorder", title: "Reorder 200 gsm stock",
                                  detail: "Order 400 sheets from the usual supplier. Lead time is four working days; current stock covers three.",
                                  status: .proposed),
                    CompanionPlan(id: "north-courier", title: "Book Friday courier",
                                  detail: "Collection at 16:00 for the confirmed design-room delivery.",
                                  status: .approved)
                ]),
            "harbor-co": Fixture(
                chats: [
                    CompanionChat(id: "harbor-agent", kind: .shopAgent, name: "Harbor shop agent",
                                  preview: "Click-and-collect is at capacity for Saturday.", unread: 4),
                    CompanionChat(id: "harbor-ops", kind: .lark, name: "Harbor Ops",
                                  preview: "Can we move the stock count to Tuesday?", unread: 1)
                ],
                messages: [
                    CompanionMessage(id: "harbor-ollie-1", author: .ollie,
                                     text: "Harbor & Co is open. Saturday click-and-collect is nearly full, and the stock count request is waiting on a date.",
                                     ts: now - 25 * minute)
                ],
                plans: [
                    CompanionPlan(id: "harbor-pause", title: "Pause click-and-collect this weekend",
                                  detail: "Stop new weekend slots until Monday. Existing bookings stay as they are.",
                                  status: .proposed)
                ]),
            "field-notes": Fixture(
                chats: [
                    CompanionChat(id: "field-agent", kind: .shopAgent, name: "Field Notes agent",
                                  preview: "The new paper samples arrived.", unread: 2),
                    CompanionChat(id: "field-team", kind: .lark, name: "Field Team",
                                  preview: "Priya: samples look good in daylight.", unread: 5),
                    CompanionChat(id: "field-supplier", kind: .lark, name: "Paper Supplier",
                                  preview: "Updated price list for Q4.", unread: 1)
                ],
                messages: [
                    CompanionMessage(id: "field-ollie-1", author: .ollie,
                                     text: "Field Notes has five open jobs. The paper samples arrived and the Q4 price list is in the supplier chat.",
                                     ts: now - 18 * minute)
                ],
                plans: [
                    CompanionPlan(id: "field-samples", title: "Approve the new sample set",
                                  detail: "Approve the five paper samples for the autumn notebook run.",
                                  status: .proposed)
                ])
        ]
    }

    func assignedShops() async throws -> [CompanionShop] {
        shops
    }

    func unreadChats(shopId: String) async throws -> [CompanionChat] {
        try fixture(shopId).chats
    }

    func messages(shopId: String) async throws -> [CompanionMessage] {
        try fixture(shopId).messages
    }

    func plans(shopId: String) async throws -> [CompanionPlan] {
        try fixture(shopId).plans
    }

    func updatePlan(shopId: String, planId: String, action: CompanionPlanAction) async throws -> CompanionPlan {
        guard let plan = try fixture(shopId).plans.first(where: { $0.id == planId }) else {
            throw CompanionAPIError.message("That plan is no longer available.")
        }
        switch action {
        case .approve:
            return CompanionPlan(id: plan.id, title: plan.title, detail: plan.detail, status: .approved)
        }
    }

    func send(shopId: String, text: String) -> AsyncThrowingStream<CompanionReplyEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let fixture = try fixture(shopId)
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                continuation.yield(.userMessage(CompanionMessage(
                    id: "you-\(now)", author: .you, text: text, ts: now)))

                let shopName = shops.first { $0.id == shopId }?.name ?? "the shop"
                let reply = replyText(shopName: shopName, question: text, fixture: fixture)
                let task = Task {
                    let pieces = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                    for (index, piece) in pieces.enumerated() {
                        guard !Task.isCancelled else { return }
                        if deltaDelayNanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: deltaDelayNanoseconds)
                        }
                        continuation.yield(.delta(index == 0 ? piece : " " + piece))
                    }
                    guard !Task.isCancelled else { return }
                    continuation.yield(.completed(CompanionMessage(
                        id: "ollie-\(now)", author: .ollie, text: reply, ts: now + 1_000)))
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func fixture(_ shopId: String) throws -> Fixture {
        guard let fixture = fixtures[shopId] else {
            throw CompanionAPIError.message("That shop is not in this demo.")
        }
        return fixture
    }

    private func replyText(shopName: String, question: String, fixture: Fixture) -> String {
        let nextPlan = fixture.plans.first(where: \.isOpen)?.title
        let unread = fixture.chats.reduce(0) { $0 + $1.unread }
        var parts = [
            "Here is \(shopName) as it stands.",
            "I can see \(unread) unread message\(unread == 1 ? "" : "s") across the shop chats."
        ]
        if let nextPlan {
            parts.append("The open plan is \"\(nextPlan)\"; approve it when you are ready and I will take it from there.")
        } else {
            parts.append("There is no plan waiting for approval right now.")
        }
        parts.append("You asked: \"\(question)\"")
        return parts.joined(separator: " ")
    }
}
