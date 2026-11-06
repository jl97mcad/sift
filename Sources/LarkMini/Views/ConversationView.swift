import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConversationView: View {
    @Environment(\.larkAccent) private var accent
    @EnvironmentObject var store: Store
    @Environment(\.siftReduceMotion) private var reduceMotion
    let chat: Chat
    @State private var importing = false
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            messageScroll
            Divider().opacity(0.2)
            composer
            if let error = store.errorText {
                ErrorBar(text: error)
            }
        }
        .task {
            if store.focusComposer {
                store.focusComposer = false
                try? await Task.sleep(nanoseconds: 150_000_000)
                composing = true
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            let target = chat.id
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        Task { await store.sendAttachment(url, to: target) }
                    }
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(chat: chat, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.displayName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(chat.isP2P ? "Lark · Direct message" : "Lark · Group conversation")
                    .font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
            }
            .panelDragHandle().help("Drag to move Sift")
            Spacer(minLength: 0)
            if let link = chat.link {
                IconButton(symbol: "arrow.up.forward.app", help: "Open in Lark") {
                    NSWorkspace.shared.open(link)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: 76)
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.canLoadOlder {
                        Button {
                            Task { await store.loadOlder() }
                        } label: {
                            if store.loadingOlder {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("Earlier messages").font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    }
                    if store.messages[chat.id] == nil {
                        PaneEmptyState(symbol: store.errorText == nil ? "bubble.left" : "exclamationmark.bubble",
                            title: store.errorText == nil ? "Loading conversation" : "Conversation unavailable",
                            detail: store.errorText == nil ? "Fetching messages from Lark." : "Open the chat again to retry.")
                    } else if store.messages[chat.id]?.isEmpty == true {
                        PaneEmptyState(symbol: "bubble.left", title: "Start a conversation", detail: "Your messages will appear here.")
                    }
                    ForEach(Array((store.messages[chat.id] ?? []).enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? store.messages[chat.id]?[index - 1] : nil
                        let list = store.messages[chat.id] ?? []
                        let next = index + 1 < list.count ? list[index + 1] : nil
                        if isNewDay(previous, message) {
                            Text(TimeFormat.day(message.ts))
                                .font(.system(size: 11))
                                .foregroundStyle(SiftStyle.muted)
                                .padding(.vertical, 6)
                        }
                        MessageBubble(message: message, isGroup: !chat.isP2P,
                                      senderName: store.memberNames[message.sender.id] ?? "",
                                      showSender: !message.groups(with: previous),
                                      showTimestamp: !message.groups(with: next))
                            .padding(.top, message.groups(with: previous) ? 4 : 10)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            // Open at the newest message; a fresh identity per chat keeps a switch from
            // animating through another chat's history.
            .defaultScrollAnchor(.bottom)
            .id(chat.id)
            .onChange(of: (store.messages[chat.id] ?? []).last?.id) { old, _ in
                guard old != nil else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                IconButton(symbol: "paperclip", help: "Attach a file") { importing = true }
                TextField("Message", text: Binding(
                    get: { store.draft(for: chat.id) },
                    set: { store.setDraft($0, for: chat.id) }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(2...5)
                    .frame(minHeight: 44, alignment: .topLeading)
                    .focused($composing)
                    .accessibilityLabel("Message \(chat.displayName)")
                    .onSubmit {
                        if canSend { Task { await store.send() } }
                    }
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: store.sending ? "clock" : "arrow.up")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                        .foregroundStyle(canSend ? Color.black : SiftStyle.muted)
                        .background(canSend ? Color.white : Color.white.opacity(0.05), in: Circle())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send message (⌘Return)").accessibilityLabel("Send message")
            }
            .composerSurface().padding(.bottom, 12)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                let target = chat.id
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    await store.sendAttachment(url, to: target)
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    private func isNewDay(_ previous: ChatMessage?, _ message: ChatMessage) -> Bool {
        guard let previous else { return false }
        let before = Date(timeIntervalSince1970: TimeInterval(previous.ts) / 1000)
        let current = Date(timeIntervalSince1970: TimeInterval(message.ts) / 1000)
        return !Calendar.current.isDate(before, inSameDayAs: current)
    }

    private var canSend: Bool {
        !store.draft(for: chat.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.sending
    }
}

struct MessageBubble: View {
    @Environment(\.larkAccent) private var accent
    let message: ChatMessage
    let isGroup: Bool
    var senderName: String = ""
    var showSender = true
    var showTimestamp = true

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 44) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                if showSender, isGroup, !message.isMine, message.type != "system", !senderName.isEmpty {
                    Text(senderName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                content
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(message.isMine ? accent.opacity(0.16) : SiftStyle.raised)
                    )
                if showTimestamp || message.deleted {
                    HStack(spacing: 4) {
                        if message.deleted {
                            Text("deleted").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                        }
                        if showTimestamp { Text(TimeFormat.clock(message.ts)).font(.system(size: 11)).foregroundStyle(SiftStyle.muted) }
                    }
                }
            }
            if !message.isMine { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let imageKey = message.imageKey {
            ResourceImage(messageId: message.id, fileKey: imageKey)
        } else if message.fileKey != nil {
            ResourceFile(message: message)
        } else {
            Text(LinkedText.attributed(message.text))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ResourceImage: View {
    @EnvironmentObject var store: Store
    let messageId: String
    let fileKey: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: failed ? "photo" : "photo.badge.arrow.down")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 150, height: 100)
            }
        }
        .task(id: messageId) {
            guard image == nil else { return }
            if let data = try? await store.api.imageData(messageId: messageId, key: fileKey) {
                image = NSImage(data: data)
            } else {
                failed = true
            }
        }
    }
}

struct ResourceFile: View {
    @EnvironmentObject var store: Store
    let message: ChatMessage
    @State private var download: Task<Void, Never>?
    @State private var failure: String?
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message.fileName ?? "File", systemImage: "doc")
                .font(.system(size: 13)).lineLimit(2)
            if download != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.system(size: 12))
                    Button("Cancel") { download?.cancel() }.buttonStyle(.plain)
                }
            } else if let saved {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SiftStyle.green)
            } else {
                Button(failure == nil ? "Save file…" : "Retry download…", action: chooseDestination)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SiftStyle.green)
            }
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary) }
        }
        .onDisappear { download?.cancel() }
    }

    private func chooseDestination() {
        guard download == nil else { return }
        let chooser = NSSavePanel()
        chooser.nameFieldStringValue = URL(fileURLWithPath: message.fileName ?? "File").lastPathComponent
        chooser.canCreateDirectories = true
        guard chooser.runModal() == .OK, let destination = chooser.url else { return }
        failure = nil
        download = Task { @MainActor in
            defer { download = nil }
            do {
                try await store.saveFile(message, to: destination)
                saved = destination
            } catch is CancellationError { failure = "Download cancelled. You can retry." }
            catch {
                failure = Task.isCancelled ? "Download cancelled. You can retry." : error.localizedDescription
            }
        }
    }
}
