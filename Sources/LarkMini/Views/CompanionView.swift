import SwiftUI

struct CompanionMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "building.2")
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(SiftStyle.green)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct CompanionView: View {
    @ObservedObject var companion: CompanionStore
    @Environment(\.siftReduceMotion) private var reduceMotion
    @FocusState private var composing: Bool
    @State private var tab = Tab.ollie

    private enum Tab: Hashable {
        case ollie
        case plans
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SiftStyle.line).frame(height: 1)
            shopPicker
            unreadStrip
            tabBar
            content
            if let error = companion.errorText { ErrorBar(text: error) }
            if tab == .ollie { composer }
        }
        .task { await companion.load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CompanionMark(size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Companion").font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary).lineLimit(1)
            }
            .panelDragHandle()
            .help("Drag to move Sift")
            Spacer(minLength: 0)
            if companion.loading {
                ProgressView().controlSize(.small).frame(width: 32)
            } else {
                IconButton(symbol: "arrow.clockwise", help: "Refresh shop") {
                    Task { await companion.refresh() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
    }

    private var subtitle: String {
        guard let shop = companion.selectedShop else {
            return "Scaffold · no shop selected"
        }
        return "Scaffold · \(shop.name) · \(shop.detail)"
    }

    private var shopPicker: some View {
        HStack(spacing: 8) {
            Label("Shop", systemImage: "building.2")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SiftStyle.secondary)
            if companion.shops.isEmpty {
                Text(companion.loading ? "Loading shops…" : "No shops assigned")
                    .font(.system(size: 12)).foregroundStyle(SiftStyle.muted)
            } else {
                Picker("Shop", selection: shopBinding) {
                    ForEach(companion.shops) { shop in
                        Text(shop.name).tag(shop.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text("\(companion.shops.count) assigned")
                .font(.system(size: 10)).foregroundStyle(SiftStyle.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var shopBinding: Binding<String> {
        Binding(
            get: { companion.selectedShopId ?? "" },
            set: { id in Task { await companion.selectShop(id) } }
        )
    }

    private var unreadStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Unread chats").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                Spacer(minLength: 0)
                if !companion.unreadChats.isEmpty {
                    Text("\(companion.unreadChats.reduce(0) { $0 + $1.unread })")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(SiftStyle.green)
                }
            }
            if companion.unreadChats.isEmpty {
                Text(companion.loading ? "Checking shop chats…" : "Nothing unread in this shop")
                    .font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(companion.unreadChats) { chat in
                            unreadCard(chat)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func unreadCard(_ chat: CompanionChat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: chat.kind == .lark ? "bubble.left" : "person.2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(chat.kind == .lark ? SiftStyle.secondary : SiftStyle.green)
                Text(chat.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(chat.unread)")
                    .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(SiftStyle.green.opacity(0.35)))
            }
            Text(chat.preview).font(.system(size: 10)).foregroundStyle(SiftStyle.secondary)
                .lineLimit(2).lineSpacing(1)
        }
        .padding(8)
        .frame(width: 168, alignment: .leading)
        .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SiftStyle.line))
        .help("\(chat.kind == .lark ? "Lark" : "Shop agent") · \(chat.name)")
    }

    private var tabBar: some View {
        HStack(spacing: 20) {
            tabButton(.ollie, title: "Ollie")
            tabButton(.plans, title: companion.openPlans.isEmpty ? "Plans" : "Plans \(companion.openPlans.count)")
            Spacer(minLength: 0)
            Text("Demo data").font(.system(size: 10)).foregroundStyle(SiftStyle.muted)
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(SiftStyle.line).frame(height: 1) }
    }

    private func tabButton(_ value: Tab, title: String) -> some View {
        Button { tab = value } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tab == value ? Color.white : SiftStyle.secondary)
                .padding(.vertical, 11)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(tab == value ? Color.white : .clear).frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if companion.selectedShopId == nil {
            PaneEmptyState(symbol: "building.2", title: "No shop selected",
                           detail: "Pick an assigned shop to see Ollie, plans and unread chats.")
        } else if tab == .ollie {
            transcript
        } else {
            planList
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if companion.messages.isEmpty {
                        PaneEmptyState(symbol: "bubble.left", title: "Ask Ollie about this shop",
                                       detail: "Ollie can read the shop chats and propose plans. Replies here are demo data.")
                    }
                    ForEach(companion.messages) { message in
                        CompanionBubble(message: message)
                    }
                    if let streaming = companion.streamingText {
                        StreamingBubble(text: streaming)
                    }
                    Color.clear.frame(height: 1).id("companion-bottom")
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .onChange(of: companion.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: companion.streamingText) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            proxy.scrollTo("companion-bottom", anchor: .bottom)
        }
    }

    private var planList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if companion.plans.isEmpty {
                    PaneEmptyState(symbol: "checkmark.seal", title: "No plans yet",
                                   detail: "When Ollie proposes work for this shop, it appears here for approval.")
                }
                ForEach(companion.plans) { plan in
                    PlanCard(
                        plan: plan,
                        approving: companion.approvingPlanId == plan.id,
                        approve: { Task { await companion.approve(plan) } }
                    )
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Ollie…", text: $companion.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5)
                .frame(minHeight: 44, alignment: .topLeading)
                .focused($composing)
                .onSubmit { if canSend { Task { await companion.send() } } }
                .accessibilityLabel("Message Ollie")
            Button { Task { await companion.send() } } label: {
                Image(systemName: companion.sending ? "clock" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                    .foregroundStyle(canSend ? Color.black : SiftStyle.muted)
                    .background(canSend ? Color.white : Color.white.opacity(0.05), in: Circle())
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain).disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send to Ollie (⌘Return)").accessibilityLabel("Send to Ollie")
        }
        .composerSurface().padding(.bottom, 12)
    }

    private var canSend: Bool {
        !companion.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !companion.sending
    }
}

private struct CompanionBubble: View {
    let message: CompanionMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isMine { Spacer(minLength: 40) } else { CompanionMark(size: 20) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                Text(message.isMine ? "You" : "Ollie")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(SiftStyle.muted)
                Text(message.text)
                    .font(.system(size: 13)).lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(message.isMine ? SiftStyle.raised : SiftStyle.green.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SiftStyle.line))
            }
            if message.isMine { CompanionMark(size: 20).hidden() } else { Spacer(minLength: 40) }
        }
    }
}

private struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CompanionMark(size: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Ollie").font(.system(size: 10, weight: .semibold)).foregroundStyle(SiftStyle.muted)
                    ActivityDots()
                }
                Text(text.isEmpty ? "Thinking…" : text)
                    .font(.system(size: 13)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(SiftStyle.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SiftStyle.line))
            }
            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ollie is replying")
    }
}

private struct PlanCard: View {
    let plan: CompanionPlan
    let approving: Bool
    let approve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label(plan.isOpen ? "Needs approval" : plan.status.label,
                      systemImage: plan.isOpen ? "hand.raised" : "checkmark.seal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(plan.isOpen ? SiftStyle.green : SiftStyle.muted)
                Spacer(minLength: 0)
                Text(plan.status.label)
                    .font(.system(size: 10)).foregroundStyle(SiftStyle.muted)
            }
            Text(plan.title).font(.system(size: 13, weight: .semibold))
            Text(plan.detail)
                .font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if plan.isOpen {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: approve) {
                        Label(approving ? "Approving…" : "Approve plan",
                              systemImage: approving ? "clock" : "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SiftStyle.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(approving)
                    .help("Approve this plan in the demo")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            plan.isOpen ? SiftStyle.green.opacity(0.35) : SiftStyle.line))
        .textSelection(.enabled)
    }
}
