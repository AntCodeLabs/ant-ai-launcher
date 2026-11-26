import Carbon
import Foundation

/// System-wide keyboard shortcuts via Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
    static let keyC = UInt32(kVK_ANSI_C)
    static let digitKeys: [Int: UInt32] = [
        1: UInt32(kVK_ANSI_1), 2: UInt32(kVK_ANSI_2), 3: UInt32(kVK_ANSI_3),
        4: UInt32(kVK_ANSI_4), 5: UInt32(kVK_ANSI_5), 6: UInt32(kVK_ANSI_6),
        7: UInt32(kVK_ANSI_7), 8: UInt32(kVK_ANSI_8), 9: UInt32(kVK_ANSI_9),
    ]

    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.registered[id]?.action() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Registers a shortcut; returns its id (for `unregister`) or nil if another app already owns it.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> UInt32? {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x434C_4C4E), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Clauncher: couldn't register hotkey \(keyCode) (\(status)); another app may be using it")
            return nil
        }
        registered[id] = (ref, action)
        return id
    }

    func unregister(_ id: UInt32) {
        if let r = registered.removeValue(forKey: id) { UnregisterEventHotKey(r.ref) }
    }
}
