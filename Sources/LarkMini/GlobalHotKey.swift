import AppKit
import Carbon.HIToolbox

/// A global key, registered with Carbon so it works without accessibility permissions and
/// while another app is frontmost. Option-Space toggles the panel; Option-Shift-Space and Control-Option-V are voice.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let keyCode: Int
    private let modifiers: Int
    private let id: UInt32
    private let action: () -> Void
    private let release: (() -> Void)?

    init(keyCode: Int = kVK_Space, modifiers: Int = optionKey, id: UInt32 = 1,
         action: @escaping () -> Void, release: (() -> Void)? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.id = id
        self.action = action
        self.release = release
    }

    @discardableResult
    func register() -> Bool {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            // Every key's handler sees every hot key event; each answers only its own.
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { down ? hotKey.action() : hotKey.release?() }
            }
            return noErr
        }, specs.count, &specs, pointer, &handlerRef)
        guard status == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4D4E49), id: id) // 'LMNI'
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        return registered == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
