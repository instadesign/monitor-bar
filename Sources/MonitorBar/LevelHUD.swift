import AppKit
import SwiftUI

/// The small frosted pill that shows the new level when brightness or volume changes from the
/// keyboard, near the top-right of the screen it applies to. (Apple's own bubble can't be shown
/// for other apps on this macOS, so this takes its place.)
@MainActor
final class LevelHUD {
    static let shared = LevelHUD()

    enum Kind { case brightness, off, volume, muted }

    private final class State: ObservableObject {
        @Published var spec = Panel.brightness
        @Published var value = 0
        @Published var maximum = 100
        @Published var black = false
    }

    private let state = State()
    private var panel: NSPanel?
    private var generation = 0

    func show(_ kind: Kind, value: Int, maximum: Int, on display: CGDirectDisplayID?) {
        let screen = NSScreen.screens.first { display != nil && Displays.id(of: $0) == display } ?? NSScreen.main
        guard let screen else { return }

        switch kind {
        case .brightness, .off: state.spec = Panel.brightness
        case .volume: state.spec = Panel.volume
        case .muted: state.spec = ControlSpec(code: Panel.volume.code, label: "Volume", symbol: "speaker.slash.fill", defaultMax: 100)
        }
        state.value = value
        state.black = kind == .off
        state.maximum = maximum

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 290, height: 72)
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.maxX - size.width - 10, y: area.maxY - size.height - 8,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.generation == mine else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { if self.generation == mine { panel.orderOut(nil) } }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu  // above the black "off" window
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        // A mask image (rather than clipping the layer) rounds the window's shadow too; with a
        // layer clip, macOS still draws the shadow for the full square window.
        blur.maskImage = Self.roundedMask(radius: 18)

        let host = NSHostingView(rootView: HUDView(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
        return panel
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private struct HUDView: View {
        @ObservedObject var state: State

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(state.spec.label) · UPERFECT")
                    .font(.system(size: 12, weight: .semibold))
                CapsuleSlider(spec: state.spec, value: state.value, maximum: state.maximum, black: state.black) { _ in }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
