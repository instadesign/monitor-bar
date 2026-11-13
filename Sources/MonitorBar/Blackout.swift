import AppKit

/// The "off" step below brightness 0: a black window over the whole monitor. The monitor stays
/// on (no power-off risk) but shows pure black, which on an OLED means its pixels are off.
/// Quitting the app removes it; so does unplugging the monitor or changing its mode.
/// The pointer stays visible on top, and a click anywhere on the black brings the picture back.
@MainActor
final class Blackout {
    var onClick: (() -> Void)?
    private var window: NSWindow?

    func cover(_ display: CGDirectDisplayID?) {
        guard window == nil, let display,
              let screen = NSScreen.screens.first(where: { Displays.id(of: $0) == display }) else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // Above the menu bar and everything else, but below pop-ups, so the panel and the level
        // pill still show on top of it.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = ClickView()
        view.onClick = { [weak self] in self?.onClick?() }
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
    }

    func uncover() {
        window?.orderOut(nil)
        window = nil
    }

    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}
