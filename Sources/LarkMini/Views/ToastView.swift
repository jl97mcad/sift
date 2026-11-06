import SwiftUI

struct ToastCard: View {
    @EnvironmentObject var store: Store
    @Environment(\.siftReduceMotion) private var reduceMotion
    let toast: ChatToast

    var body: some View {
        Button {
            store.focusComposer = true
            store.open(toast.chat)
            store.dismissToast(toast)
        } label: {
            HStack(spacing: 8) {
                AvatarView(chat: toast.chat, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.chat.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(toast.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: 230, alignment: .leading)
            .background(
                ZStack {
                    BlurView(material: .popover)
                    Color.black.opacity(0.45)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
    }
}

struct ToastStack: View {
    @EnvironmentObject var store: Store
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(store.toasts) { toast in
                ToastCard(toast: toast)
            }
        }
        .padding(8)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: store.toasts)
    }
}
