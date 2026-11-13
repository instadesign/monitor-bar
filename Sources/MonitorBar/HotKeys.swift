import Carbon.HIToolbox

/// System-wide keyboard shortcuts (Control-Option plus a key). Uses the old Carbon hot-key API,
/// which needs no Accessibility permission. If another app already owns a combination,
/// registering it fails and the key is listed in `taken`.
@MainActor
final class HotKeys {
    struct Key {
        let id: UInt32
        let keyCode: Int
        let action: () -> Void
    }

    private var keys: [Key] = []
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var taken: [UInt32] = []

    func register(_ keys: [Key]) {
        self.keys = keys
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard err == noErr else { return err }
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { me.fire(hotKey.id) }
            return noErr
        }, 1, &spec, me, &handler)

        for key in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x4D4E4252 /* "MNBR" */, id: key.id)
            let status = RegisterEventHotKey(UInt32(key.keyCode), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { taken.append(key.id) }
        }
    }

    private func fire(_ id: UInt32) {
        keys.first { $0.id == id }?.action()
    }
}
