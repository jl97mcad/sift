import SwiftUI
import AppKit

enum SiftStyle {
    static let surface = Color(white: 0.085)
    static let rail = Color(white: 0.055)
    static let raised = Color(white: 0.15)
    static let line = Color.white.opacity(0.09)
    static let secondary = Color(white: 0.70)
    static let muted = Color(white: 0.58)
    static let green = Color(red: 0.71, green: 0.86, blue: 0.62)
}

private struct ReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue: Color = .blue
}

extension EnvironmentValues {
    // NSHostingView does not refresh SwiftUI's read-only accessibility value on this host.
    var siftReduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }

    var larkAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

struct BlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct AvatarView: View {
    @Environment(\.larkAccent) private var accent
    let chat: Chat
    var size: CGFloat = 30

    var body: some View {
        Group {
            // Lark's shared default image makes groups indistinguishable; initials do not.
            if let url = chat.avatar, !url.path.contains("default-avatar") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            SiftStyle.raised
            Text(chat.initials)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

struct UnreadDot: View {
    @Environment(\.larkAccent) private var accent
    var size: CGFloat = 7
    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: size, height: size)
    }
}

/// Only an unseen request for the owner pulses; ordinary unread replies keep a small dot.
/// Three soft beats when it appears, then a still ring: no animation at rest.
struct AttentionPulse: View {
    @Environment(\.siftReduceMotion) private var reduceMotion
    var size: CGFloat
    @State private var beats = 0

    private var ring: some View {
        Circle().strokeBorder(SiftStyle.green, lineWidth: 1.5).frame(width: size, height: size)
    }

    var body: some View {
        Group {
            if reduceMotion { ring.opacity(0.65) }
            else {
                ring.phaseAnimator([false, true], trigger: beats) { content, phase in
                    content.scaleEffect(phase ? 1.16 : 1).opacity(phase ? 0.18 : 0.65)
                } animation: { _ in .easeInOut(duration: 0.7) }
            }
        }
        .task {
            guard !reduceMotion else { return }
            for _ in 0..<3 {
                beats += 1
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(SiftStyle.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ErrorBar: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color(red: 1, green: 0.66, blue: 0.60))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.12))
    }
}

extension View {
    func panelChrome(corner: CGFloat = 20) -> some View {
        self
            .background(SiftStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
            )
    }
}

enum BrandIcon {
    static func statusBar() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.71, green: 0.90, blue: 0.68, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: 17, height: 17)).fill()
        NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.92, alpha: 1).setFill()
        for x in [5.6, 10.0] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 6.4, width: 2.4, height: 4.2),
                         xRadius: 1.1, yRadius: 1.1).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

/// An agent mark, shared by the rail and conversation heading.
struct ControlMark: View {
    var size: CGFloat = 28
    var running: Bool = false

    var body: some View {
        Image(systemName: "command")
            .font(.system(size: size * 0.58, weight: .medium))
            .foregroundStyle(SiftStyle.green)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if running {
                    Circle().fill(SiftStyle.green).frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
    }
}

struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary).lineLimit(1)
            }
            .panelDragHandle()
            .help("Drag to move Sift")
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
    }
}

struct PaneEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(SiftStyle.green)
                .padding(.bottom, 6)
            Text(title).font(.system(size: 17, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(SiftStyle.secondary).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .padding(.top, 24)
    }
}

struct ShortcutHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Text(keys).foregroundStyle(SiftStyle.secondary)
            Text(label).foregroundStyle(SiftStyle.muted)
        }
        .font(.system(size: 11))
    }
}

extension View {
    func composerSurface() -> some View {
        padding(10)
            .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SiftStyle.line))
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }
}
