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
                if store.openNeedCount > 0 {
                    Button { store.controlFocusAsks = true } label: {
                        Label("\(store.openNeedCount) waiting", systemImage: "hand.raised")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(SiftStyle.green)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(SiftStyle.green.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain).help("Jump to what needs you")
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
                    if store.controlHasOlder && !store.controlTimeline.isEmpty {
                        if store.canLoadEarlierControl {
                            Button(store.controlBusy ? "Loading…" : "Earlier activity") { Task { await store.loadEarlierControl() } }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                                .disabled(store.controlBusy).padding(.bottom, 16)
                        } else {
                            Button("Older history is in Paseo") { store.openInPaseo() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(SiftStyle.muted).padding(.bottom, 16)
                        }
                    }
                    if store.controlTimeline.isEmpty {
                        PaneEmptyState(symbol: "command", title: store.controlBusy ? "Loading conversation" : store.errorText != nil ? "Conversation unavailable" : "What are we working on?",
                            detail: store.errorText != nil ? "Refresh to try again. Your draft stays here." : "Send a task or pick up where you left off with your agent.")
                    }
                    ForEach(Array(store.controlTimeline.enumerated()), id: \.element.id) { index, entry in
                        let previous = index > 0 ? store.controlTimeline[index - 1] : nil
                        switch entry {
                        case .message(let message):
                            let grouped = message.groups(with: previous?.message)
                            PaseoBubble(message: message, showHeader: !grouped, links: store.chatLinks)
                                .padding(.top, index == 0 ? 0 : grouped ? 6 : 22).id(entry.id)
                        case .work(_, let steps):
                            WorkRow(steps: steps).padding(.top, index == 0 ? 0 : 10).id(entry.id)
                        case .notice(_, let level, let text, _):
                            NoticeRow(level: level, text: text).padding(.top, index == 0 ? 0 : 10).id(entry.id)
                        }
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
            .onChange(of: store.controlTimeline.last?.id) { old, _ in
                guard old != nil else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var asks: some View {
        ForEach(store.controlPermissions, id: \.id) { request in
            PermissionCard(request: request) { store.openInPaseo() }.padding(.bottom, 12)
        }
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
            Button { store.controlFocusAsks = true } label: {
                Label(store.controlPermissions.count > 1 ? "\(store.controlPermissions.count) requests wait for you · answer in Paseo"
                      : "Waiting for you · answer in Paseo", systemImage: "hand.raised")
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SiftStyle.green).help("Show the request")
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

/// A pending Paseo request, named by kind with its content. Answers stay in Paseo.
struct PermissionCard: View {
    let request: PermissionRequest
    let answer: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs you · " + request.heading, systemImage: request.kind == "question" ? "questionmark.bubble" : "hand.raised")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(SiftStyle.green)
            if !request.title.isEmpty { Text(request.title).font(.system(size: 13, weight: .semibold)) }
            if !request.description.isEmpty {
                Text(request.description).font(.system(size: 12)).lineSpacing(3)
                    .lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: true)
            }
            if !request.detail.isEmpty {
                Text(request.detail).font(.system(size: 11, design: request.kind == "tool" ? .monospaced : .default))
                    .foregroundStyle(SiftStyle.secondary).lineLimit(expanded ? nil : 6).fixedSize(horizontal: false, vertical: true)
            }
            if !request.actions.isEmpty {
                Text("Choices in Paseo: " + request.actions.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
            }
            HStack {
                if request.description.count > 240 || request.detail.count > 300 {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }.buttonStyle(.plain)
                }
                Spacer()
                Button("Answer in Paseo", action: answer).buttonStyle(.plain)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(SiftStyle.green)
        }
        .textSelection(.enabled)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SiftStyle.green.opacity(0.35)))
    }
}

/// Control's work between messages: one quiet line that opens to each step and its output.
/// No animation: it sits inside the lazy, bottom-anchored transcript.
struct WorkRow: View {
    let steps: [AgentStep]
    @State private var expanded = false
    @State private var open = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Image(systemName: steps.contains(where: \.failed) ? "exclamationmark.triangle" : "gearshape.2")
                    Text(AgentStep.summary(steps)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(steps.contains(where: \.failed) ? Color.orange.opacity(0.9) : SiftStyle.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(expanded ? "Hide the steps" : "Show the steps")
            .accessibilityLabel("Control activity: \(AgentStep.summary(steps))")
            if let checklist = steps.last(where: { $0.kind == "todo" }), !expanded {
                TodoList(todos: checklist.todos).padding(.leading, 15)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in stepRow(step) }
                }
                .padding(.leading, 15)
            }
        }
    }

    @ViewBuilder private func stepRow(_ step: AgentStep) -> some View {
        let hasBody = !step.detail.isEmpty || !step.todos.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            Button { if open.contains(step.id) { open.remove(step.id) } else { open.insert(step.id) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(step.title).font(.system(size: 11, weight: .medium))
                    if !step.target.isEmpty {
                        Text(step.target).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                    if !step.status.isEmpty, step.status != "completed" {
                        Text(step.status).font(.system(size: 10)).foregroundStyle(step.failed ? Color.orange : SiftStyle.muted)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(SiftStyle.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!hasBody)
            if open.contains(step.id) {
                if step.unrendered {
                    Text("Sift has no view for this content yet; it is shown raw. Paseo shows it in full.")
                        .font(.system(size: 10)).foregroundStyle(SiftStyle.muted)
                }
                if !step.todos.isEmpty { TodoList(todos: step.todos) }
                if !step.detail.isEmpty {
                    ScrollView(.horizontal) {
                        Text(step.detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(SiftStyle.secondary)
                            .fixedSize().padding(8).textSelection(.enabled)
                    }
                    .frame(maxHeight: 220).background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

struct TodoList: View {
    let todos: [AgentStep.Todo]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                Label(todo.text, systemImage: todo.status == "completed" ? "checkmark.circle.fill"
                      : todo.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
                    .font(.system(size: 11)).foregroundStyle(todo.status == "completed" ? SiftStyle.muted : SiftStyle.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// A Paseo error or notification: visible, never folded into work.
struct NoticeRow: View {
    let level: String
    let text: String

    var body: some View {
        Label(text, systemImage: level == "error" ? "xmark.octagon" : level == "warning" ? "exclamationmark.triangle" : "info.circle")
            .font(.system(size: 12)).foregroundStyle(level == "info" ? SiftStyle.secondary : Color.orange.opacity(0.9))
            .lineLimit(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
