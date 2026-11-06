import SwiftUI

struct ControlChatView: View {
    @EnvironmentObject var store: Store
    @Environment(\.siftReduceMotion) private var reduceMotion
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ControlMark(size: 32, running: store.controlActivity != nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Control").font(.system(size: 20, weight: .semibold))
                    Text(store.controlSeat?.title ?? "Paseo")
                        .font(.system(size: 11)).foregroundStyle(SiftStyle.secondary).lineLimit(1)
                }
                .panelDragHandle().help("Drag to move Sift")
                Spacer(minLength: 0)
                if store.openAskCount > 0 {
                    Button { store.controlFocusAsks = true } label: {
                        Label(store.openAskCount == 1 ? "1 ask" : "\(store.openAskCount) asks", systemImage: "hand.raised")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(SiftStyle.green)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(SiftStyle.green.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain).help("Jump to open asks")
                }
                IconButton(symbol: "arrow.clockwise", help: "Refresh conversation") {
                    store.errorText = nil
                    Task { await store.refreshControl() }
                }.disabled(store.controlBusy)
            }
            .padding(.horizontal, 16).frame(height: 76)
            Rectangle().fill(SiftStyle.line).frame(height: 1)
            transcript
            // Outside the scroll view: an animating row inside lazy, bottom-anchored content
            // re-measured the whole transcript every frame and pegged the main thread.
            if store.controlNeedsInput || store.controlActivity != nil || ["archived", "error"].contains(store.controlStatus) {
                liveState.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
            }
            if let error = store.errorText { ErrorBar(text: error) }
            composer
        }
        .task { await store.refreshControl() }
        .environment(\.openURL, OpenURLAction { url in
            guard let id = ChatLinks.chatId(from: url) else { return .systemAction }
            store.openLinkedChat(id)
            return .handled
        })
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    asks.id("asks")
                    if store.controlHasOlder && !store.controlMessages.isEmpty {
                        Text("Recent messages · earlier history is in Paseo")
                            .font(.system(size: 11)).foregroundStyle(SiftStyle.muted).padding(.bottom, 16)
                    }
                    if store.controlMessages.isEmpty {
                        PaneEmptyState(symbol: "command", title: store.controlBusy ? "Loading conversation" : store.errorText != nil ? "Conversation unavailable" : "What are we working on?",
                            detail: store.errorText != nil ? "Refresh to try again. Your draft stays here." : "Send a task or pick up where you left off with your agent.")
                    }
                    ForEach(Array(store.controlMessages.enumerated()), id: \.element.id) { index, message in
                        let grouped = message.groups(with: index > 0 ? store.controlMessages[index - 1] : nil)
                        PaseoBubble(message: message, showHeader: !grouped, links: store.chatLinks)
                            .padding(.top, index == 0 ? 0 : grouped ? 6 : 22).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .id(store.controlSeat?.agentId)
            .onChange(of: store.controlFocusAsks, initial: true) {
                guard store.controlFocusAsks else { return }
                store.controlFocusAsks = false
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("asks", anchor: .top) }
            }
            .onChange(of: store.controlMessages.last?.id) { old, _ in
                guard old != nil else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var asks: some View {
        switch store.asks {
        case .off: EmptyView()
        case .unavailable(let reason):
            Text("Asks unknown · \(reason)").font(.system(size: 11)).foregroundStyle(SiftStyle.muted).padding(.bottom, 16)
        case .available(let open):
            ForEach(open) { AskCard(ask: $0, links: store.chatLinks).padding(.bottom, 12) }
            if !open.isEmpty { Color.clear.frame(height: 10) }
        }
    }

    /// One line for what Control is doing now; idle sessions show nothing.
    @ViewBuilder private var liveState: some View {
        if store.controlNeedsInput {
            Label("Waiting for your permission · answer it in Paseo", systemImage: "hand.raised")
                .font(.system(size: 12)).foregroundStyle(SiftStyle.green)
        } else if let activity = store.controlActivity {
            HStack(spacing: 8) {
                ActivityDots()
                Text(activity).font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Control: \(activity)")
        } else if store.controlStatus == "archived" {
            Text("This session is archived. Sift moves to the next Control once Paseo names one.")
                .font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
        } else if store.controlStatus == "error" {
            Text("Control stopped with an error.").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Control…", text: $store.controlDraft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5)
                    .frame(minHeight: 44, alignment: .topLeading)
                    .focused($composing)
                    .onSubmit { if canSend { Task { await store.sendControl() } } }
                    .accessibilityLabel("Message Control")
                Button { Task { await store.sendControl() } } label: {
                    Image(systemName: store.controlSending ? "clock" : "arrow.up")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                        .foregroundStyle(canSend ? Color.black : SiftStyle.muted)
                        .background(canSend ? Color.white : Color.white.opacity(0.05), in: Circle())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain).disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send to Control (⌘Return)").accessibilityLabel("Send to Control")
            }
            .composerSurface().padding(.bottom, 12)
        }
    }

    private var canSend: Bool {
        !store.controlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.controlSending
    }
}

/// Small, steady sign of a running turn; Reduce Motion keeps it still.
/// Only opacity animates, so a frame never invalidates layout.
struct ActivityDots: View {
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                let dot = Circle().fill(SiftStyle.green).frame(width: 4, height: 4)
                if reduceMotion { dot.opacity(0.7) }
                else {
                    dot.phaseAnimator([0.3, 1]) { content, opacity in content.opacity(opacity) }
                        animation: { _ in .easeInOut(duration: 0.6).delay(Double(index) * 0.2) }
                }
            }
        }
        .frame(width: 18, height: 4).accessibilityHidden(true)
    }
}

/// An open ask from the Control's runner. Answers stay on its board.
struct AskCard: View {
    let ask: OpenAsk
    var links = ChatLinks(chats: [])
    @State private var expanded = false

    private func linked(_ text: String) -> AttributedString {
        var result = LinkedText.attributed(text)
        links.link(&result)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs you" + (ask.plan.isEmpty ? "" : " · " + ask.plan), systemImage: "hand.raised")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(SiftStyle.green)
            if !ask.title.isEmpty { Text(ask.title).font(.system(size: 13, weight: .semibold)) }
            Text(linked(ask.question)).font(.system(size: 12)).lineSpacing(3)
                .lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: true)
            if !ask.recommendation.isEmpty {
                Text(linked("Recommended: " + ask.recommendation)).font(.system(size: 12))
                    .foregroundStyle(SiftStyle.secondary).lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if ask.question.count > 220 || ask.recommendation.count > 110 {
                    Button(expanded ? "Show less" : "Read the whole ask") { expanded.toggle() }.buttonStyle(.plain)
                }
                Spacer()
                if let link = ask.link { Link(link.host?.contains("linear") == true ? "Answer in Linear" : "Open ask", destination: link) }
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(SiftStyle.green)
        }
        .textSelection(.enabled)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SiftStyle.green.opacity(0.35)))
    }
}

struct PaseoBubble: View {
    let message: AgentMessage
    var showHeader = true
    var links = ChatLinks(chats: [])
    @State private var expanded = false
    private var blocks: [ReplyBlock] { ReplyBlock.cached(message.displayText) }
    private var isLong: Bool { message.isAssistant && message.text.count > 1200 && blocks.count > 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeader {
                HStack(spacing: 6) {
                    switch message.origin {
                    case .control: Image(systemName: "command").foregroundStyle(SiftStyle.green)
                    case .agent: Image(systemName: "person.2")
                    case .automation: Image(systemName: "gearshape")
                    case .you: EmptyView()
                    }
                    Text(message.speaker).lineLimit(1)
                    if let ts = message.ts { Text(TimeFormat.clock(ts)).foregroundStyle(SiftStyle.muted) }
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(SiftStyle.secondary)
            }
            if message.isContext && !expanded {
                Button { expanded = true } label: {
                    Text(UpdateText.short(message.displayText, limit: 140))
                        .font(.system(size: 12)).foregroundStyle(SiftStyle.muted).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).help("Show the full message").accessibilityHint("Shows the full message")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array((isLong && !expanded ? Array(blocks.prefix(2)) : blocks).enumerated()), id: \.offset) { _, block in
                        ReplyBlockView(block: block, links: links)
                    }
                }
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if isLong || message.isContext {
                    Button(expanded ? "Show less" : "Read full reply") { expanded.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SiftStyle.green)
                }
            }
        }
        .padding(message.isMine ? 12 : 0)
        .background(message.isMine ? SiftStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ReplyBlockView: View {
    let block: ReplyBlock
    var links = ChatLinks(chats: [])
    /// Monospaced code reads larger than body text at the same size; one point smaller evens lines.
    private var inline: AttributedString {
        var text = ReplyBlock.inline(block.text)
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: block.kind == .heading ? 13 : 12, design: .monospaced)
        }
        if block.kind != .code { links.link(&text) }
        return text
    }

    var body: some View {
        if block.kind == .code {
            ScrollView(.horizontal) {
                Text(block.text).font(.system(size: 11, design: .monospaced)).fixedSize()
                    .padding(10)
            }.background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 6))
        } else {
            HStack(alignment: .top, spacing: 8) {
                if let marker = block.marker {
                    Text(marker).foregroundStyle(SiftStyle.green).frame(minWidth: 12, alignment: .trailing)
                }
                Text(inline).font(.system(size: block.kind == .heading ? 14 : 13,
                                         weight: block.kind == .heading ? .semibold : .regular))
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
