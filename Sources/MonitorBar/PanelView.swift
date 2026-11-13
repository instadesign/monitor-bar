import AppKit
import MonitorCore
import ServiceManagement
import SwiftUI

/// The panel that drops down from the menu-bar icon, styled after Control Center.
struct PanelView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var keyAccess: KeyAccess

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        VStack(spacing: 10) {
            headerTile
            if model.connection == .notFound { notFoundTile }

            VStack(spacing: 10) {
                Tile("Display") {
                    slider(Panel.brightness)
                    slider(Panel.contrast)
                }
                Tile("Sound") {
                    slider(Panel.volume)
                }
                HStack(spacing: 10) {
                    Tile("Sharpness", stretch: true) { slider(Panel.sharpness) }
                    Tile("Colour preset", stretch: true) { presetMenu }
                }
                .fixedSize(horizontal: false, vertical: true)
                advancedTile
            }
            .disabled(!connected)
            .opacity(connected ? 1 : 0.5)

            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: Tiles

    private var headerTile: some View {
        Tile {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(connected ? Color.accentColor : Color.secondary.opacity(0.35))
                    Image(systemName: "display")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UPERFECT").font(.system(size: 13, weight: .semibold))
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isReading { ProgressView().controlSize(.small) }
            }
        }
    }

    private var statusText: String {
        switch model.connection {
        case .connected: return model.isReading ? "Reading settings…" : "Connected"
        case .searching: return "Looking for the monitor…"
        case .notFound: return "Not connected"
        }
    }

    private var notFoundTile: some View {
        Tile {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cable.connector").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The monitor isn't answering. If it's plugged in over USB-C it may be reconnecting, which takes a few seconds.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { model.retry() }.controlSize(.small)
                }
            }
        }
    }

    private var presetMenu: some View {
        let code = VCPCode.colourPreset
        let top = max(model.maxima[code] ?? 11, 1)
        return Picker("Colour preset", selection: Binding(
            get: { model.values[code] ?? 0 },
            set: { model.set(code, $0) }
        )) {
            if model.values[code] == nil { Text("–").tag(0) }
            ForEach(1...top, id: \.self) { Text(Panel.presetName($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var advancedTile: some View {
        Tile {
            Button {
                model.advancedOpen.toggle()
            } label: {
                HStack {
                    Text("Advanced").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.advancedOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.advancedOpen {
                caption("Colour gain")
                ForEach(Panel.gains) { slider($0) }
                Text("Colour gain normally only takes effect in the User colour preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                caption("Factory resets")
                resets
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func slider(_ spec: ControlSpec) -> some View {
        let isBrightness = spec.code == VCPCode.brightness
        return CapsuleSlider(
            spec: spec, value: model.values[spec.code], maximum: model.maximum(spec),
            black: isBrightness ? model.blackedOut : nil,
            setBlack: isBrightness ? { model.setBlackout($0) } : nil
        ) { model.set(spec.code, $0) }
    }

    // MARK: Resets

    @ViewBuilder private var resets: some View {
        if let reset = model.confirmingReset {
            VStack(alignment: .leading, spacing: 8) {
                Text(question(reset))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { model.confirmingReset = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(reset == .all ? "Reset everything" : "Reset", role: .destructive) {
                        model.confirmingReset = nil
                        model.factoryReset(reset)
                    }
                    .tint(.red)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background((reset == .all ? Color.red : Color.secondary).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            HStack(spacing: 6) {
                Button("Brightness…") { model.confirmingReset = .brightness }
                Button("Colour…") { model.confirmingReset = .colour }
            }
            .controlSize(.small)
            Button("Reset everything…") { model.confirmingReset = .all }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .padding(.top, 2)
        }
        if let notice = model.notice {
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func question(_ reset: FactoryReset) -> String {
        switch reset {
        case .brightness:
            return "Put brightness and contrast back to their factory settings?"
        case .colour:
            return "Put the colour settings back to their factory settings?"
        case .geometry:
            return "Put the picture geometry back to its factory settings? (Tried on 13 Nov: it didn't change the aspect ratio.)"
        case .all:
            return "Reset everything to factory settings? Brightness, contrast, volume and colour go back to the factory defaults; you can set them again here. Settings only the monitor's own menu can change stay as they are."
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if keyAccess.trusted {
                Label("Your Mac's brightness keys work on this monitor when the pointer is on it; volume keys when sound plays through it.",
                      systemImage: "keyboard")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Label("Use your Mac's brightness and volume keys", systemImage: "keyboard")
                    Spacer()
                    Button("Allow…") { keyAccess.request() }.controlSize(.small)
                }
            }
            Text(model.shortcutsTaken
                 ? "Control-Option-↑/↓ are taken by another app."
                 : "Also: Control-Option-↑/↓ for brightness from anywhere.")
                .foregroundStyle(model.shortcutsTaken ? Color.orange : Color.secondary)

            HStack {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!loginItem.isInstalled)
                    .help(loginItem.isInstalled ? "" : "Only the copy in Applications can open at login.")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            if loginItem.needsApproval {
                HStack {
                    Text("Allow Monitor Bar in System Settings › Login Items.").foregroundStyle(.orange)
                    Button("Open") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

/// A rounded Control Center-style module.
struct Tile<Content: View>: View {
    let title: String?
    let stretch: Bool
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(_ title: String? = nil, stretch: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.stretch = stretch
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06), lineWidth: 0.5))
    }
}

/// Control Center's wide pill slider: icon inside on the left, filled up to the value.
/// With `black` set (brightness only), dragging past the left end gives the extra "off" step.
struct CapsuleSlider: View {
    let spec: ControlSpec
    let value: Int?
    let maximum: Int
    var black: Bool? = nil
    var setBlack: ((Bool) -> Void)? = nil
    let set: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    private var isBlack: Bool { black == true }

    var body: some View {
        HStack(spacing: 8) {
            track
            Text(isBlack ? "Off" : value.map(String.init) ?? "–")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.label)
        .accessibilityValue(isBlack ? "Off" : value.map(String.init) ?? "unknown")
        .accessibilityAdjustableAction { direction in
            guard let v = value else { return }
            switch direction {
            case .increment: if isBlack { setBlack?(false) } else { set(min(v + 1, maximum)) }
            case .decrement: if v == 0, let setBlack { setBlack(true) } else { set(max(v - 1, 0)) }
            @unknown default: break
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            let fraction = maximum > 0 ? min(max(Double(value ?? 0) / Double(maximum), 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(scheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.08))
                if !isBlack {
                    Capsule()
                        .fill(spec.tint ?? .white)
                        .frame(width: height + (width - height) * fraction)
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.15), radius: 1, y: 0.5)
                }
                Image(systemName: isBlack ? "moon.fill" : spec.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isBlack ? Color.secondary : spec.tint == nil ? Color.black.opacity(0.55) : Color.white)
                    .frame(width: height, height: height)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled, value != nil else { return }
                if let setBlack {
                    // Past the left end (into the icon's left edge or beyond) is the off step.
                    let past = drag.location.x < height * 0.35
                    if past != isBlack { setBlack(past) }
                    if past { return }
                }
                let f = (drag.location.x - height / 2) / max(width - height, 1)
                set(Int((min(max(f, 0), 1) * Double(maximum)).rounded()))
            })
        }
        .frame(height: 24)
    }
}
