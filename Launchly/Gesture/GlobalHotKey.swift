import Carbon
import Foundation
import os

private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    GlobalHotKey.shared.handleHotKeyEvent()
    return noErr
}

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onTrigger: (() -> Void)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aryanfulari.Launchly",
        category: "HotKey"
    )

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isEnabled = false

    private let hotKeySignature: OSType = 0x4C4E4348 // 'LNCH'
    private let hotKeyID: UInt32 = 1

    private init() {}

    deinit {
        unregister()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            register()
        } else {
            unregister()
        }
    }

    func register() {
        unregister()
        guard isEnabled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )

        guard installStatus == noErr else {
            logger.error("Failed to install Carbon hot key event handler: \(installStatus)")
            return
        }
        eventHandlerRef = handlerRef

        let hotKeyIdentifier = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if registerStatus == noErr {
            hotKeyRef = ref
            logger.info("Registered global hotkey Ctrl+Opt+Space")
        } else {
            logger.error("Failed to register global hotkey: \(registerStatus)")
            unregister()
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func handleHotKeyEvent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }
            self.onTrigger?()
        }
    }
}
