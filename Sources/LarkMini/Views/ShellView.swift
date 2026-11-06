import SwiftUI

/// The expanded panel: a rail that never moves, and one content pane.
struct ShellView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            RailView()
            Rectangle().fill(SiftStyle.line).frame(width: 1)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.showingSettings {
            SettingsView()
        } else if store.controlOpen, let seat = store.seat {
            ControlChatView(seat: seat)
        } else if let chat = store.openChat {
            ConversationView(chat: chat)
        } else if store.auth != .signedIn {
            SignInView()
        } else {
            ChatListView()
        }
    }
}
