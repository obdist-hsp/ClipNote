import Carbon
import AppKit

/// Carbon RegisterEventHotKey によるグローバルホットキー（アクセシビリティ権限不要）
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let callback: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// keyCode: kVK_ANSI_2 など, modifiers: cmdKey | shiftKey など
    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        self.id = HotKey.nextID; HotKey.nextID += 1
        HotKey.instances[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.instances[hk.id]?.callback()
            return noErr
        }, 1, &spec, nil, &handler)

        let hkID = EventHotKeyID(signature: OSType(0x434C_4950) /* 'CLIP' */, id: id)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.instances[id] = nil
    }
}
