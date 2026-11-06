import SwiftUI
import AppKit

/// Watches the pointer so the face's eyes can follow it. Driven by pointer-move events,
/// not a timer: a resting pointer, an expanded panel or Reduce Motion costs no wakeups.
@MainActor
final class GazeTracker: ObservableObject {
    static let shared = GazeTracker()
    @Published private(set) var offset: CGSize = .zero
    @Published private(set) var proximity: Double = 0
    var active = true

    private var monitors: [Any] = []
    private var lastUpdate = Date.distantPast

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
            MainActor.assumeIsolated { GazeTracker.shared.update() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            MainActor.assumeIsolated { GazeTracker.shared.update() }
            return event
        }) { monitors.append(local) }
    }

    private func update() {
        // At most 30 updates a second while the pointer moves.
        guard active, Date().timeIntervalSince(lastUpdate) > 0.033,
              let frame = PanelBridge.shared.panel?.frame else { return }
        lastUpdate = Date()
        let mouse = NSEvent.mouseLocation
        let look = Self.look(dx: mouse.x - frame.midX, dy: mouse.y - frame.midY)
        if abs(look.proximity - proximity) > 0.02 { proximity = look.proximity }
        let target = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .zero : look.offset
        if abs(target.width - offset.width) > 0.06 || abs(target.height - offset.height) > 0.06 {
            offset = target
        }
    }

    /// Eye offset toward the pointer (screen coordinates, y up) and hover closeness 0...1.
    nonisolated static func look(dx: CGFloat, dy: CGFloat) -> (offset: CGSize, proximity: Double) {
        let distance = max(1, (dx * dx + dy * dy).squareRoot())
        let reach: CGFloat = 2.8
        let strength = min(1, distance / 180)
        return (CGSize(width: dx / distance * reach * strength, height: -dy / distance * reach * strength),
                max(0, min(1, 1 - Double(distance - 22) / 68)))
    }
}

struct FaceIcon: View {
    @ObservedObject private var gaze = GazeTracker.shared
    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var blinking = false
    @State private var blinkTask: Task<Void, Never>?
    var size: CGFloat = 36

    static let faceTop = Color(red: 0.639, green: 0.847, blue: 0.529)
    static let faceBottom = Color(red: 0.520, green: 0.780, blue: 0.480)
    static let rim = Color(red: 0.243, green: 0.475, blue: 0.239)
    static let eye = Color(red: 1.0, green: 0.976, blue: 0.922)
    static let eyeStroke = Color(red: 0.259, green: 0.478, blue: 0.239)
    static let aura = Color(red: 0.196, green: 0.784, blue: 0.353)
    static let face = faceTop

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(colors: [FaceIcon.faceTop, FaceIcon.faceBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            HStack(spacing: 6) {
                eyeShape
                eyeShape
            }
            .scaleEffect(y: blinking ? 0.14 : 1, anchor: .center)
            .offset(x: reduceMotion ? 0 : gaze.offset.width, y: (reduceMotion ? 0 : gaze.offset.height) + 1.5)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: blinking)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(FaceIcon.rim.opacity(0.55), lineWidth: 0.75))
        .onAppear { startBlinking() }
        .onChange(of: reduceMotion) {
            blinkTask?.cancel()
            blinkTask = nil
            blinking = false
            if !reduceMotion { startBlinking() }
        }
        .onDisappear {
            blinkTask?.cancel()
            blinkTask = nil
        }
    }

    private func startBlinking() {
        guard !reduceMotion, blinkTask == nil else { return }
        blinkTask = Task { @MainActor in
            while !Task.isCancelled {
                let pause = UInt64(Double.random(in: 3.0...7.5) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: pause)
                guard !Task.isCancelled else { return }
                blinking = true
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
                blinking = false
                if Bool.random() {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    blinking = true
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    blinking = false
                }
            }
        }
    }

    private var eyeShape: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(FaceIcon.eye)
            .frame(width: 6, height: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(FaceIcon.eyeStroke.opacity(0.25), lineWidth: 0.5)
            )
    }
}
