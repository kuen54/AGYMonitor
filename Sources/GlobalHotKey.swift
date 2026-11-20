import Cocoa
import Carbon

// MARK: - Carbon Global Hotkey (⌥⇧A)

/// Registers a system-wide Carbon hotkey (Option+Shift+A) without requiring
/// Accessibility permissions, invoking `onTrigger` on the main queue.
final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private static let signature: OSType = 0x4147594D // 'AGYM'
    private static let hotKeyID: UInt32 = 1

    deinit {
        unregister()
    }

    @discardableResult
    func register(onTrigger: @escaping () -> Void) -> Bool {
        self.onTrigger = onTrigger
        guard hotKeyRef == nil else { return true }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            GlobalHotKeyManager.callback,
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }

        let keyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let modifiers = UInt32(optionKey | shiftKey)
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            modifiers,
            keyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if regStatus != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        onTrigger = nil
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    private func handleHotKey(_ event: EventRef?) -> OSStatus {
        guard let event = event else { return OSStatus(eventNotHandledErr) }
        var keyID = EventHotKeyID()
        let err = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &keyID
        )
        guard err == noErr,
              keyID.signature == Self.signature,
              keyID.id == Self.hotKeyID else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.hotKeyRef != nil else { return }
            self.onTrigger?()
        }
        return noErr
    }

    private static let callback: EventHandlerUPP = { _, event, userData in
        guard let userData = userData else { return OSStatus(eventNotHandledErr) }
        let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        return manager.handleHotKey(event)
    }
}
