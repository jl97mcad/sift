import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        ZStack {
            if store.isExpanded {
                ExpandedView()
                    .transition(.opacity)
            } else {
                CollapsedBubble()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if store.isExpanded, !store.searchOpen, !store.toasts.isEmpty {
                ToastStack()
            }
        }
        .overlay {
            if store.searchOpen && store.isExpanded {
                ChatPickerView()
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.searchOpen)
        .modifier(ChromeIfExpanded(expanded: store.isExpanded))
        .environment(\.siftReduceMotion, reduceMotion)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .environment(\.colorScheme, .dark)
        .environment(\.larkAccent, store.accentColor)
        .tint(store.accentColor)
        .onChange(of: store.settings.panelWidth) {
            NotificationCenter.default.post(name: .panelSettingsChanged, object: nil)
        }
    }
}

struct CollapsedBubble: View {
    @EnvironmentObject var store: Store
    @Environment(\.siftReduceMotion) private var reduceMotion
    @ObservedObject private var gaze = GazeTracker.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            FaceIcon(size: 36)
                .background {
                    if store.needsYouUnseen { AttentionPulse(size: 44) }
                }
                .background(
                    Circle()
                        .fill(
                            RadialGradient(stops: [
                                .init(color: Color(red: 0.52, green: 0.80, blue: 0.47).opacity(0.62), location: 0.00),
                                .init(color: Color(red: 0.55, green: 0.82, blue: 0.50).opacity(0.50), location: 0.60),
                                .init(color: Color(red: 0.62, green: 0.86, blue: 0.56).opacity(0.22), location: 0.80),
                                .init(color: Color(red: 0.66, green: 0.88, blue: 0.60).opacity(0.06), location: 0.93),
                                .init(color: Color(red: 0.70, green: 0.90, blue: 0.63).opacity(0.00), location: 1.00)
                            ], center: .center, startRadius: 0, endRadius: 30)
                        )
                        .frame(width: 60, height: 60)
                        .opacity(gaze.proximity)
                )
                .overlay(alignment: .topTrailing) {
                    if store.needsYouUnseen {
                        EmptyView()
                    } else if store.controlAttention != nil {
                        UnreadDot(size: 7)
                            .padding(2).background(SiftStyle.rail, in: Circle())
                            .offset(x: 2, y: -2)
                    } else if store.unreadCount > 0 {
                        Text(store.unreadCount > 9 ? "9+" : "\(store.unreadCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.23)))
                            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 1))
                            .offset(x: 4, y: -4)
                    }
                }
                .padding(.trailing, 16)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.05 * gaze.proximity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .help(store.attentionSummary.map { $0 + " · Click to open" } ?? "Open Sift (⌥Space)")
        .accessibilityLabel("Open Sift, \(store.unreadCount) unread chats" + (store.attentionSummary.map { ", " + $0 } ?? ""))
    }
}

private struct ChromeIfExpanded: ViewModifier {
    let expanded: Bool
    func body(content: Content) -> some View {
        if expanded {
            content.panelChrome()
        } else {
            content
        }
    }
}

struct ExpandedView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if isSignedIn || !store.seats.isEmpty {
                ShellView()
            } else if store.showingSettings {
                SettingsView()
            } else {
                SignInView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isSignedIn: Bool {
        if case .signedIn = store.auth { return true }
        return false
    }
}

extension Notification.Name {
    static let panelDragEnded = Notification.Name("Sift.panelDragEnded")
    static let panelSettingsChanged = Notification.Name("Sift.panelSettingsChanged")
    static let expandPanel = Notification.Name("Sift.expandPanel")
    static let collapsePanel = Notification.Name("Sift.collapsePanel")
}
