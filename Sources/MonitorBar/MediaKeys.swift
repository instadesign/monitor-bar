import AppKit
import CoreAudio

/// Listens to the Mac's own brightness, volume and mute keys and lets the app take the ones
/// meant for the monitor; every other key press goes through to macOS untouched.
/// Needs the Accessibility permission (System Settings › Privacy & Security › Accessibility).
@MainActor
final class MediaKeys {
    enum Key { case brightnessUp, brightnessDown, volumeUp, volumeDown, mute }

    /// Return true to take the key (macOS won't see it), false to pass it on.
    /// `fine` is true when Option-Shift is held, for quarter steps as on Apple's own screens.
    var handler: ((Key, _ fine: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var taken: Set<Key> = []

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14),  // NX_SYSDEFINED: media and brightness keys
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { me.reenable() }
                    return Unmanaged.passUnretained(event)
                }
                guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                    return Unmanaged.passUnretained(event)
                }
                let code = (ns.data1 & 0xFFFF_0000) >> 16
                let flags = ns.data1 & 0xFFFF
                let down = ((flags & 0xFF00) >> 8) == 0xA
                let key: Key?
                switch code {
                case 2: key = .brightnessUp
                case 3: key = .brightnessDown
                case 0: key = .volumeUp
                case 1: key = .volumeDown
                case 7: key = .mute
                default: key = nil
                }
                guard let key else { return Unmanaged.passUnretained(event) }
                let fine = ns.modifierFlags.contains([.option, .shift])
                let take = MainActor.assumeIsolated { me.handle(key, down: down, fine: fine) }
                return take ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Decide on key-down; swallow the matching key-up only if the key-down was taken.
    private func handle(_ key: Key, down: Bool, fine: Bool) -> Bool {
        guard down else { return taken.remove(key) != nil }
        let take = handler?(key, fine) ?? false
        if take { taken.insert(key) } else { taken.remove(key) }
        return take
    }
}

/// Apple-style steps: 16 across the full range, or quarter steps (64) with Option-Shift.
enum Steps {
    static func next(_ current: Int, max top: Int, up: Bool, fine: Bool) -> Int {
        guard top > 0 else { return current }
        let step = Double(top) / (fine ? 64 : 16)
        let position = (Double(current) / step).rounded() + (up ? 1 : -1)
        return min(max(Int((position * step).rounded()), 0), top)
    }
}

enum Displays {
    static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func underPointer() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }.flatMap(id)
    }

    /// The external monitor, if the pointer is on it (the built-in screen keeps its own keys).
    static func externalUnderPointer() -> CGDirectDisplayID? {
        guard let display = underPointer(), CGDisplayIsBuiltin(display) == 0 else { return nil }
        return display
    }

    static func firstExternal() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) == 0 }
    }
}

enum AudioOutput {
    /// True when sound is going to a monitor over DisplayPort/HDMI and macOS has no volume
    /// control of its own for it, which is when the volume keys should drive the monitor.
    static func isMonitorWithoutOwnVolume() -> Bool {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI else { return false }

        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var volume = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                    mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &volume),
               AudioObjectIsPropertySettable(device, &volume, &settable) == noErr, settable.boolValue {
                return false
            }
        }
        return true
    }
}

/// Whether Monitor Bar may watch the keyboard (the Accessibility permission).
@MainActor
final class KeyAccess: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()
    var onGranted: (() -> Void)?
    private var timer: Timer?

    func refresh() {
        trusted = AXIsProcessTrusted()
        if trusted { onGranted?() }
    }

    /// Shows macOS's own "allow Accessibility" prompt, then waits for the switch to be turned on.
    func request() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { refresh(); return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    t.invalidate()
                    self.timer = nil
                    self.refresh()
                }
            }
        }
    }
}
