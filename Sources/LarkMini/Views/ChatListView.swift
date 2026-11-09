import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Sift", subtitle: store.offline ? "Offline · showing saved chats" : liveStatus) {
                shortcuts
                if store.loadingChats {
                    ProgressView().controlSize(.small).frame(width: 32)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Refresh chats") {
                        store.errorText = nil
                        Task { await store.loadChats(reset: true) }
                    }
                }
            }
            HStack(spacing: 20) {
                tab("Inbox", all: false)
                tab("All chats", all: true)
                Spacer(minLength: 0)
                if !store.showAllChats && store.unreadCount > 0 {
                    Text("\(store.unreadCount) unread").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(SiftStyle.green)
                }
            }
            .padding(.horizontal, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(SiftStyle.line).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if store.visibleChats.isEmpty {
                            if store.loadingChats {
                                PaneEmptyState(symbol: "arrow.triangle.2.circlepath", title: "Loading your chats", detail: "Your conversations will appear here.")
                            } else if store.errorText != nil || store.offline {
                                PaneEmptyState(symbol: "wifi.slash", title: "Chats are unavailable", detail: "Refresh to try again. Saved conversations are still in All chats.")
                            } else {
                                PaneEmptyState(symbol: store.showAllChats ? "bubble.left.and.bubble.right" : "checkmark",
                                    title: store.showAllChats ? "No chats loaded" : "Nothing needs you",
                                    detail: store.showAllChats ? "Refresh your chats or find a conversation with ⌘K." : "No new messages in your tracked chats. Your history is in All chats.")
                                if !store.showAllChats {
                                    Button("Browse all chats") { store.showAllChats = true }
                                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
                                }
                            }
                        } else {
                            HStack {
                                Text(store.showAllChats ? "Recent conversations" : "New messages")
                                Spacer()
                                if store.showAllChats { Text("\(store.visibleChats.count) loaded") }
                            }
                            .font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
                            ForEach(Array(store.visibleChats.enumerated()), id: \.element.id) { index, chat in
                                ChatRow(chat: chat, selected: index == store.listSelection)
                                    .id(chat.id)
                                    .task(id: chat.id) { await store.ensurePreview(chat.id) }
                            }
                        }
                        if store.showAllChats {
                            if store.canLoadMoreChats {
                                Button(store.loadingChats ? "Loading more chats…" : "Load more chats") {
                                    Task { await store.loadNextChatPage() }
                                }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                                    .padding(12).disabled(store.loadingChats)
                            }
                            Text("Loaded chats only · previews checked in small batches")
                                .font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                                .padding(.horizontal, 8).padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 16)
                }
                .onChange(of: store.listSelection) {
                    if let chat = store.selectedInboxChat() { proxy.scrollTo(chat.id) }
                }
            }
            .onChange(of: store.showAllChats) { store.listSelection = 0 }
            .onChange(of: store.visibleChats.map(\.id)) {
                store.listSelection = min(store.listSelection, max(0, store.visibleChats.count - 1))
            }
            if let error = store.errorText { ErrorBar(text: error) }
        }
        .onDisappear { store.showingShortcuts = false }
    }

    private func tab(_ title: String, all: Bool) -> some View {
        Button { store.showAllChats = all } label: {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(store.showAllChats == all ? Color.white : SiftStyle.secondary)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(store.showAllChats == all ? Color.white : .clear).frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(store.showAllChats == all ? .isSelected : [])
    }

    /// What needs you right now, instead of a slogan.
    private var liveStatus: String {
        let needs = store.seats.reduce(0) { $0 + $1.openNeedCount }
        var parts: [String] = []
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if store.unreadCount > 0 { parts.append("\(store.unreadCount) unread") }
        return parts.isEmpty ? "Nothing needs you" : parts.joined(separator: " · ")
    }

    private var shortcuts: some View {
        IconButton(symbol: "keyboard", help: "Keyboard shortcuts") { store.showingShortcuts.toggle() }
            .popover(isPresented: $store.showingShortcuts) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("At your fingertips").font(.system(size: 14, weight: .semibold))
                    ShortcutHint(keys: "⌃⌥ V", label: "talk to Sift (tap, or hold)")
                    ShortcutHint(keys: "⌥ Space", label: "open or collapse Sift")
                    ShortcutHint(keys: "⌘ K", label: "find a chat")
                    ShortcutHint(keys: "⌘ 0", label: "Inbox")
                    ShortcutHint(keys: "⌘ 1–9", label: "pinned chats")
                    ShortcutHint(keys: "J K / ↑ ↓", label: "move through chats")
                    ShortcutHint(keys: "E", label: "mark selected chat read")
                    ShortcutHint(keys: "⌘ ,", label: "settings")
                    ShortcutHint(keys: "Esc", label: "back, then collapse")
                }.padding(20)
                    .foregroundStyle(.white)
                    .background(SiftStyle.surface)
                    .preferredColorScheme(.dark)
            }
    }
}

struct ChatRow: View {
    @EnvironmentObject var store: Store
    let chat: Chat
    var selected = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button { store.open(chat) } label: {
                HStack(alignment: .top, spacing: 10) {
                    AvatarView(chat: chat, size: 40).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(chat.displayName).font(.system(size: 13, weight: store.isUnread(chat) ? .semibold : .medium)).lineLimit(1)
                                .help(chat.name)
                            ForEach(chat.tags, id: \.self) { TagBadge(text: $0) }
                            Spacer(minLength: 0)
                            if let preview = store.previews[chat.id] {
                                Text(TimeFormat.short(preview.ts)).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(SiftStyle.muted).fixedSize()
                            }
                        }
                        if store.settings.showPreviewText {
                            Text(store.previews[chat.id]?.text ?? "Preview unavailable")
                                .font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                                .lineLimit(2).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if store.isUnread(chat) {
                Button { store.markRead(chat) } label: {
                    Image(systemName: hovered || selected ? "checkmark.circle" : "circle.fill")
                        .font(.system(size: hovered || selected ? 15 : 6))
                        .foregroundStyle(SiftStyle.green)
                        .frame(width: 26, height: 36)
                }
                .buttonStyle(.plain).help("Unread · click to mark read").accessibilityLabel("Mark \(chat.displayName) read")
                .padding(.trailing, 4)
            }
        }
        .background(selected ? SiftStyle.raised : hovered ? Color.white.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .onHover { hovered = $0 }
        .contextMenu {
            Button(store.pinned.contains(chat.id) ? "Unpin" : "Pin") { store.togglePin(chat) }
                .disabled(!store.canPin(chat))
            if store.isUnread(chat) { Button("Mark read") { store.markRead(chat) } }
            if store.isMuted(chat) { Button("Unmute") { store.unmute(chat) } }
            else { Button("Mute for 1 hour") { store.mute(chat) } }
            if let link = chat.link { Button("Open in Lark") { NSWorkspace.shared.open(link) } }
        }
    }
}
