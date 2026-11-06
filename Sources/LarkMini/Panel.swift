import AppKit
import SwiftUI

@MainActor
final class PanelBridge {
    static let shared = PanelBridge()
    weak var panel: FloatingPanel?
    var isFocused: Bool { panel.map { $0.isKeyWindow && $0.frame.height > 100 } ?? false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onCollapsedTap: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func mouseUp(with event: NSEvent) {
        // Fallback for clicks the hosting view swallows while collapsed.
        if frame.height < 100, let onCollapsedTap {
            DispatchQueue.main.async { onCollapsedTap() }
            return
        }
        super.mouseUp(with: event)
    }

}

/// Only the collapsed bubble needs a click target; the expanded panel uses
/// normal SwiftUI hit testing.
final class BubbleClickView: NSView {
    var onTap: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        // Let the click finish before the panel replaces this view, or the
        // same event lands on whatever control appears under the cursor.
        DispatchQueue.main.async { self.onTap?() }
    }
}

/// Drag only the title region; header actions keep their normal hit targets.
struct PanelDragHandle: ViewModifier {
    @State private var pointerOffset: NSPoint?

    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    guard let panel = PanelBridge.shared.panel, panel.frame.height > 100 else { return }
                    let pointer = NSEvent.mouseLocation
                    if pointerOffset == nil {
                        pointerOffset = NSPoint(x: panel.frame.minX - pointer.x, y: panel.frame.minY - pointer.y)
                    }
                    guard let offset = pointerOffset else { return }
                    panel.setFrameOrigin(NSPoint(x: pointer.x + offset.x, y: pointer.y + offset.y))
                }
                .onEnded { _ in
                    pointerOffset = nil
                    NotificationCenter.default.post(name: .panelDragEnded, object: nil)
                }
        )
    }
}

extension View {
    func panelDragHandle() -> some View { modifier(PanelDragHandle()) }
}

@MainActor
final class PanelController {
    let panel: FloatingPanel
    private let store: Store
    private let container = NSView()
    private let bubbleClick = BubbleClickView()
    private let margin: CGFloat = 12
    private var transitionID = 0
    private var collapsePending = false

    init(store: Store) {
        self.store = store
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        PanelBridge.shared.panel = panel
        panel.onEscape = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.store.showingShortcuts {
                    self.store.showingShortcuts = false
                    return
                }
                if self.store.searchOpen {
                    self.store.closeSearch()
                    return
                }
                if self.store.showingSettings {
                    self.store.showingSettings = false
                    return
                }
                if self.store.controlOpen {
                    self.store.closeControl()
                    return
                }
                if self.store.openChat != nil {
                    self.store.closeConversation()
                    return
                }
                self.collapse()
            }
        }

        let host = FirstMouseHostingView(rootView: RootView().environmentObject(store))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        container.autoresizesSubviews = true
        container.addSubview(host)
        container.addSubview(bubbleClick)
        panel.contentView = container
        panel.contentMinSize = .zero

        bubbleClick.onTap = { [weak self] in
            MainActor.assumeIsolated { self?.openFromHead() }
        }
        panel.onCollapsedTap = { [weak self] in
            MainActor.assumeIsolated { self?.openFromHead() }
        }

        NotificationCenter.default.addObserver(forName: .expandPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.expand() }
        }
        NotificationCenter.default.addObserver(forName: .collapsePanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse(hard: true) }
        }
        NotificationCenter.default.addObserver(forName: .panelSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLayout() }
        }
        NotificationCenter.default.addObserver(forName: .panelDragEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePanelPosition() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.markControlRead() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizeContent() }
        }
    }

    private func openFromHead() {
        expand()
        if store.controlAttention != nil || store.needsYouUnseen { store.openControl() }
    }

    func show() {
        layout()
        panel.orderFrontRegardless()
    }

    func expand() {
        store.reloadState()
        transitionID += 1
        collapsePending = false
        if !store.isExpanded {
            store.isExpanded = true
            GazeTracker.shared.active = false
            layout()
            panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
    }

    func collapse(hard: Bool = false) {
        guard store.isExpanded, !collapsePending else { return }
        if !hard && store.searchOpen {
            store.closeSearch()
            return
        }
        if store.searchOpen { store.closeSearch() }
        store.showingShortcuts = false
        collapsePending = true
        transitionID += 1
        let currentTransition = transitionID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionID == currentTransition else { return }
                self.collapsePending = false
                self.store.isExpanded = false
                GazeTracker.shared.active = true
                self.layout()
                self.panel.alphaValue = 1
            }
        }
    }

    func toggle() {
        store.isExpanded && !collapsePending ? collapse() : expand()
    }

    func refreshLayout() {
        guard store.isExpanded else { return }
        layout()
    }

    private func layout() {
        guard let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let rect: NSRect
        if store.isExpanded {
            let size = NSSize(width: CGFloat(Settings.validWidth(store.settings.panelWidth)),
                              height: min(560, visible.height - margin * 2 - 40))
            var proposed = PanelGeometry.rightEdge(size: size, in: visible, margin: margin)
            if let saved = UserDefaults.standard.array(forKey: "expandedPanelOrigin") as? [Double], saved.count == 2,
               saved.allSatisfy({ $0.isFinite }) {
                proposed.origin = NSPoint(x: saved[0], y: saved[1])
            }
            rect = PanelGeometry.clamp(proposed, in: visible, margin: margin)
        } else {
            // Leave room for the resting head, its aura and unread badge.
            rect = PanelGeometry.rightEdge(size: NSSize(width: 72, height: 72), in: visible, margin: 10)
        }
        panel.hasShadow = store.isExpanded
        panel.setFrame(rect, display: true)
        resizeContent()
    }

    private func savePanelPosition() {
        guard store.isExpanded, let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let frame = PanelGeometry.clamp(panel.frame, in: visible, margin: margin)
        // Dropped against the right edge means docked again, beside the head.
        if PanelGeometry.docks(frame, in: visible, margin: margin) {
            UserDefaults.standard.removeObject(forKey: "expandedPanelOrigin")
            layout()
            return
        }
        panel.setFrame(frame, display: true)
        UserDefaults.standard.set([Double(frame.minX), Double(frame.minY)], forKey: "expandedPanelOrigin")
    }

    private func resizeContent() {
        let size = panel.frame.size
        container.frame = NSRect(origin: .zero, size: size)
        container.subviews.first?.frame = container.bounds
        bubbleClick.frame = store.isExpanded ? .zero : container.bounds
        bubbleClick.isHidden = store.isExpanded
    }
}

enum PanelGeometry {
    static func clamp(_ frame: NSRect, in visible: NSRect, margin: CGFloat) -> NSRect {
        let width = min(frame.width, max(0, visible.width - margin * 2))
        let height = min(frame.height, max(0, visible.height - margin * 2))
        return NSRect(x: min(max(frame.minX, visible.minX + margin), visible.maxX - margin - width),
                      y: min(max(frame.minY, visible.minY + margin), visible.maxY - margin - height),
                      width: width, height: height)
    }

    static func docks(_ frame: NSRect, in visible: NSRect, margin: CGFloat) -> Bool {
        frame.maxX >= visible.maxX - margin - 48
    }

    static func rightEdge(size: NSSize, in visible: NSRect, margin: CGFloat) -> NSRect {
        NSRect(x: visible.maxX - margin - size.width,
               y: visible.midY - size.height / 2,
               width: size.width, height: size.height)
    }
}
