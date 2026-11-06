import SwiftUI

/// The rail stays in place while the content changes.
struct RailView: View {
    @EnvironmentObject var store: Store
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 8) {
            Button { store.showInbox() } label: {
                VStack(spacing: 4) {
                    FaceIcon(size: 32)
                    Text("Inbox").font(.system(size: 11, weight: .medium))
                }
                .frame(width: 48, height: 58)
                .background(selection(store.openChat == nil && !store.controlOpen && !store.showingSettings))
            }
            .buttonStyle(.plain)
            .help("Inbox (⌘0)")
            .accessibilityLabel("Sift Inbox")
            .padding(.top, 10)

            if store.controlSeat != nil {
                Button { store.openControl() } label: {
                    VStack(spacing: 4) {
                        ControlMark(size: 28, running: store.controlActivity != nil)
                            .background {
                                if store.needsYouUnseen { AttentionPulse(size: 34) }
                            }
                            .overlay(alignment: .topTrailing) {
                                if store.controlAttention != nil && !store.needsYouUnseen { UnreadDot(size: 6).offset(x: 3, y: -2) }
                            }
                        Text("Control").font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 48, height: 54)
                    .background(selection(store.controlOpen && !store.showingSettings))
                }
                .buttonStyle(.plain)
                .help(store.attentionSummary.map { "Control · " + $0 } ?? "Control agent conversation")
                .accessibilityLabel(store.attentionSummary.map { "Control, " + $0 } ?? "Control agent conversation")
            }

            Rectangle().fill(SiftStyle.line).frame(width: 28, height: 1)
                .padding(.vertical, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(store.pinnedChats.enumerated()), id: \.element.id) { index, chat in
                        railItem(chat, index: index)
                    }
                    IconButton(symbol: "plus", help: "Find and pin a chat") { store.openSearch() }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 4) {
                IconButton(symbol: "magnifyingglass", help: "Find a chat (⌘K)") { store.openSearch() }
                IconButton(symbol: "gearshape", help: "Settings (⌘,)") { store.showingSettings = true }
                    .background(selection(store.showingSettings))
                IconButton(symbol: "chevron.right", help: "Collapse Sift (Esc)") {
                    NotificationCenter.default.post(name: .collapsePanel, object: nil)
                }
            }
            .padding(.bottom, 10)
        }
        .frame(width: 60)
        .background(SiftStyle.rail)
    }

    private func selection(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12).fill(selected ? SiftStyle.raised : .clear)
    }

    private func railItem(_ chat: Chat, index: Int) -> some View {
        Button { store.open(chat) } label: {
            AvatarView(chat: chat, size: 32)
                .overlay(alignment: .bottomTrailing) {
                    if store.isUnread(chat) {
                        UnreadDot(size: 7)
                            .padding(2).background(SiftStyle.rail, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
                .frame(width: 48, height: 44)
                .background(selection((store.openChat?.id == chat.id && !store.showingSettings) || dropTarget == chat.id))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chat.displayName + (index < 9 ? " (⌘\(index + 1))" : ""))
        .accessibilityLabel(chat.displayName + (store.isUnread(chat) ? ", unread" : ""))
        .onDrag { NSItemProvider(object: chat.id as NSString) }
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTarget == chat.id }, set: { dropTarget = $0 ? chat.id : nil }
        )) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let id = value as? String else { return }
                DispatchQueue.main.async { store.movePin(from: id, to: chat.id) }
            }
            return true
        }
        .contextMenu {
            Button("Unpin") { store.togglePin(chat) }
            if store.isMuted(chat) {
                Button("Unmute") { store.unmute(chat) }
            } else {
                Button("Mute for 1 hour") { store.mute(chat) }
            }
        }
    }
}
