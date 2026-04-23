#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// Registers a single global hotkey (⌥Space by default) that fires `onFire`
/// on the main queue every time it's pressed anywhere in the system.
/// Uses Carbon `RegisterEventHotKey` — the only reliable API for true global
/// shortcuts without a sandbox-incompatible Accessibility dependency.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onFire: (() -> Void)?

    /// keyCode uses Carbon virtual key codes (e.g. kVK_Space = 49).
    /// modifiers is the Carbon bitmask (optionKey, cmdKey, controlKey, shiftKey).
    func register(keyCode: UInt32 = UInt32(kVK_Space),
                  modifiers: UInt32 = UInt32(optionKey)) {
        unregister()

        var hotKeyID = EventHotKeyID(signature: OSType(0x544F4441), id: 1) // 'TODA'

        let eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        var specs = [eventSpec]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var fired = EventHotKeyID()
                GetEventParameter(event,
                                  OSType(kEventParamDirectObject),
                                  OSType(typeEventHotKeyID),
                                  nil,
                                  MemoryLayout<EventHotKeyID>.size,
                                  nil,
                                  &fired)
                if fired.signature == OSType(0x544F4441) {
                    DispatchQueue.main.async {
                        GlobalHotkey.shared.onFire?()
                    }
                }
                return noErr
            },
            1, &specs, nil, &eventHandler
        )

        guard status == noErr else { return }

        RegisterEventHotKey(keyCode,
                            modifiers,
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }
    }
}
#endif
