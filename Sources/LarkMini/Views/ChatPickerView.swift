import SwiftUI

struct ChatPickerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.larkAccent) private var accent
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            card
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchRow
            Divider().opacity(0.2)
            results
            Divider().opacity(0.2)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: 420)
        .background(
            ZStack {
                SiftStyle.surface
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .padding(10)
        .task(id: store.search) {
            guard store.search.count >= 2 else {
                store.remoteResults = []
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await store.searchAll()
        }
        .onAppear { focused = true }
        .onChange(of: store.search) { store.searchSelection = 0 }
    }

    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search people and groups", text: $store.search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if store.searching {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            } else if !store.search.isEmpty {
                Button {
                    store.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SiftStyle.muted)
                }
                .buttonStyle(.plain)
            }
            Button {
                store.closeSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.pinnedMatches.isEmpty && store.chatMatches.isEmpty && store.remoteOnly.isEmpty {
                        emptyState
                    }
                    if !store.pinnedMatches.isEmpty {
                        sectionLabel("Pinned")
                        rows(store.pinnedMatches)
                    }
                    if !store.chatMatches.isEmpty {
                        sectionLabel("Your chats")
                        rows(store.chatMatches)
                    }
                    if !store.remoteOnly.isEmpty {
                        sectionLabel("From Lark")
                        rows(store.remoteOnly)
                    }
                    if store.search.isEmpty {
                        Text("Pin a chat to keep it in the left rail.")
                            .font(.system(size: 11))
                            .foregroundStyle(SiftStyle.muted)
                            .padding(.top, 10)
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: store.searchSelection) {
                if store.searchResults.indices.contains(store.searchSelection) {
                    proxy.scrollTo(store.searchResults[store.searchSelection].id)
                }
            }
        }
    }

    private func rows(_ chats: [Chat]) -> some View {
        ForEach(chats) { chat in
            row(chat).id(chat.id)
            Divider().opacity(0.1).padding(.leading, 48)
        }
    }

    private func isSelected(_ chat: Chat) -> Bool {
        store.searchResults.firstIndex { $0.id == chat.id } == store.searchSelection
    }

    private func row(_ chat: Chat) -> some View {
        HStack(spacing: 8) {
            Button {
                store.closeSearch()
                store.open(chat)
            } label: {
                HStack(spacing: 9) {
                    AvatarView(chat: chat, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(chat.isP2P ? "Direct message" : (chat.isTopic ? "Topic group" : "Group"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.togglePin(chat)
            } label: {
                Image(systemName: store.pinned.contains(chat.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(store.pinned.contains(chat.id) ? accent : Color.secondary.opacity(0.6))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(store.pinned.contains(chat.id) ? "Unpin" : "Pin")
            .accessibilityLabel(store.pinned.contains(chat.id) ? "Unpin \(chat.displayName)" : "Pin \(chat.displayName)")
            .disabled(!store.canPin(chat))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(isSelected(chat) ? Color.white.opacity(0.07) : Color.clear)
        .onHover { hovering in
            if hovering, let index = store.searchResults.firstIndex(where: { $0.id == chat.id }) {
                store.searchSelection = index
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text(store.searching ? "Searching…" : (store.search.isEmpty ? "Type a name" : "No chats match"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if store.search.count >= 2 && !store.searching {
                Text("Lark's search covers groups. Direct chats appear once they are in your loaded list.")
                    .font(.system(size: 11))
                    .foregroundStyle(SiftStyle.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 28)
        .padding(.horizontal, 18)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SiftStyle.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private var footer: some View {
        HStack {
            Text("\(store.pinned.count) of 10 pinned")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Esc to close")
                .font(.system(size: 11))
                .foregroundStyle(SiftStyle.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }
}
