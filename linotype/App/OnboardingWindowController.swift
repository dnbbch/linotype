import Cocoa

/// First-run window that explains why linotype needs Accessibility and links
/// straight to the System Settings pane. Non-modal — the menu-bar app keeps
/// running behind it; it self-closes once the tap starts (permission granted).
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Brand accent (orange), matching SettingsWindowController.
    private static let accent = NSColor(red: 0.96, green: 0.51, blue: 0.12, alpha: 1)

    private let statusLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private var statusTimer: Timer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Добро пожаловать в linotype"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildLayout()
        startStatusPolling()
        window.center()
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "linotype")
        title.font = .systemFont(ofSize: 28, weight: .bold)

        let pitch = NSTextField(wrappingLabelWithString:
            "Автоматически исправляет раскладку, когда слово набрано не в той — «ghbdtn» → «привет».")
        pitch.font = .systemFont(ofSize: 13)
        pitch.textColor = .secondaryLabelColor

        let permission = NSTextField(wrappingLabelWithString:
            "Для этого нужен доступ «Универсальный доступ» (Accessibility): "
            + "linotype читает нажатия клавиш только чтобы поправить раскладку. Всё работает "
            + "на вашем Mac — ничего не отправляется в сеть.")
        permission.font = .systemFont(ofSize: 12)
        permission.textColor = .tertiaryLabelColor

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        updateStatus()

        // Compact cheat-sheet so the power features are discoverable from day one.
        let cheatSheet = NSTextField(wrappingLabelWithString: hotkeyCheatSheet())
        cheatSheet.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cheatSheet.textColor = .secondaryLabelColor

        openButton.title = "Открыть Системные настройки"
        openButton.target = self
        openButton.action = #selector(openSystemSettings)
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"  // primary

        let laterButton = NSButton(title: "Позже", target: self, action: #selector(dismiss))
        laterButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [laterButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [iconView, title, pitch, permission, statusLabel, cheatSheet, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    /// Cheat-sheet lines, including the user's configured manual-switch trigger so
    /// the description always matches their actual keys.
    private func hotkeyCheatSheet() -> String {
        let trigger: String
        switch SettingsStore.shared.manualTrigger {
        case .doubleShift:  trigger = "Двойной Shift"
        case .doubleOption: trigger = "Двойной Option"
        case .singleOption: trigger = "Одиночный Option"
        }
        return "⌘⌥L — исправить выделенное / последнее набранное\n"
             + "⌘⌥' — «ёлочки»\n"
             + "\(trigger) — переключить последнее слово"
    }

    /// Live permission feedback: polls until Accessibility is granted, then shows a
    /// green confirmation and relabels the primary button. The app's own tap poll
    /// closes the window once it actually starts; this is just clearer feedback.
    private func startStatusPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        if AXIsProcessTrusted() {
            statusLabel.stringValue = "✓ Доступ предоставлен"
            statusLabel.textColor = .systemGreen
            openButton.title = "Готово"
        } else {
            statusLabel.stringValue = "● Ожидаю разрешение…"
            statusLabel.textColor = Self.accent
            openButton.title = "Открыть Системные настройки"
        }
    }

    @objc private func openSystemSettings() {
        // Once granted the primary button just closes.
        if AXIsProcessTrusted() { close(); return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func dismiss() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        // Drop back to accessory so no Dock icon lingers.
        NSApp.setActivationPolicy(.accessory)
    }
}
