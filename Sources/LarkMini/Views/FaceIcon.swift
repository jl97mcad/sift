import SwiftUI
import AppKit

/// Watches the pointer so the face's eyes can follow it.
@MainActor
final class GazeTracker: ObservableObject {
    static let shared = GazeTracker()
    @Published private(set) var offset: CGSize = .zero
    @Published private(set) var proximity: Double = 0
    @Published private(set) var near = false
    var active = true

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { _ in
            MainActor.assumeIsolated { GazeTracker.shared.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update() {
        guard active, let frame = PanelBridge.shared.panel?.frame else { return }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        let distance = max(1, sqrt(dx * dx + dy * dy))
        let hoverDistance = distance
        let newProximity = max(0, min(1, 1 - (hoverDistance - 22) / 68))
        if abs(newProximity - proximity) > 0.02 { proximity = newProximity }
        let shouldBeNear = near ? hoverDistance < 110 : hoverDistance < 85
        if shouldBeNear != near { near = shouldBeNear }


        let reach: CGFloat = 2.8
        let strength = min(1, distance / 180)
        let target = CGSize(width: dx / distance * reach * strength,
                            height: -dy / distance * reach * strength)
        if abs(target.width - offset.width) > 0.06 || abs(target.height - offset.height) > 0.06 {
            offset = target
        }
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
