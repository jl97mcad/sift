import SwiftUI

/// The rail stays in place while the content changes.
struct RailView: View {
    @EnvironmentObject var store: Store
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 8) {
            // Agents first, Lark second.
            if !store.seats.isEmpty {
                VStack(spacing: 6) {
                    ForEach(store.seats) { seat in
                        SeatRailItem(seat: seat, selected: store.controlOpen && store.seat?.id == seat.id && !store.showingSettings,
                                     dropTarget: $dropTarget)
                    }
                }
                .padding(.top, 10)
            }

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
            .padding(.top, store.seats.isEmpty ? 10 : 0)

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
        RailSelection(selected: selected)
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
                guard let id = value as? String, !id.hasPrefix("seat:") else { return }
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

struct RailSelection: View {
    let selected: Bool
    var body: some View { RoundedRectangle(cornerRadius: 12).fill(selected ? SiftStyle.raised : .clear) }
}

/// One agent in the rail: its own face, a pulse for an unseen need, a dot for a new reply.
struct SeatRailItem: View {
    @EnvironmentObject var store: Store
    @ObservedObject var seat: SeatSession
    let selected: Bool
    @Binding var dropTarget: String?

    var body: some View {
        Button { store.openSeat(seat) } label: {
            VStack(spacing: 4) {
                FaceIcon(size: 30, palette: seat.palette)
                    .background {
                        if seat.needsYouUnseen { AttentionPulse(size: 36) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if seat.attention != nil && !seat.needsYouUnseen { UnreadDot(size: 6).offset(x: 3, y: -2) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if seat.activity != nil {
                            Circle().fill(SiftStyle.green).frame(width: 6, height: 6)
                                .padding(1).background(SiftStyle.rail, in: Circle()).offset(x: 2, y: 2)
                        }
                    }
                Text(seat.label).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(maxWidth: 52)
            }
            .frame(width: 48, height: 54)
            .background(RailSelection(selected: selected || dropTarget == seat.id))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(seat.attentionSummary.map { seat.config.title + " · " + $0 } ?? seat.config.title)
        .accessibilityLabel(seat.attentionSummary.map { seat.label + ", " + $0 } ?? seat.label)
        .onDrag { NSItemProvider(object: ("seat:" + seat.id) as NSString) }
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTarget == seat.id }, set: { dropTarget = $0 ? seat.id : nil }
        )) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let id = value as? String, id.hasPrefix("seat:") else { return }
                DispatchQueue.main.async { store.moveSeat(from: String(id.dropFirst(5)), to: seat.id) }
            }
            return true
        }
        .contextMenu {
            Button("Open in Paseo") { seat.openInPaseo() }
            Button("Remove") { store.removeSeat(seat) }
        }
    }
}
