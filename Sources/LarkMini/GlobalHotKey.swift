import AppKit
import Carbon.HIToolbox

/// Option-Space toggle, registered with Carbon so it works without
/// accessibility permissions and while another app is frontmost.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @discardableResult
    func register() -> Bool {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { hotKey.action() }
            }
            return noErr
        }, 1, &spec, pointer, &handlerRef)
        guard status == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4D4E49), id: 1) // 'LMNI'
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        return registered == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
