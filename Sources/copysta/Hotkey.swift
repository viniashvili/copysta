import Carbon

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // Accessed from the C callback via userData pointer.
    var onActivate: (() -> Void)?

    func register(handler: @escaping () -> Void) {
        onActivate = handler

        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Pass `self` through userData so the C-convention callback can reach it.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let handlerErr = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
                DispatchQueue.main.async { mgr.onActivate?() }
                return noErr
            },
            1, &eventType,
            selfPtr,
            &eventHandlerRef
        )
        if handlerErr != noErr {
            print("[Hotkey] InstallEventHandler failed: \(handlerErr)")
            return
        }

        // 'CSTY' signature, id 1.  Carbon consumes the event so ⌘⇧V won't
        // also trigger "Paste and Match Style" in the frontmost app.
        let hkID = EventHotKeyID(signature: 0x43535459, id: 1)
        let regErr = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),          // V key (keycode 9)
            UInt32(cmdKey | shiftKey),    // ⌘⇧
            hkID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        if regErr != noErr {
            print("[Hotkey] RegisterEventHotKey failed: \(regErr)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef        { UnregisterEventHotKey(ref);  hotKeyRef = nil }
        if let ref = eventHandlerRef  { RemoveEventHandler(ref);     eventHandlerRef = nil }
    }

    deinit { unregister() }
}
