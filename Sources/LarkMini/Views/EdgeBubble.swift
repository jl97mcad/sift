import AppKit
import Combine
import SwiftUI

/// A soft thought bubble beside the collapsed head: a new Lark arrival or a genuine Control need.
struct EdgeBubble: Equatable, Identifiable {
    enum Target: Equatable { case chat(String), inbox, control }

    var id = UUID()
    var target: Target
    var title: String
    var text: String
    var names: [String] = []
    var count = 1

    /// A burst of arrivals coalesces into one bubble; a Control need is never covered by chatter.
    static func arrival(_ current: EdgeBubble?, chatId: String, name: String, text: String) -> EdgeBubble {
        guard let current, current.target != .control else {
            return current ?? EdgeBubble(target: .chat(chatId), title: name, text: text, names: [name])
        }
        let names = current.names.contains(name) ? current.names : current.names + [name]
        let count = current.count + 1
        let others = names.count > 2 ? " +\(names.count - 2)" : ""
        return EdgeBubble(id: current.id, target: names.count == 1 ? .chat(chatId) : .inbox,
                          title: names.count == 1 ? "\(name) · \(count) new"
                              : "\(count) new · " + names.prefix(2).joined(separator: ", ") + others,
                          text: text, names: names, count: count)
    }
}

/// Sift's own chat-bird mark, drawn in white: a speech bubble with a wing.
struct ChatBirdMark: View {
    var size: CGFloat = 26

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 24
            var bird = Path()
            bird.addEllipse(in: CGRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 14 * s))
            bird.move(to: CGPoint(x: 7 * s, y: 15 * s))
            bird.addLine(to: CGPoint(x: 5 * s, y: 21 * s))
            bird.addLine(to: CGPoint(x: 11.5 * s, y: 16.8 * s))
            bird.closeSubpath()
            context.fill(bird, with: .color(.white))
            var wing = Path()
            wing.move(to: CGPoint(x: 8 * s, y: 12 * s))
            wing.addQuadCurve(to: CGPoint(x: 16.5 * s, y: 8.5 * s), control: CGPoint(x: 11 * s, y: 14.5 * s))
            context.stroke(wing, with: .color(ChatBirdMark.tint), style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 16.6 * s, y: 7.4 * s, width: 1.6 * s, height: 1.6 * s)), with: .color(ChatBirdMark.tint))
        }
        .frame(width: size * 0.62, height: size * 0.62)
        .frame(width: size, height: size)
        .background(ChatBirdMark.tint, in: Circle())
        .accessibilityHidden(true)
    }

    static let tint = Color(red: 0.20, green: 0.44, blue: 0.98)
}

/// A rounded cloud with a few soft bumps, merged into one outline; static, so it costs nothing at rest.
struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var cloud = Path(roundedRect: rect.insetBy(dx: 0, dy: 7), cornerRadius: 22, style: .continuous)
        for (x, d) in [(0.24, 30.0), (0.5, 36.0), (0.74, 28.0)] {
            cloud = cloud.union(Path(ellipseIn: CGRect(x: rect.minX + rect.width * x - d / 2, y: rect.minY, width: d, height: d)))
        }
        for (x, d) in [(0.36, 24.0), (0.62, 22.0)] {
            cloud = cloud.union(Path(ellipseIn: CGRect(x: rect.minX + rect.width * x - d / 2, y: rect.maxY - d, width: d, height: d)))
        }
        return cloud
    }
}

struct EdgeBubbleView: View {
    let bubble: EdgeBubble
    @EnvironmentObject var store: Store
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            HStack(spacing: 10) {
                if bubble.target == .control {
                    ControlMark(size: 26).background(SiftStyle.raised, in: Circle())
                } else {
                    ChatBirdMark(size: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(bubble.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(bubble.text).font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                        .lineLimit(hovering ? 3 : 1).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 190, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(CloudShape().fill(SiftStyle.surface.opacity(0.97)))
            .overlay(CloudShape().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            // Trailing thought dots toward the head.
            VStack(spacing: 3) {
                Circle().fill(SiftStyle.surface.opacity(0.97)).frame(width: 8, height: 8)
                Circle().fill(SiftStyle.surface.opacity(0.97)).frame(width: 5, height: 5).offset(x: 5)
            }
            .padding(.bottom, 2)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            store.holdBubble(inside)
        }
        .onTapGesture { store.openBubble() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens it in Sift")
    }
}

/// One spring on arrival, then still; Reduce Motion fades only.
struct EdgeBubbleHost: View {
    @EnvironmentObject var store: Store
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            if let bubble = store.bubble {
                EdgeBubbleView(bubble: bubble)
                    .id(bubble.id)
                    .transition(reduceMotion ? .opacity
                        : .scale(scale: 0.55, anchor: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.62),
                   value: store.bubble?.id)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

/// A transparent window beside the collapsed head that never takes focus.
@MainActor
final class EdgeBubbleController {
    private let store: Store
    private let panel: NSPanel
    private var watch: AnyCancellable?
    private static let size = NSSize(width: 300, height: 130)

    init(store: Store) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: EdgeBubbleHost().environmentObject(store))
        host.sizingOptions = []
        panel.contentView = host
        watch = store.$bubble.combineLatest(store.$isExpanded)
            .receive(on: RunLoop.main)
            .sink { [weak self] bubble, expanded in
                MainActor.assumeIsolated { self?.update(visible: bubble != nil && !expanded) }
            }
    }

    private func update(visible: Bool) {
        guard visible else {
            // Let the fade finish, then drop the window so a resting edge costs nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.store.bubble == nil || self.store.isExpanded else { return }
                self.panel.orderOut(nil)
            }
            return
        }
        guard let head = PanelBridge.shared.panel?.frame,
              let screen = (PanelBridge.shared.panel?.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = NSRect(origin: NSPoint(x: head.minX - Self.size.width + 6, y: head.midY - 34), size: Self.size)
        frame.origin.y = min(max(frame.minY, screen.minY + 8), screen.maxY - Self.size.height - 8)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }
}
