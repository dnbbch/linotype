import Cocoa

/// A small РУ/EN plaque shown on a switch, anchored under the menu-bar icon.
/// On frequent switches it doesn't flicker — it just updates the text and
/// extends the display. Toggleable in settings.
final class SwitchHUD {

    weak var statusItem: NSStatusItem?

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?
    private var visible = false

    func show(_ text: String) {
        guard SettingsStore.shared.showHUD else { return }
        if Thread.isMainThread { present(text) }
        else { DispatchQueue.main.async { self.present(text) } }
    }

    private func present(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label?.stringValue = text

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)

        // Already on screen: just extend, don't re-animate (no flicker).
        if visible { return }
        visible = true
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.visible = false
        }
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 60, height: 38)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 9
        blur.layer?.masksToBounds = true

        let lbl = NSTextField(labelWithString: "")
        lbl.font = .systemFont(ofSize: 16, weight: .semibold)
        lbl.alignment = .center
        lbl.textColor = .labelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])
        self.label = lbl

        panel.contentView = blur
        return panel
    }

    /// Positions the plaque under the menu-bar icon, or top-center of the main
    /// screen as a fallback.
    private func position(_ panel: NSPanel) {
        let s = panel.frame.size

        if let win = statusItem?.button?.window {
            let f = win.frame
            var x = f.midX - s.width / 2
            var y = f.minY - s.height - 6
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) }) ?? NSScreen.main {
                let sf = screen.frame
                x = min(max(x, sf.minX + 8), sf.maxX - s.width - 8)
                y = min(max(y, sf.minY + 8), sf.maxY - s.height - 8)
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.maxY - s.height - 12))
        }
    }
}
