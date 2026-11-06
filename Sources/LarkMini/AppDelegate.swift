import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: Store
    private let panelController: PanelController
    private let bubbleController: EdgeBubbleController
    private let demoMode: Bool
    private var statusItem: NSStatusItem?
    private var outsideMonitor: Any?
    private var hotKey: GlobalHotKey?
    private var editMonitor: Any?
    private var keyMonitor: Any?

    init(demo: Bool, openDemoChat: Bool = false, openDemoControl: Bool = false, openDemoSearch: Bool = false, demoNeedsYou: Bool = false) {
        demoMode = demo
        store = demo ? Store.demo(needsYou: demoNeedsYou) : Store()
        if demo && openDemoChat { store.openChat = store.chats.first }
        if demo && openDemoControl { store.controlOpen = true }
        if demo && openDemoSearch {
            store.searchOpen = true
        }
        panelController = PanelController(store: store)
        bubbleController = EdgeBubbleController(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GazeTracker.shared.start()
        Notifications.shared.onOpen = { [weak self] destination in
            guard let self else { return }
            self.panelController.expand()
            if destination == "control" { self.store.openControl() }
            else if let chat = self.store.chats.first(where: { $0.id == destination }) { self.store.open(chat) }
        }
        Task { await Notifications.shared.refresh(request: Notifications.shared.enabled) }
        installEditMenu()
        installKeyMonitor()
        setUpStatusItem()
        let signedIn: Bool
        if case .signedIn = store.auth { signedIn = true } else { signedIn = false }
        store.isExpanded = demoMode ? !CommandLine.arguments.contains("--demo-needs-you") : !signedIn
        panelController.show()
        store.start()
        if !demoMode { installOutsideClickMonitor() }
        let hotKey = GlobalHotKey { [weak self] in self?.panelController.toggle() }
        hotKey.register()
        self.hotKey = hotKey
        if store.isExpanded {
            panelController.expand()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }

    /// Accessory apps with no main menu never route ⌘C/⌘V/⌘A, so the panel's
    /// text fields are dead. Install the standard Edit menu and a fallback
    /// monitor for the nonactivating panel.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Sift",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu

        editMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased()
            let selector: Selector?
            switch key {
            case "v": selector = #selector(NSText.paste(_:))
            case "c": selector = #selector(NSText.copy(_:))
            case "x": selector = #selector(NSText.cut(_:))
            case "a": selector = #selector(NSText.selectAll(_:))
            case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: selector = nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: nil) {
                return nil
            }
            return event
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(event) == nil }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard store.isExpanded, !store.showingShortcuts else { return event }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if store.searchOpen {
            switch event.keyCode {
            case 125: store.moveSearchSelection(1); return nil
            case 126: store.moveSearchSelection(-1); return nil
            case 36: store.openSelectedSearchResult(); return nil
            default: break
            }
        }

        let typing = (NSApp.keyWindow?.firstResponder as? NSTextView) != nil
        if !store.searchOpen, !typing, flags.isEmpty,
           store.openChat == nil, !store.showingSettings, !store.controlOpen {
            switch event.keyCode {
            case 38, 125: store.moveListSelection(1); return nil   // j, down
            case 40, 126: store.moveListSelection(-1); return nil  // k, up
            case 14: store.markSelectedRead(); return nil     // e
            case 36:
                if let chat = store.selectedInboxChat() {
                    store.open(chat)
                    return nil
                }
            default: break
            }
        }

        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k": store.openSearch(); return nil
            case ",":
                if store.searchOpen { store.closeSearch() }
                store.showingSettings = true
                return nil
            case "0": store.showInbox(); return nil
            default: break
            }
        }

        if flags.contains(.command),
           let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number) {
            let pins = store.pinnedChats
            if number <= pins.count {
                store.open(pins[number - 1])
                return nil
            }
        }

        return event
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = BrandIcon.statusBar()
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            panelController.toggle()
        }
    }

    private func showStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Sift", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Add Control seat…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() {
        panelController.expand()
    }

    @objc private func openSettings() {
        panelController.expand()
        store.showingSettings = true
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func installOutsideClickMonitor() {
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.store.isExpanded, self.store.settings.collapseOnOutsideClick else { return }
                let point = NSEvent.mouseLocation
                if !self.panelController.panel.frame.contains(point) {
                    self.panelController.collapse(hard: true)
                }
            }
        }
    }
}
