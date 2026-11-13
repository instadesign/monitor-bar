import AppKit
import Combine
import MonitorCore
import SwiftUI

/// One slider in the panel.
struct ControlSpec: Identifiable {
    let code: UInt8
    let label: String
    let symbol: String
    let defaultMax: Int
    var tint: Color? = nil
    var id: UInt8 { code }
}

enum Panel {
    static let brightness = ControlSpec(code: VCPCode.brightness, label: "Brightness", symbol: "sun.max.fill", defaultMax: 100)
    static let contrast = ControlSpec(code: VCPCode.contrast, label: "Contrast", symbol: "circle.lefthalf.filled", defaultMax: 100)
    static let volume = ControlSpec(code: VCPCode.volume, label: "Volume", symbol: "speaker.wave.2.fill", defaultMax: 100)
    static let sharpness = ControlSpec(code: VCPCode.sharpness, label: "Sharpness", symbol: "diamond.fill", defaultMax: 4)
    static let main: [ControlSpec] = [brightness, contrast, volume, sharpness]
    static let gains: [ControlSpec] = [
        .init(code: VCPCode.redGain, label: "Red gain", symbol: "r.circle.fill", defaultMax: 100, tint: .red),
        .init(code: VCPCode.greenGain, label: "Green gain", symbol: "g.circle.fill", defaultMax: 100, tint: .green),
        .init(code: VCPCode.blueGain, label: "Blue gain", symbol: "b.circle.fill", defaultMax: 100, tint: .blue),
    ]

    static let mainCodes: [UInt8] = main.map(\.code) + [VCPCode.colourPreset]
    static let advancedCodes: [UInt8] = gains.map(\.code)

    /// The standard (MCCS) names for colour preset numbers. Not yet checked against what this
    /// monitor actually shows for each one.
    static func presetName(_ n: Int) -> String {
        let names = [1: "sRGB", 2: "Native", 3: "4000 K", 4: "5000 K", 5: "6500 K", 6: "7500 K",
                     7: "8200 K", 8: "9300 K", 9: "10000 K", 10: "11500 K", 11: "User"]
        return "\(n) · \(names[n] ?? "Preset")"
    }
}

/// What the panel shows, and the rules for talking to the monitor:
/// - read the settings when the panel opens (never on a timer);
/// - send slider moves at most a few times a second, always finishing on the last value;
/// - never let a slow read overwrite a slider the user is moving.
@MainActor
final class MonitorModel: ObservableObject {
    enum Connection: Equatable { case searching, connected, notFound }

    @Published private(set) var connection: Connection = .searching
    @Published private(set) var values: [UInt8: Int] = [:]
    @Published private(set) var maxima: [UInt8: Int] = [:]
    @Published private(set) var isReading = false
    /// Whether the monitor is plugged in. Drives whether the menu-bar item is shown at all.
    @Published private(set) var monitorPresent = Monitor.isPresent()
    /// The extra "off" step below brightness 0: the monitor shows pure black (see Blackout).
    @Published private(set) var blackedOut = false
    @Published private(set) var notice: String?
    /// Which factory reset is waiting for "are you sure?" in the panel, if any.
    @Published var confirmingReset: FactoryReset?
    @Published var shortcutsTaken = false
    @Published var advancedOpen = false {
        didSet { if advancedOpen && !oldValue { refresh(Panel.advancedCodes) } }
    }

    private let link = MonitorLink()
    private var writes: [UInt8: WriteState] = [:]
    private var lastTouched: [UInt8: Date] = [:]
    private var queuedReads: [UInt8] = []
    private var presenceChecks: [DispatchWorkItem] = []
    private var absentSince: Date?
    private var changedAt = Date.distantPast
    private var readAfterChange = false

    private struct WriteState { var wanted: Int; var sent: Int?; var inFlight = false }

    // MARK: Life cycle

    func start() {
        observeDisplayChanges()
        if monitorPresent { refresh(Panel.mainCodes) } else { connection = .notFound }
    }

    func panelOpened() {
        refresh(Panel.mainCodes + (advancedOpen ? Panel.advancedCodes : []))
    }

    func retry() {
        link.forget()
        connection = .searching
        panelOpened()
    }

    // MARK: Reading

    func refresh(_ codes: [UInt8]) {
        if isReading {
            queuedReads += codes.filter { !queuedReads.contains($0) }
            return
        }
        isReading = true
        if connection != .connected { connection = .searching }
        link.read(codes, each: { [weak self] code, reading in
            MainActor.assumeIsolated { self?.received(code, reading) }
        }, done: { [weak self] answered in
            MainActor.assumeIsolated { self?.finishedReading(answered: answered) }
        })
    }

    private func received(_ code: UInt8, _ reading: VCPReading?) {
        guard let r = reading, r.supported else { return }
        connection = .connected
        if r.max > 0 { maxima[code] = r.max }
        if writes[code]?.inFlight == true { return }
        if let t = lastTouched[code], Date().timeIntervalSince(t) < 1.5 { return }
        values[code] = r.current
    }

    private func finishedReading(answered: Bool) {
        isReading = false
        connection = answered ? .connected : .notFound
        if answered, !queuedReads.isEmpty {
            let next = queuedReads
            queuedReads = []
            refresh(next)
        } else {
            queuedReads = []
        }
    }

    // MARK: Writing

    func maximum(_ spec: ControlSpec) -> Int { maxima[spec.code] ?? spec.defaultMax }

    func set(_ code: UInt8, _ value: Int) {
        guard values[code] != value else { return }
        values[code] = value
        lastTouched[code] = Date()
        if writes[code] == nil { writes[code] = WriteState(wanted: value) } else { writes[code]!.wanted = value }
        pump(code)
    }

    /// Send the latest wanted value if nothing is on the wire for this code. When a write
    /// finishes, wait a moment and send again if the slider has moved since.
    private func pump(_ code: UInt8) {
        guard let s = writes[code], !s.inFlight, s.sent != s.wanted else { return }
        let value = s.wanted
        writes[code]!.inFlight = true
        link.write(code, value) { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard ok else {
                    self.writes[code] = nil
                    self.connection = .notFound
                    return
                }
                self.writes[code]?.inFlight = false
                self.writes[code]?.sent = value
                self.lastTouched[code] = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    MainActor.assumeIsolated { self.pump(code) }
                }
            }
        }
    }

    // MARK: Shortcuts and resets

    func setBlackout(_ on: Bool) {
        if blackedOut != on { blackedOut = on }
    }

    /// Change a setting relative to its current value, reading it first if it's unknown.
    /// `transform` gets (current, maximum) and returns the new value; `then` gets (new, maximum).
    func adjust(_ code: UInt8, _ transform: @escaping (Int, Int) -> Int, then: ((Int, Int) -> Void)? = nil) {
        let apply: (Int) -> Void = { [weak self] current in
            guard let self else { return }
            let top = self.maxima[code] ?? 100
            let new = min(max(transform(current, top), 0), top)
            self.set(code, new)
            then?(new, top)
        }
        if let v = values[code] { apply(v); return }
        link.read([code], each: { [weak self] c, reading in
            MainActor.assumeIsolated {
                self?.received(c, reading)
                if let reading, reading.supported { apply(reading.current) }
            }
        }, done: { [weak self] answered in
            MainActor.assumeIsolated { if !answered { self?.connection = .notFound } }
        })
    }

    /// The monitor has no mute of its own, so mute means volume 0, and unmute puts it back.
    private var volumeBeforeMute: Int?

    func toggleMute(then: @escaping (_ muted: Bool, _ volume: Int) -> Void) {
        adjust(VCPCode.volume, { [weak self] current, _ in
            guard let self else { return current }
            if current > 0 { self.volumeBeforeMute = current; return 0 }
            defer { self.volumeBeforeMute = nil }
            return self.volumeBeforeMute ?? 50
        }, then: { new, _ in then(new == 0, new) })
    }

    func factoryReset(_ reset: FactoryReset) {
        writes.removeAll()
        lastTouched.removeAll()
        notice = nil
        link.write(reset.code, 1) { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard ok else {
                    self.notice = "The reset wasn't sent: the monitor isn't answering."
                    self.connection = .notFound
                    return
                }
                self.notice = "Sent: factory reset of \(reset.what)."
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { self.refresh(Panel.mainCodes + Panel.advancedCodes) }
                }
            }
        }
    }

    // MARK: Display changes

    /// When the displays reconfigure (plugging in, waking, resolution or rotation changes) the
    /// control channel goes away for a few seconds. Forget it and read again shortly after.
    private func observeDisplayChanges() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let model = Unmanaged<MonitorModel>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { model.displaysChanged() } }
        }, me)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
    }

    private func displaysChanged() {
        link.forget()
        setBlackout(false)  // a reconnect or mode change brings the picture back
        changedAt = Date()
        readAfterChange = true
        presenceChecks.forEach { $0.cancel() }
        presenceChecks = [0, 1, 2, 3, 4, 5, 6, 8, 12].map { delay in
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.checkPresence() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    /// Plugged in: show at once, and read the settings once the channel has settled (2.5 s after
    /// the change). Unplugged: only count the monitor as gone after 5 s without its channel,
    /// because the channel also disappears briefly during resolution or rotation changes.
    private func checkPresence() {
        if Monitor.isPresent() {
            absentSince = nil
            if !monitorPresent { monitorPresent = true }
            if readAfterChange, Date().timeIntervalSince(changedAt) >= 2.5 {
                readAfterChange = false
                panelOpened()
            }
        } else {
            let since = absentSince ?? Date()
            absentSince = since
            if monitorPresent, Date().timeIntervalSince(since) >= 5 {
                monitorPresent = false
                connection = .notFound
                readAfterChange = false
            }
        }
    }
}
