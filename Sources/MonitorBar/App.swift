import AppKit
import Carbon.HIToolbox
import Combine
import MonitorCore
import ServiceManagement
import SwiftUI

@main
enum MonitorBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar only: no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// The menu-bar icon (a sun plus the monitor's brightness), the panel it opens, and the keys.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MonitorModel()
    private let loginItem = LoginItem()
    private let keyAccess = KeyAccess()
    private let hotKeys = HotKeys()
    private let mediaKeys = MediaKeys()
    private let blackout = Blackout()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        let host = NSHostingController(rootView: PanelView(model: model, loginItem: loginItem, keyAccess: keyAccess))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        // Control Center's panel has no pointer arrow; hide the popover's if this macOS allows it.
        if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }

        model.$values.combineLatest(model.$connection, model.$blackedOut)
            .sink { [weak self] values, connection, black in
                self?.updateIcon(brightness: values[VCPCode.brightness], connection: connection, black: black)
            }
            .store(in: &bag)

        blackout.onClick = { [weak self] in self?.model.setBlackout(false) }
        model.$blackedOut.removeDuplicates()
            .sink { [weak self] black in
                guard let self else { return }
                if black { self.blackout.cover(Displays.firstExternal()) } else { self.blackout.uncover() }
            }
            .store(in: &bag)

        model.$monitorPresent.removeDuplicates()
            .sink { [weak self] present in self?.setItemVisible(present) }
            .store(in: &bag)

        model.start()

        hotKeys.register([
            .init(id: 1, keyCode: kVK_UpArrow) { [weak self] in
                self?.stepBrightness(up: true, fine: false, display: Displays.firstExternal())
            },
            .init(id: 2, keyCode: kVK_DownArrow) { [weak self] in
                self?.stepBrightness(up: false, fine: false, display: Displays.firstExternal())
            },
        ])
        model.shortcutsTaken = !hotKeys.taken.isEmpty

        mediaKeys.handler = { [weak self] key, fine in self?.handleMediaKey(key, fine: fine) ?? false }
        keyAccess.onGranted = { [weak self] in
            guard let self else { return }
            if !self.mediaKeys.start() { NSLog("MonitorBar: could not start listening to the keyboard") }
        }
        keyAccess.refresh()

        loginItem.switchOnFirstTime()

        handleDevelopmentFlags()
    }

    // MARK: Keys

    private func stepBrightness(up: Bool, fine: Bool, display: CGDirectDisplayID?) {
        guard model.monitorPresent else { return }
        // The extra off step: brightness-down at 0 blacks the monitor out; brightness-up brings it back.
        if model.blackedOut || (!up && model.values[VCPCode.brightness] == 0) {
            model.setBlackout(!up)
            LevelHUD.shared.show(up ? .brightness : .off, value: model.values[VCPCode.brightness] ?? 0, maximum: 100, on: display)
            return
        }
        model.adjust(VCPCode.brightness, { current, top in Steps.next(current, max: top, up: up, fine: fine) }) { new, top in
            LevelHUD.shared.show(.brightness, value: new, maximum: top, on: display)
        }
    }

    private func handleMediaKey(_ key: MediaKeys.Key, fine: Bool) -> Bool {
        guard model.monitorPresent, model.connection != .notFound else { return false }
        switch key {
        case .brightnessUp, .brightnessDown:
            guard let display = Displays.externalUnderPointer() else { return false }
            stepBrightness(up: key == .brightnessUp, fine: fine, display: display)
            return true
        case .volumeUp, .volumeDown:
            guard AudioOutput.isMonitorWithoutOwnVolume() else { return false }
            let display = Displays.underPointer()
            model.adjust(VCPCode.volume, { current, top in Steps.next(current, max: top, up: key == .volumeUp, fine: fine) }) { new, top in
                LevelHUD.shared.show(new == 0 ? .muted : .volume, value: new, maximum: top, on: display)
            }
            return true
        case .mute:
            guard AudioOutput.isMonitorWithoutOwnVolume() else { return false }
            let display = Displays.underPointer()
            model.toggleMute { muted, volume in
                LevelHUD.shared.show(muted ? .muted : .volume, value: volume, maximum: 100, on: display)
            }
            return true
        }
    }

    // MARK: Icon and panel

    private func updateIcon(brightness: Int?, connection: MonitorModel.Connection, black: Bool) {
        guard let button = statusItem?.button else { return }
        let lost = connection == .notFound
        let name = lost ? "display.trianglebadge.exclamationmark" : "sun.max"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: "Monitor")
            ?? NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Monitor"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.title = lost ? "" : black ? " off" : brightness.map { " \($0)" } ?? ""
        button.toolTip = lost ? "Monitor not connected" : "Monitor brightness"
    }

    /// The menu-bar item only appears while the monitor is plugged in.
    private func setItemVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
        if !visible, popover.isShown { popover.performClose(nil) }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        model.panelOpened()
        loginItem.refresh()
        keyAccess.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Development aids

    /// --open shows the panel at launch; --advanced expands Advanced; --snapshot <file.png> saves
    /// a picture of the panel a few seconds later; --test-hud shows the level pill with made-up
    /// values (nothing is sent to the monitor).
    private func handleDevelopmentFlags() {
        let args = CommandLine.arguments
        if args.contains("--advanced") { model.advancedOpen = true }
        if args.contains("--open") || args.contains("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showPanel() }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.snapshot(to: path) }
        }
        if let i = args.firstIndex(of: "--report"), i + 1 < args.count {
            // Writes the app's own view of its permissions, for checking from the terminal.
            let names = ["not registered", "enabled", "needs approval", "not found"]
            let login = SMAppService.mainApp.status
            let lines = [
                "app: \(Bundle.main.bundlePath)",
                "open at login: \(names[safe: login.rawValue] ?? "\(login.rawValue)")",
                "accessibility allowed: \(AXIsProcessTrusted())",
                "control-option shortcuts taken by another app: \(!hotKeys.taken.isEmpty)",
                "keyboard listener running: \(mediaKeys.isRunning)",
                "monitor plugged in: \(model.monitorPresent)",
                "menu-bar item visible: \(statusItem.isVisible)",
            ]
            try? lines.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        if args.contains("--test-hud") {
            // Shows the level pill on the built-in screen with made-up values; sends nothing.
            for (i, v) in [56, 63, 69].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i)) {
                    LevelHUD.shared.show(.brightness, value: v, maximum: 100, on: CGMainDisplayID())
                }
            }
        }
    }

    private func snapshot(to path: String) {
        let candidates = [popover.contentViewController?.view.window?.contentView?.superview,
                          popover.contentViewController?.view].compactMap { $0 }
        guard let root = candidates.first(where: { $0.layer != nil }), let layer = root.layer else {
            NSLog("MonitorBar snapshot: no layer-backed view to render")
            return
        }
        let scale = root.window?.backingScaleFactor ?? 2
        let size = root.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        if !layer.isGeometryFlipped && root.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
